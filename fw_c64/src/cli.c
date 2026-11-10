/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: cli.c
 * Role: transport of the engineering CLI (contract in cli.h): raw UART bytes in via
 *   keyboard_cli_getc(), line editing with echo, Menu_ProcessLine() dispatch, and a
 *   non-blocking output ring drained straight into the UART Lite transmit FIFO.
 */
#include "cli.h"

#include <stddef.h>

#include "basic.h"
#include "keyboard.h"
#include "menu.h"

#include "xparameters.h"   /* XPAR_AXI_UARTLITE_0_BASEADDR */
#include "xuartlite_l.h"   /* XUartLite_IsTransmitFull, XUartLite_SendByte */

#define CLI_UART_BASE   (XPAR_AXI_UARTLITE_0_BASEADDR)
#define CLI_ESC_SKIP    (8u)     /* bytes dropped after ESC at most */

static uint8_t  g_tx[CLI_TX_RING];
static uint32_t g_tx_head;       /* next write index (free-running) */
static uint32_t g_tx_tail;       /* next read index (free-running) */
static int      g_tx_overflow;
static char     g_line[MENU_LINE_MAX];
static uint32_t g_len;
static int      g_line_ready;    /* a full line waits in g_line for an empty output ring */
static int      g_line_over;     /* the current line overflowed g_line */
static int      g_last_cr;
static uint32_t g_esc_left;
static int      g_was_active;
static const ddr_probe_result_t *g_ddr;

/*
 * tx_put -- queue one output byte, LF becomes CR LF.
 * Returns: nothing; a byte that does not fit is dropped and g_tx_overflow is set.
 */
static void tx_put(char c)
{
    if (c == '\n') {
        tx_put('\r');
    }
    if (g_tx_head - g_tx_tail >= CLI_TX_RING) {
        g_tx_overflow = 1;
        return;
    }
    g_tx[g_tx_head & (CLI_TX_RING - 1u)] = (uint8_t)c;
    g_tx_head++;
}

/*
 * menu_write -- output sink of the generated menu (declared in menu.h).
 * Returns: nothing; queues the text in the output ring.
 */
void menu_write(const char *text)
{
    while (*text != '\0') {
        tx_put(*text++);
    }
}

/*
 * cli_put_u32 -- queue an unsigned decimal number.
 * Returns: nothing.
 */
void cli_put_u32(uint32_t v)
{
    char tmp[10];
    uint32_t n = 0u;

    do {
        tmp[n++] = (char)('0' + (v % 10u));
        v /= 10u;
    } while (v != 0u && n < sizeof(tmp));
    while (n > 0u) {
        tx_put(tmp[--n]);
    }
}

/*
 * cli_put_hex -- queue "0x" and a fixed number of hex digits (1..8).
 * Returns: nothing.
 */
void cli_put_hex(uint32_t v, uint32_t digits)
{
    uint32_t i;

    if (digits < 1u || digits > 8u) {
        digits = 8u;
    }
    tx_put('0');
    tx_put('x');
    for (i = digits; i > 0u; i--) {
        tx_put("0123456789ABCDEF"[(v >> ((i - 1u) * 4u)) & 0xFu]);
    }
}

/*
 * cli_put_kv -- queue "key=<decimal> ".
 * Returns: nothing.
 */
void cli_put_kv(const char *key, uint32_t v)
{
    menu_write(key);
    tx_put('=');
    cli_put_u32(v);
    tx_put(' ');
}

/*
 * cli_refuse_if_playing -- guard for commands that must not stall the player.
 * Returns: 1 (and prints the refusal) while a tune plays, else 0.
 */
int cli_refuse_if_playing(void)
{
    if (basic_playing()) {
        menu_write("Refused: a tune is playing (EXIT, then the X key stops it)\n");
        return 1;
    }
    return 0;
}

/*
 * cli_ddr -- DDR3 probe result handed over by main.
 * Returns: the result, never NULL (a zero result before cli_init).
 */
const ddr_probe_result_t *cli_ddr(void)
{
    static const ddr_probe_result_t zero = { 0u, 0u, 0u, 0u, 0u };

    return (g_ddr != NULL) ? g_ddr : &zero;
}

/*
 * cli_init -- remember the DDR3 probe result and reset the editor.
 * Returns: nothing.
 */
void cli_init(const ddr_probe_result_t *ddr)
{
    g_ddr = ddr;
    g_tx_head = g_tx_tail = 0u;
    g_len = 0u;
    g_line_ready = 0;
    g_was_active = 0;
    Menu_Init();
}

/*
 * tx_drain -- move up to CLI_TX_SLICE ring bytes into the UART transmit FIFO.
 * Stops at once when the FIFO is full, so it never waits.
 * Returns: nothing.
 */
static void tx_drain(void)
{
    uint32_t n;

    for (n = 0u; n < CLI_TX_SLICE && g_tx_tail != g_tx_head; n++) {
        if (XUartLite_IsTransmitFull(CLI_UART_BASE)) {
            break;
        }
        XUartLite_SendByte(CLI_UART_BASE, g_tx[g_tx_tail & (CLI_TX_RING - 1u)]);
        g_tx_tail++;
    }
}

/*
 * rx_byte -- line editor step for one input byte.
 * Steps: skip the tail of an ESC sequence; CR / LF ends the line (the LF of a CR LF pair
 *   is swallowed); BS / DEL erases one character; printable ASCII is echoed and stored;
 *   other control bytes are ignored. A line longer than MENU_LINE_MAX - 1 is flagged and
 *   refused at its end.
 * Returns: nothing.
 */
static void rx_byte(uint8_t b)
{
    if (g_esc_left > 0u) {
        g_esc_left--;
        if ((b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || b == '~') {
            g_esc_left = 0u;
        }
        return;
    }
    if (b == 0x1Bu) {
        g_esc_left = CLI_ESC_SKIP;
        return;
    }
    if (b == '\n' && g_last_cr) {
        g_last_cr = 0;
        return;
    }
    g_last_cr = (b == '\r');
    if (b == '\r' || b == '\n') {
        tx_put('\n');
        g_line[g_len] = '\0';
        g_line_ready = 1;
    } else if (b == 0x08u || b == 0x7Fu) {
        if (g_len > 0u) {
            g_len--;
            menu_write("\b \b");
        }
    } else if (b >= 0x20u && b < 0x7Fu) {
        if (g_len < MENU_LINE_MAX - 1u) {
            g_line[g_len++] = (char)b;
            tx_put((char)b);
        } else {
            g_line_over = 1;
        }
    }
}

/*
 * cli_poll -- one non-blocking CLI step (see cli.h).
 * Steps:
 *   1. Output: drain the ring. On the inactive -> active edge queue banner and prompt.
 *   2. When active and no line is waiting: read up to CLI_RX_SLICE bytes.
 *   3. When a line waits and the output ring is empty: run it through Menu_ProcessLine;
 *      EXIT leaves CLI mode; queue "[output truncated]" if output was dropped; queue the prompt.
 * Input: active = keyboard_cli_mode().
 * Returns: nothing.
 */
void cli_poll(int active)
{
    tx_drain();
    if (!active) {
        g_was_active = 0;
        return;
    }
    if (!g_was_active) {
        g_was_active = 1;
        g_len = 0u;
        g_line_ready = 0;
        g_esc_left = 0u;
        menu_write("\nIronKernel 64 engineering CLI, HELP lists the commands, EXIT returns\n" CLI_PROMPT);
    }
    if (!g_line_ready) {
        uint32_t n;
        uint8_t b;

        for (n = 0u; n < CLI_RX_SLICE && !g_line_ready && keyboard_cli_getc(&b); n++) {
            rx_byte(b);
        }
    }
    if (g_line_ready && g_tx_tail == g_tx_head) {
        int rc;

        if (g_line_over) {
            menu_write("Line too long\n");
            rc = -1;
        } else {
            rc = Menu_ProcessLine(g_line);
        }
        g_len = 0u;
        g_line_over = 0;
        g_line_ready = 0;
        if (g_tx_overflow) {
            g_tx_overflow = 0;
            menu_write("[output truncated]\n");
        }
        if (rc == MENU_EXIT) {
            menu_write("Back to the C64 screen\n");
            keyboard_set_cli_mode(0);
        } else {
            menu_write(CLI_PROMPT);
        }
    }
}

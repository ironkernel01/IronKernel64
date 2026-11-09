/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: keyboard.c
 * Role: UART (ANSI terminal) and PS/2 set 2 decoders feeding one PETSCII key queue
 *   (contract in keyboard.h).
 *
 * Ownership: this file is the only one that reads the UART Lite receive FIFO (XUartLite
 *   driver, instance axi_uartlite_0) and the ps2_rx registers (C64_PLAT_WIN0_BASE +
 *   C64_WIN_PS2_OFS). The UART transmit side stays with the BSP console.
 * Data flow: hardware FIFO -> raw byte ring (drain: ISR or keyboard_poll) -> decoder
 *   (keyboard_poll, main context) -> PETSCII queue (keyboard_getkey, main context).
 *   Each ring has one producer and one consumer; head is written by the producer only and
 *   tail by the consumer only, both volatile.
 * Fail-stop: a failing XUartLite call prints the API name and code and parks the CPU.
 */
#include "keyboard.h"

#include "c64_platform.h"
#include "c64_regs.h"

#include "xil_exception.h"  /* Xil_ExceptionDisable (fail-stop park) */
#include "xil_io.h"         /* Xil_In32, Xil_Out32 */
#include "xil_printf.h"     /* xil_printf (fail-stop report) */
#include "xparameters.h"    /* XPAR_AXI_UARTLITE_0_BASEADDR */
#include "xstatus.h"        /* XST_SUCCESS */
#include "xuartlite.h"      /* XUartLite_* */

#define KBD_UART_BASE       (XPAR_AXI_UARTLITE_0_BASEADDR)
#define KBD_PS2_BASE        (C64_PLAT_WIN0_BASE + C64_WIN_PS2_OFS)
#define KBD_PS2_REG(ofs)    (KBD_PS2_BASE + (uint32_t)(ofs))
#define KBD_RAW_MASK        (KEYBOARD_RAW_DEPTH - 1u)
#define KBD_UART_CHUNK      (16u)   /* = UART Lite receive FIFO depth */
#define KBD_CSI_MAX         (8u)    /* parameter characters kept from one CSI sequence */
#define KBD_PS2_E1_SKIP     (7u)    /* bytes after E1 in the Pause make sequence */
#define KBD_SET2_CODES      (0x84u) /* set 2 make codes 0x00..0x83 */

#define ASCII_CTRL_B        (0x02u)
#define ASCII_CTRL_C        (0x03u)
#define ASCII_BS            (0x08u)
#define ASCII_LF            (0x0Au)
#define ASCII_CR            (0x0Du)
#define ASCII_ESC           (0x1Bu)
#define ASCII_DEL           (0x7Fu)

#define PS2_PREFIX_E0       (0xE0u)
#define PS2_PREFIX_E1       (0xE1u)
#define PS2_PREFIX_BREAK    (0xF0u)
#define PS2_REPLY_BAT_OK    (0xAAu)
#define PS2_REPLY_ACK       (0xFAu)
#define PS2_REPLY_RESEND    (0xFEu)
#define PS2_REPLY_ERROR     (0xFFu)
#define PS2_REPLY_OVERRUN   (0x00u)

/* Set 2 make codes used by name. */
#define SC_LSHIFT           (0x12u)
#define SC_RSHIFT           (0x59u)
#define SC_CTRL             (0x14u)
#define SC_ALT              (0x11u)
#define SC_CAPS             (0x58u)
#define SC_ENTER            (0x5Au)
#define SC_BKSP             (0x66u)
#define SC_ESC              (0x76u)
#define SC_F1               (0x05u)
#define SC_F2               (0x06u)
#define SC_F3               (0x04u)
#define SC_F4               (0x0Cu)
#define SC_F5               (0x03u)
#define SC_F6               (0x0Bu)
#define SC_F7               (0x83u)
#define SC_F8               (0x0Au)
#define SC_KP_ENTER_E0      (0x5Au)
#define SC_KP_SLASH_E0      (0x4Au)
#define SC_HOME_E0          (0x6Cu)
#define SC_INSERT_E0        (0x70u)
#define SC_DELETE_E0        (0x71u)
#define SC_UP_E0            (0x75u)
#define SC_DOWN_E0          (0x72u)
#define SC_LEFT_E0          (0x6Bu)
#define SC_RIGHT_E0         (0x74u)
#define SC_FAKE_LSHIFT_E0   (0x12u)
#define SC_FAKE_RSHIFT_E0   (0x59u)

typedef struct
{
    uint8_t buf[KEYBOARD_RAW_DEPTH];
    volatile uint32_t head;   /* producer only */
    volatile uint32_t tail;   /* consumer only */
} kbd_ring_t;

typedef enum
{
    ESC_IDLE = 0,
    ESC_GOT_ESC,
    ESC_CSI,
    ESC_SS3
} kbd_esc_state_t;

/* US layout, set 2 make code -> ASCII, unshifted and shifted (0 = no character). */
static const uint8_t g_set2_plain[KBD_SET2_CODES] = {
    [0x0Eu] = '`', [0x16u] = '1', [0x1Eu] = '2', [0x26u] = '3', [0x25u] = '4', [0x2Eu] = '5',
    [0x36u] = '6', [0x3Du] = '7', [0x3Eu] = '8', [0x46u] = '9', [0x45u] = '0', [0x4Eu] = '-',
    [0x55u] = '=', [0x15u] = 'q', [0x1Du] = 'w', [0x24u] = 'e', [0x2Du] = 'r', [0x2Cu] = 't',
    [0x35u] = 'y', [0x3Cu] = 'u', [0x43u] = 'i', [0x44u] = 'o', [0x4Du] = 'p', [0x54u] = '[',
    [0x5Bu] = ']', [0x5Du] = '\\', [0x1Cu] = 'a', [0x1Bu] = 's', [0x23u] = 'd', [0x2Bu] = 'f',
    [0x34u] = 'g', [0x33u] = 'h', [0x3Bu] = 'j', [0x42u] = 'k', [0x4Bu] = 'l', [0x4Cu] = ';',
    [0x52u] = '\'', [0x1Au] = 'z', [0x22u] = 'x', [0x21u] = 'c', [0x2Au] = 'v', [0x32u] = 'b',
    [0x31u] = 'n', [0x3Au] = 'm', [0x41u] = ',', [0x49u] = '.', [0x4Au] = '/', [0x29u] = ' ',
    [0x70u] = '0', [0x69u] = '1', [0x72u] = '2', [0x7Au] = '3', [0x6Bu] = '4', [0x73u] = '5',
    [0x74u] = '6', [0x6Cu] = '7', [0x75u] = '8', [0x7Du] = '9', [0x71u] = '.', [0x79u] = '+',
    [0x7Bu] = '-', [0x7Cu] = '*'
};

static const uint8_t g_set2_shift[KBD_SET2_CODES] = {
    [0x0Eu] = '~', [0x16u] = '!', [0x1Eu] = '@', [0x26u] = '#', [0x25u] = '$', [0x2Eu] = '%',
    [0x36u] = '^', [0x3Du] = '&', [0x3Eu] = '*', [0x46u] = '(', [0x45u] = ')', [0x4Eu] = '_',
    [0x55u] = '+', [0x54u] = '{', [0x5Bu] = '}', [0x5Du] = '|', [0x4Cu] = ':', [0x52u] = '"',
    [0x41u] = '<', [0x49u] = '>', [0x4Au] = '?', [0x29u] = ' ',
    [0x70u] = '0', [0x69u] = '1', [0x72u] = '2', [0x7Au] = '3', [0x6Bu] = '4', [0x73u] = '5',
    [0x74u] = '6', [0x6Cu] = '7', [0x75u] = '8', [0x7Du] = '9', [0x71u] = '.', [0x79u] = '+',
    [0x7Bu] = '-', [0x7Cu] = '*'
};

/* Ctrl + 1..9, 0 and C= + 1..8: C64 colour / RVS codes (index = digit). */
static const uint8_t g_ctrl_digit[10] = {
    KEYBOARD_KEY_RVS_OFF, 0x90u, 0x05u, 0x1Cu, 0x9Fu, 0x9Cu, 0x1Eu, 0x1Fu, 0x9Eu,
    KEYBOARD_KEY_RVS_ON
};
static const uint8_t g_cbm_digit[10] = {
    0u, 0x81u, 0x95u, 0x96u, 0x97u, 0x98u, 0x99u, 0x9Au, 0x9Bu, 0u
};

static XUartLite g_uart;
static keyboard_input_mode_t g_mode;
static kbd_ring_t g_uart_raw;
static kbd_ring_t g_ps2_raw;
static volatile uint32_t g_ps2_err_seen;   /* producer: drain; consumer compares */
static uint32_t g_ps2_err_handled;
static uint8_t  g_queue[KEYBOARD_QUEUE_DEPTH];
static uint32_t g_q_head;
static uint32_t g_q_tail;
static kbd_ring_t g_cli_raw;
static int      g_cli_mode;
static keyboard_stats_t g_stats;

/* UART decoder state (main context). */
static kbd_esc_state_t g_esc;
static uint32_t g_esc_time;
static uint8_t  g_csi[KBD_CSI_MAX + 1u];
static uint32_t g_csi_len;
static int      g_last_cr;

/* PS/2 decoder state (main context). */
static int      g_ps2_e0;
static int      g_ps2_break;
static uint32_t g_ps2_skip;
static int      g_lshift;
static int      g_rshift;
static int      g_ctrl_l;
static int      g_ctrl_r;
static int      g_alt_l;
static int      g_alt_r;
static int      g_caps;
static int      g_lower_set;

/*
 * kbd_fail -- fail-stop: report the failing API and park.
 * Steps:
 *   1. Print the API name and its return code on the console.
 *   2. Disable interrupts and park the CPU.
 * Returns: never.
 */
static void kbd_fail(const char *api, int code)
{
    xil_printf("FATAL keyboard: %s returned %d\r\n", api, code);
    Xil_ExceptionDisable();
    for (;;) {
    }
}

/*
 * ring_put -- producer side of a raw byte ring.
 * Returns: 1 stored, 0 ring full (byte dropped; the caller counts it).
 */
static int ring_put(kbd_ring_t *r, uint8_t b)
{
    uint32_t head = r->head;

    if (head - r->tail >= KEYBOARD_RAW_DEPTH) {
        return 0;
    }
    r->buf[head & KBD_RAW_MASK] = b;
    r->head = head + 1u;
    return 1;
}

/*
 * ring_get -- consumer side of a raw byte ring.
 * Returns: 1 and *b set, or 0 when empty.
 */
static int ring_get(kbd_ring_t *r, uint8_t *b)
{
    uint32_t tail = r->tail;

    if (tail == r->head) {
        return 0;
    }
    *b = r->buf[tail & KBD_RAW_MASK];
    r->tail = tail + 1u;
    return 1;
}

/*
 * queue_key -- append one PETSCII key to the key queue.
 * Returns: nothing; a full queue drops the key and counts it.
 */
static void queue_key(uint8_t petscii)
{
    if (g_q_head - g_q_tail >= KEYBOARD_QUEUE_DEPTH) {
        g_stats.keys_dropped++;
        return;
    }
    g_queue[g_q_head % KEYBOARD_QUEUE_DEPTH] = petscii;
    g_q_head++;
}

/*
 * ascii_to_petscii -- printable ASCII to PETSCII.
 * Steps:
 *   1. $20-$5F map to themselves ('\' is the pound sign, '^' up-arrow, '_' left-arrow).
 *   2. Lower-case letters map to the unshifted C64 letters $41-$5A.
 *   3. '`', '{', '|', '}', '~' and control bytes have no PETSCII key.
 * Returns: the PETSCII code, or 0 for none.
 */
static uint8_t ascii_to_petscii(uint8_t c)
{
    if (c >= 0x20u && c <= 0x5Fu) {
        return c;
    }
    if (c >= 'a' && c <= 'z') {
        return (uint8_t)(c - 0x20u);
    }
    return 0u;
}

/*
 * drain_uart -- move the UART receive FIFO into the raw ring.
 * Steps:
 *   1. Read up to KBD_UART_CHUNK bytes with XUartLite_Recv (non-blocking).
 *   2. Store them; repeat while a full chunk came back, at most twice the FIFO depth.
 *   3. Note receive errors from the driver statistics.
 * Returns: nothing.
 */
static void drain_uart(void)
{
    uint8_t chunk[KBD_UART_CHUNK];
    XUartLite_Stats st;

    for (uint32_t pass = 0u; pass < 2u; pass++) {
        unsigned int n = XUartLite_Recv(&g_uart, chunk, KBD_UART_CHUNK);
        for (unsigned int i = 0u; i < n; i++) {
            if (!ring_put(&g_uart_raw, chunk[i])) {
                g_stats.raw_dropped++;
            }
        }
        if (n < KBD_UART_CHUNK) {
            break;
        }
    }
    XUartLite_GetStats(&g_uart, &st);
    g_stats.uart_errors = st.ReceiveOverrunErrors + st.ReceiveParityErrors +
                          st.ReceiveFramingErrors;
}

/*
 * drain_ps2 -- move the ps2_rx FIFO into the raw ring and collect its error flags.
 * Steps:
 *   1. While STATUS shows data (at most C64_PS2_FIFO_DEPTH reads), pop DATA and store the
 *      byte when its valid bit is set.
 *   2. If parity, overflow or frame flags are set, clear them (W1C), count them and bump
 *      g_ps2_err_seen so the decoder drops its partial sequence.
 * Returns: nothing.
 */
static void drain_ps2(void)
{
    const uint32_t err_mask = (1u << C64_PS2_STATUS_PARITY_BIT) |
                              (1u << C64_PS2_STATUS_OVERFLOW_BIT) |
                              (1u << C64_PS2_STATUS_FRAME_BIT);
    uint32_t status;

    for (uint32_t i = 0u; i < C64_PS2_FIFO_DEPTH; i++) {
        uint32_t data;
        if ((Xil_In32(KBD_PS2_REG(C64_PS2_STATUS_OFS)) & (1u << C64_PS2_STATUS_AVAIL_BIT)) == 0u) {
            break;
        }
        data = Xil_In32(KBD_PS2_REG(C64_PS2_DATA_OFS));
        if ((data & (1u << C64_PS2_DATA_VALID_BIT)) != 0u && !ring_put(&g_ps2_raw, (uint8_t)data)) {
            g_stats.raw_dropped++;
        }
    }
    status = Xil_In32(KBD_PS2_REG(C64_PS2_STATUS_OFS)) & err_mask;
    if (status != 0u) {
        Xil_Out32(KBD_PS2_REG(C64_PS2_STATUS_OFS), status);
        g_stats.ps2_errors++;
        g_ps2_err_seen++;
    }
}

/*
 * keyboard_init -- set up the UART receive path and the PS/2 receiver.
 * Steps:
 *   1. XUartLite_LookupConfig / XUartLite_CfgInitialize for axi_uartlite_0 (fail-stop).
 *   2. Clear the ps2_rx error flags; in IRQ mode enable the ps2_rx and UART interrupts
 *      (the caller connects keyboard_ps2_isr / keyboard_uart_isr to the INTC).
 *   3. Reset rings, queue and decoder state; start in C64 (non-CLI) mode.
 * Returns: nothing.
 */
void keyboard_init(keyboard_input_mode_t mode)
{
    XUartLite_Config *cfg;
    int st;

    g_mode = mode;
    cfg = XUartLite_LookupConfig(KBD_UART_BASE);
    if (cfg == NULL) {
        kbd_fail("XUartLite_LookupConfig", 0);
    }
    st = XUartLite_CfgInitialize(&g_uart, cfg, cfg->RegBaseAddr);
    if (st != XST_SUCCESS) {
        kbd_fail("XUartLite_CfgInitialize", st);
    }
    Xil_Out32(KBD_PS2_REG(C64_PS2_STATUS_OFS),
              (1u << C64_PS2_STATUS_PARITY_BIT) | (1u << C64_PS2_STATUS_OVERFLOW_BIT) |
              (1u << C64_PS2_STATUS_FRAME_BIT));
    Xil_Out32(KBD_PS2_REG(C64_PS2_CTRL_OFS),
              (mode == KEYBOARD_INPUT_IRQ) ? (1u << C64_PS2_CTRL_IRQ_EN_BIT) : 0u);
    if (mode == KEYBOARD_INPUT_IRQ) {
        XUartLite_EnableInterrupt(&g_uart);
    }
    g_uart_raw.head = g_uart_raw.tail = 0u;
    g_ps2_raw.head = g_ps2_raw.tail = 0u;
    g_cli_raw.head = g_cli_raw.tail = 0u;
    g_q_head = g_q_tail = 0u;
    g_esc = ESC_IDLE;
    g_cli_mode = 0;
}

/*
 * keyboard_uart_isr -- UART Lite interrupt (IRQ mode): drain the receive FIFO.
 * Returns: nothing.
 */
void keyboard_uart_isr(void *ref)
{
    (void)ref;
    drain_uart();
}

/*
 * keyboard_ps2_isr -- ps2_rx interrupt (IRQ mode): drain the scan code FIFO.
 * Returns: nothing.
 */
void keyboard_ps2_isr(void *ref)
{
    (void)ref;
    drain_ps2();
}

/*
 * csi_param -- first numeric parameter of the collected CSI sequence.
 * Returns: the number, or 0 when absent.
 */
static uint32_t csi_param(uint32_t index)
{
    uint32_t value = 0u;
    uint32_t field = 0u;

    for (uint32_t i = 0u; i < g_csi_len; i++) {
        if (g_csi[i] == ';') {
            field++;
        } else if (field == index && g_csi[i] >= '0' && g_csi[i] <= '9') {
            value = value * 10u + (uint32_t)(g_csi[i] - '0');
        }
    }
    return value;
}

/*
 * csi_final -- act on a complete CSI sequence (ESC [ params final).
 * Steps:
 *   1. A/B/C/D: cursor keys. H: Home (modifier 2 = Shift -> CLR). P/Q/R/S: F1-F4.
 *   2. '~': 1/7 Home, 2 Insert -> INST, 3 Delete -> DEL, 11-15 F1-F5, 17-19 F6-F8.
 *   3. Anything else is ignored.
 * Returns: nothing.
 */
static void csi_final(uint8_t f)
{
    static const uint8_t fkeys[8] = {
        KEYBOARD_KEY_F1, KEYBOARD_KEY_F2, KEYBOARD_KEY_F3, KEYBOARD_KEY_F4,
        KEYBOARD_KEY_F5, KEYBOARD_KEY_F6, KEYBOARD_KEY_F7, KEYBOARD_KEY_F8
    };
    uint32_t p = csi_param(0u);

    switch (f) {
    case 'A': queue_key(KEYBOARD_KEY_UP); break;
    case 'B': queue_key(KEYBOARD_KEY_DOWN); break;
    case 'C': queue_key(KEYBOARD_KEY_RIGHT); break;
    case 'D': queue_key(KEYBOARD_KEY_LEFT); break;
    case 'H': queue_key((csi_param(1u) == 2u) ? KEYBOARD_KEY_CLR : KEYBOARD_KEY_HOME); break;
    case 'P': queue_key(KEYBOARD_KEY_F1); break;
    case 'Q': queue_key(KEYBOARD_KEY_F2); break;
    case 'R': queue_key(KEYBOARD_KEY_F3); break;
    case 'S': queue_key(KEYBOARD_KEY_F4); break;
    case '~':
        if (p == 1u || p == 7u) {
            queue_key((csi_param(1u) == 2u) ? KEYBOARD_KEY_CLR : KEYBOARD_KEY_HOME);
        } else if (p == 2u) {
            queue_key(KEYBOARD_KEY_INST);
        } else if (p == 3u) {
            queue_key(KEYBOARD_KEY_DEL);
        } else if (p >= 11u && p <= 15u) {
            queue_key(fkeys[p - 11u]);
        } else if (p >= 17u && p <= 19u) {
            queue_key(fkeys[p - 12u]);
        }
        break;
    default:
        break;
    }
}

/*
 * uart_plain -- one UART byte outside an escape sequence (C64 mode).
 * Steps:
 *   1. CR -> RETURN; LF -> RETURN unless it follows a CR; BS/DEL -> DEL;
 *      Ctrl-C -> RUN/STOP; ESC starts a sequence (timestamped).
 *   2. Printable ASCII -> PETSCII; other control bytes are ignored.
 * Returns: nothing.
 */
static void uart_plain(uint8_t c, uint32_t now_ms)
{
    int was_cr = g_last_cr;
    uint8_t p;

    g_last_cr = (c == ASCII_CR);
    switch (c) {
    case ASCII_CR:
        queue_key(KEYBOARD_KEY_RETURN);
        return;
    case ASCII_LF:
        if (!was_cr) {
            queue_key(KEYBOARD_KEY_RETURN);
        }
        return;
    case ASCII_BS:
    case ASCII_DEL:
        queue_key(KEYBOARD_KEY_DEL);
        return;
    case ASCII_CTRL_C:
        queue_key(KEYBOARD_KEY_RUN_STOP);
        return;
    case ASCII_ESC:
        g_esc = ESC_GOT_ESC;
        g_esc_time = now_ms;
        return;
    default:
        break;
    }
    p = ascii_to_petscii(c);
    if (p != 0u) {
        queue_key(p);
    }
}

/*
 * uart_byte -- feed one UART byte to the decoder.
 * Steps:
 *   1. Ctrl-B toggles CLI mode (reported through *events, never queued).
 *   2. In CLI mode pass the byte to the CLI ring.
 *   3. Otherwise run the ESC / CSI / SS3 state machine; a byte that cannot continue a
 *      sequence after a lone ESC turns the ESC into RUN/STOP and is decoded normally.
 * Returns: nothing.
 */
static void uart_byte(uint8_t c, uint32_t now_ms, uint32_t *events)
{
    if (c == ASCII_CTRL_B) {
        g_cli_mode = !g_cli_mode;
        g_esc = ESC_IDLE;
        *events |= KEYBOARD_EVENT_CLI_TOGGLE;
        return;
    }
    if (g_cli_mode) {
        if (!ring_put(&g_cli_raw, c)) {
            g_stats.keys_dropped++;
        }
        return;
    }
    switch (g_esc) {
    case ESC_GOT_ESC:
        if (c == '[') {
            g_esc = ESC_CSI;
            g_csi_len = 0u;
        } else if (c == 'O') {
            g_esc = ESC_SS3;
        } else {
            g_esc = ESC_IDLE;
            queue_key(KEYBOARD_KEY_RUN_STOP);
            uart_plain(c, now_ms);
        }
        break;
    case ESC_CSI:
        if (c >= 0x40u && c <= 0x7Eu) {
            g_esc = ESC_IDLE;
            csi_final(c);
        } else if (g_csi_len < KBD_CSI_MAX) {
            g_csi[g_csi_len++] = c;
        }
        break;
    case ESC_SS3:
        g_esc = ESC_IDLE;
        g_csi_len = 0u;
        csi_final(c);
        break;
    default:
        uart_plain(c, now_ms);
        break;
    }
}

/*
 * ps2_reset_sequence -- drop a partial E0 / F0 / E1 sequence (after a receive error).
 * Returns: nothing.
 */
static void ps2_reset_sequence(void)
{
    g_ps2_e0 = 0;
    g_ps2_break = 0;
    g_ps2_skip = 0u;
}

/*
 * ps2_extended -- an E0-prefixed make code.
 * Returns: nothing.
 */
static void ps2_extended(uint8_t sc, int shift)
{
    switch (sc) {
    case SC_UP_E0:       queue_key(KEYBOARD_KEY_UP); break;
    case SC_DOWN_E0:     queue_key(KEYBOARD_KEY_DOWN); break;
    case SC_LEFT_E0:     queue_key(KEYBOARD_KEY_LEFT); break;
    case SC_RIGHT_E0:    queue_key(KEYBOARD_KEY_RIGHT); break;
    case SC_HOME_E0:     queue_key(shift ? KEYBOARD_KEY_CLR : KEYBOARD_KEY_HOME); break;
    case SC_INSERT_E0:   queue_key(KEYBOARD_KEY_INST); break;
    case SC_DELETE_E0:   queue_key(KEYBOARD_KEY_DEL); break;
    case SC_KP_ENTER_E0: queue_key(shift ? KEYBOARD_KEY_SHIFT_RETURN : KEYBOARD_KEY_RETURN); break;
    case SC_KP_SLASH_E0: queue_key('/'); break;
    default:             break;   /* GUI, Apps, End, Page keys, Print Screen: none */
    }
}

/*
 * is_top_row_digit -- scan code of a main-block digit key (not the keypad).
 * Returns: 1 for the keys 1..9, 0; else 0.
 */
static int is_top_row_digit(uint8_t sc)
{
    static const uint8_t digits[10] = {
        0x45u, 0x16u, 0x1Eu, 0x26u, 0x25u, 0x2Eu, 0x36u, 0x3Du, 0x3Eu, 0x46u
    };
    for (uint32_t i = 0u; i < 10u; i++) {
        if (digits[i] == sc) {
            return 1;
        }
    }
    return 0;
}

/*
 * ps2_make -- a non-extended make code (modifiers already handled).
 * Steps:
 *   1. Named keys: RETURN, DEL/INST, RUN/STOP, F1-F8.
 *   2. Ctrl + digit: colour / RVS codes; Alt (C=) + digit: second colour row.
 *   3. Letters: shifted PETSCII ($C1-$DA) when Shift XOR Caps Lock, else $41-$5A.
 *   4. Other keys: US layout ASCII (shifted table with Shift) -> PETSCII.
 * Returns: nothing.
 */
static void ps2_make(uint8_t sc, int shift, int ctrl, int alt)
{
    uint8_t ascii;

    switch (sc) {
    case SC_ENTER: queue_key(shift ? KEYBOARD_KEY_SHIFT_RETURN : KEYBOARD_KEY_RETURN); return;
    case SC_BKSP:  queue_key(shift ? KEYBOARD_KEY_INST : KEYBOARD_KEY_DEL); return;
    case SC_ESC:   queue_key(KEYBOARD_KEY_RUN_STOP); return;
    case SC_F1:    queue_key(KEYBOARD_KEY_F1); return;
    case SC_F2:    queue_key(KEYBOARD_KEY_F2); return;
    case SC_F3:    queue_key(KEYBOARD_KEY_F3); return;
    case SC_F4:    queue_key(KEYBOARD_KEY_F4); return;
    case SC_F5:    queue_key(KEYBOARD_KEY_F5); return;
    case SC_F6:    queue_key(KEYBOARD_KEY_F6); return;
    case SC_F7:    queue_key(KEYBOARD_KEY_F7); return;
    case SC_F8:    queue_key(KEYBOARD_KEY_F8); return;
    default:       break;
    }
    if (sc >= KBD_SET2_CODES) {
        return;
    }
    ascii = g_set2_plain[sc];
    if ((ctrl || alt) && is_top_row_digit(sc)) {
        uint8_t code = ctrl ? g_ctrl_digit[ascii - '0'] : g_cbm_digit[ascii - '0'];
        if (code != 0u) {
            queue_key(code);
        }
        return;
    }
    if (ctrl || alt) {
        return;
    }
    if (ascii >= 'a' && ascii <= 'z') {
        int shifted = (shift != 0) != (g_caps != 0);
        queue_key((uint8_t)(ascii - 'a' + (shifted ? 0xC1u : 0x41u)));
        return;
    }
    if (shift && g_set2_shift[sc] != 0u) {
        ascii = g_set2_shift[sc];
    }
    ascii = ascii_to_petscii(ascii);
    if (ascii != 0u) {
        queue_key(ascii);
    }
}

/*
 * ps2_byte -- feed one scan code byte to the set 2 decoder.
 * Steps:
 *   1. Skip the rest of an E1 (Pause) sequence; ignore keyboard replies (AA, FA, FE, FF, 00).
 *   2. Latch E0 and F0 prefixes.
 *   3. Update Shift / Ctrl / Alt on make and break; Caps Lock toggles on make; Alt with
 *      Shift (either order) switches the character set like Shift + C= on a C64.
 *   4. Decode other make codes; break codes end there.
 * Returns: nothing.
 */
static void ps2_byte(uint8_t b)
{
    int make;
    int ext;

    if (g_ps2_skip > 0u) {
        g_ps2_skip--;
        return;
    }
    switch (b) {
    case PS2_PREFIX_E1:     g_ps2_skip = KBD_PS2_E1_SKIP; return;
    case PS2_PREFIX_E0:     g_ps2_e0 = 1; return;
    case PS2_PREFIX_BREAK:  g_ps2_break = 1; return;
    case PS2_REPLY_BAT_OK:
    case PS2_REPLY_ACK:
    case PS2_REPLY_RESEND:
    case PS2_REPLY_ERROR:
    case PS2_REPLY_OVERRUN: ps2_reset_sequence(); return;
    default:                break;
    }
    make = !g_ps2_break;
    ext = g_ps2_e0;
    g_ps2_e0 = 0;
    g_ps2_break = 0;

    if (ext && (b == SC_FAKE_LSHIFT_E0 || b == SC_FAKE_RSHIFT_E0)) {
        return;
    }
    if (b == SC_LSHIFT || b == SC_RSHIFT) {
        int was = g_lshift || g_rshift;
        if (b == SC_LSHIFT) {
            g_lshift = make;
        } else {
            g_rshift = make;
        }
        if (make && !was && (g_alt_l || g_alt_r)) {
            g_lower_set = !g_lower_set;
            queue_key(g_lower_set ? KEYBOARD_KEY_LOWER_CASE : KEYBOARD_KEY_UPPER_CASE);
        }
        return;
    }
    if (b == SC_CTRL) {
        if (ext) {
            g_ctrl_r = make;
        } else {
            g_ctrl_l = make;
        }
        return;
    }
    if (b == SC_ALT) {
        int was = g_alt_l || g_alt_r;
        if (ext) {
            g_alt_r = make;
        } else {
            g_alt_l = make;
        }
        if (make && !was && (g_lshift || g_rshift)) {
            g_lower_set = !g_lower_set;
            queue_key(g_lower_set ? KEYBOARD_KEY_LOWER_CASE : KEYBOARD_KEY_UPPER_CASE);
        }
        return;
    }
    if (!make) {
        return;
    }
    if (!ext && b == SC_CAPS) {
        g_caps = !g_caps;
        return;
    }
    if (ext) {
        ps2_extended(b, g_lshift || g_rshift);
    } else {
        ps2_make(b, g_lshift || g_rshift, g_ctrl_l || g_ctrl_r, g_alt_l || g_alt_r);
    }
}

/*
 * keyboard_poll -- run both decoders (main context; call every loop iteration).
 * Steps:
 *   1. In polled mode drain the UART and PS/2 hardware FIFOs.
 *   2. Decode the raw UART bytes (CLI toggle, escape sequences) and the PS/2 bytes
 *      (dropping a partial sequence after a ps2_rx error), each bounded by the ring size.
 *   3. Turn a lone ESC older than KEYBOARD_ESC_TIMEOUT_MS into RUN/STOP; drop an
 *      unfinished CSI/SS3 sequence after the same time.
 * Returns: KEYBOARD_EVENT_* bits seen in this call.
 */
uint32_t keyboard_poll(uint32_t now_ms)
{
    uint32_t events = 0u;
    uint8_t b;

    if (g_mode == KEYBOARD_INPUT_POLL) {
        drain_uart();
        drain_ps2();
    }
    for (uint32_t i = 0u; i < KEYBOARD_RAW_DEPTH && ring_get(&g_uart_raw, &b); i++) {
        uart_byte(b, now_ms, &events);
    }
    if (g_ps2_err_seen != g_ps2_err_handled) {
        g_ps2_err_handled = g_ps2_err_seen;
        ps2_reset_sequence();
    }
    for (uint32_t i = 0u; i < KEYBOARD_RAW_DEPTH && ring_get(&g_ps2_raw, &b); i++) {
        ps2_byte(b);
    }
    if (g_esc != ESC_IDLE && (uint32_t)(now_ms - g_esc_time) >= KEYBOARD_ESC_TIMEOUT_MS) {
        if (g_esc == ESC_GOT_ESC) {
            queue_key(KEYBOARD_KEY_RUN_STOP);
        }
        g_esc = ESC_IDLE;
    }
    return events;
}

/*
 * keyboard_getkey -- take the oldest PETSCII key.
 * Returns: 1 and *petscii set, or 0 when the queue is empty.
 */
int keyboard_getkey(uint8_t *petscii)
{
    if (g_q_tail == g_q_head) {
        return 0;
    }
    *petscii = g_queue[g_q_tail % KEYBOARD_QUEUE_DEPTH];
    g_q_tail++;
    return 1;
}

/*
 * keyboard_flush -- discard every queued key (as the C64 does after RUN/STOP).
 * Returns: nothing.
 */
void keyboard_flush(void)
{
    g_q_tail = g_q_head;
}

/*
 * keyboard_cli_mode -- UART bytes go to the CLI instead of the C64.
 * Returns: 1 in CLI mode, else 0.
 */
int keyboard_cli_mode(void)
{
    return g_cli_mode;
}

/*
 * keyboard_set_cli_mode -- select CLI or C64 mode for the UART.
 * Returns: nothing.
 */
void keyboard_set_cli_mode(int on)
{
    g_cli_mode = on ? 1 : 0;
    g_esc = ESC_IDLE;
}

/*
 * keyboard_cli_getc -- next raw UART byte for the engineering CLI (CLI mode).
 * Returns: 1 and *byte set, or 0 when none is waiting.
 */
int keyboard_cli_getc(uint8_t *byte)
{
    return ring_get(&g_cli_raw, byte);
}

/*
 * keyboard_get_stats -- copy the drop and error counters.
 * Returns: nothing.
 */
void keyboard_get_stats(keyboard_stats_t *stats)
{
    *stats = g_stats;
}

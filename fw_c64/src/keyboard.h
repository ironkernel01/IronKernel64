/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: keyboard.h
 * Role: the C64 keyboard: one PETSCII key queue fed by the UART console (ANSI terminal) and
 *   by the USB keyboard on J15 (PS/2 scan code set 2 through the ps2_rx block).
 *
 * Ownership: keyboard.c is the only file that reads the UART Lite receive path
 *   (axi_uartlite_0, XUartLite driver) and the ps2_rx registers (C64_PLAT_WIN0_BASE +
 *   C64_WIN_PS2_OFS). The UART transmit path stays with the BSP console (xil_printf).
 *
 * Contract:
 *   - Keys come out of keyboard_getkey() as PETSCII codes (KEYBOARD_KEY_* for the control
 *     keys), oldest first. The queue holds KEYBOARD_QUEUE_DEPTH keys; further keys are
 *     dropped and counted.
 *   - UART: printable ASCII maps to PETSCII with letters folded to the unshifted C64 letter
 *     (a terminal user types text, not graphics). ANSI/VT sequences give the cursor keys,
 *     Home (CLR/HOME; Shift+Home = CLR), Insert (INST), Delete (DEL) and F1-F8. Backspace
 *     (0x08/0x7F) = DEL, CR = RETURN, Ctrl-C = RUN/STOP. A lone ESC becomes RUN/STOP when
 *     no sequence byte follows within KEYBOARD_ESC_TIMEOUT_MS.
 *   - Ctrl-B (0x02) on the UART toggles CLI mode: it is never queued; keyboard_poll()
 *     reports it with KEYBOARD_EVENT_CLI_TOGGLE. In CLI mode the UART bytes go raw to
 *     keyboard_cli_getc() (the engineering CLI) and the PS/2 keyboard still feeds the
 *     C64 queue.
 *   - PS/2: make/break and E0-prefixed codes, Shift/Ctrl/Alt state, Caps Lock as the C64
 *     SHIFT LOCK (latched shift on letters), US layout. F1-F8, cursor keys, Home =
 *     CLR/HOME, Esc = RUN/STOP, Insert = INST, Backspace/Delete = DEL. Ctrl+1..8 and
 *     Ctrl+9/0 give the C64 colour and RVS ON/OFF codes, Alt (the C= key) + 1..8 the
 *     second colour row, Alt + Shift switches the character set. Pause/Break (E1 prefix)
 *     and Print Screen are ignored.
 *   - Input sources are drained either by the ISRs (KEYBOARD_INPUT_IRQ: the caller
 *     connects keyboard_uart_isr and keyboard_ps2_isr to the INTC) or by keyboard_poll()
 *     (KEYBOARD_INPUT_POLL). Both cases use single-producer/single-consumer byte rings.
 * Headers hold contracts and constants; per-function commentary lives in the .c files.
 */
#ifndef KEYBOARD_H
#define KEYBOARD_H

#include <stdint.h> /* uint8_t, uint32_t */

#define KEYBOARD_QUEUE_DEPTH      (32u)   /* PETSCII keys (C64: 10) */
#define KEYBOARD_RAW_DEPTH        (256u)  /* raw bytes per input source, power of two */
#define KEYBOARD_ESC_TIMEOUT_MS   (100u)  /* lone ESC -> RUN/STOP */

/* PETSCII control keys. */
#define KEYBOARD_KEY_RUN_STOP     (0x03u)
#define KEYBOARD_KEY_RETURN       (0x0Du)
#define KEYBOARD_KEY_SHIFT_RETURN (0x8Du)
#define KEYBOARD_KEY_LOWER_CASE   (0x0Eu)
#define KEYBOARD_KEY_UPPER_CASE   (0x8Eu)
#define KEYBOARD_KEY_DOWN         (0x11u)
#define KEYBOARD_KEY_UP           (0x91u)
#define KEYBOARD_KEY_RIGHT        (0x1Du)
#define KEYBOARD_KEY_LEFT         (0x9Du)
#define KEYBOARD_KEY_RVS_ON       (0x12u)
#define KEYBOARD_KEY_RVS_OFF      (0x92u)
#define KEYBOARD_KEY_HOME         (0x13u)
#define KEYBOARD_KEY_CLR          (0x93u)
#define KEYBOARD_KEY_DEL          (0x14u)
#define KEYBOARD_KEY_INST         (0x94u)
#define KEYBOARD_KEY_F1           (0x85u)
#define KEYBOARD_KEY_F3           (0x86u)
#define KEYBOARD_KEY_F5           (0x87u)
#define KEYBOARD_KEY_F7           (0x88u)
#define KEYBOARD_KEY_F2           (0x89u)
#define KEYBOARD_KEY_F4           (0x8Au)
#define KEYBOARD_KEY_F6           (0x8Bu)
#define KEYBOARD_KEY_F8           (0x8Cu)

/* keyboard_poll() event bits. */
#define KEYBOARD_EVENT_CLI_TOGGLE (1u << 0)

typedef enum
{
    KEYBOARD_INPUT_POLL = 0,
    KEYBOARD_INPUT_IRQ  = 1
} keyboard_input_mode_t;

typedef struct
{
    uint32_t keys_dropped;     /* PETSCII queue or CLI byte ring full */
    uint32_t raw_dropped;      /* raw byte ring full (UART or PS/2) */
    uint32_t ps2_errors;       /* parity / frame / overflow flags seen in ps2_rx */
    uint32_t uart_errors;      /* UART Lite overrun / framing / parity flags seen */
} keyboard_stats_t;

void     keyboard_init(keyboard_input_mode_t mode);
void     keyboard_uart_isr(void *ref);
void     keyboard_ps2_isr(void *ref);
uint32_t keyboard_poll(uint32_t now_ms);
int      keyboard_getkey(uint8_t *petscii);
void     keyboard_flush(void);
int      keyboard_cli_mode(void);
void     keyboard_set_cli_mode(int on);
int      keyboard_cli_getc(uint8_t *byte);
void     keyboard_get_stats(keyboard_stats_t *stats);

#endif /* KEYBOARD_H */

/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: main.c
 * Role: core 0 boot and main loop: platform bring-up in a fixed order with fail-stop checks,
 *   boot banner on the UART, then the superloop (keyboard, BASIC shell or the engineering CLI (cli.c)).
 *
 * Interrupt wiring (axi_intc_0, fpga/bd/c64_bd.tcl; input = bit of the INTC intr vector):
 *   0 sid_audio_out low-level   -> audio_out_isr
 *   1 c64_video vsync           -> video_vsync_isr
 *   2 ps2_rx                    -> keyboard_ps2_isr
 *   8 axi_timer_0 (1 ms tick)   -> XTmrCtr_InterruptHandler -> tick_cb (millisecond counter)
 *   9 axi_uartlite_0            -> keyboard_uart_isr
 *   10 mailbox_0, 11 axi_iic_0  -> not connected (drive_client and the codec driver poll)
 * Init order: INTC + timer, UART/keyboard, DDR3 probe, ADAU1761, audio_out, video, c64screen,
 *   basic, drive_client, oled; interrupts are enabled globally last.
 * Fail-stop: a failed step prints its name and status on the UART and parks the core with
 *   interrupts off.
 */
#include <stddef.h>
#include <stdint.h>

#include "adau1761.h"
#include "audio_out.h"
#include "basic.h"
#include "c64_platform.h"
#include "c64_regs.h"
#include "c64screen.h"
#include "cli.h"
#include "ddr_probe.h"
#include "drive_client.h"
#include "keyboard.h"
#include "oled.h"
#include "oled_ui.h"
#include "player.h"
#include "video.h"

#include "xil_exception.h"  /* Xil_Exception* */
#include "xil_io.h"         /* Xil_In32 */
#include "xil_printf.h"     /* xil_printf, outbyte */
#include "xintc.h"          /* XIntc_* */
#include "xparameters.h"    /* XPAR_AXI_INTC_0_BASEADDR, XPAR_AXI_TIMER_0_* */
#include "xstatus.h"        /* XST_SUCCESS */
#include "xtmrctr.h"        /* XTmrCtr_* */

#define IRQ_AUDIO            (0u)
#define IRQ_VSYNC            (1u)
#define IRQ_PS2              (2u)
#define IRQ_TIMER            (8u)
#define IRQ_UART             (9u)

#define TICK_TIMER           (0u)                 /* axi_timer_0 counter 0 */
#define TICK_COUNTS          (XPAR_AXI_TIMER_0_CLOCK_FREQUENCY / 1000u)   /* 1 ms */
#define LOAD_BUF_BYTES       (65536u)
#define SYS_REG(ofs)         (C64_PLAT_WIN0_BASE + C64_WIN_SYS_OFS + (uint32_t)(ofs))
#define SYS_DIRTY_MASK       (1u << 0)
#define MIB                  (1048576u)
#define CLI_NOTICE           "CLI not built yet; Ctrl-B returns\r\n"

static XIntc  g_intc;
static XTmrCtr g_tmr;
static volatile uint32_t g_ms;
static ddr_probe_result_t g_ddr;
static uint8_t g_load_buf[LOAD_BUF_BYTES];
#define BOOT_DRIVE_WAIT_PINGS (12u)                /* x DRIVE_CLIENT_PING_TIMEOUT_MS = 3 s */
#define LOG1_DRAIN_MAX       (64u)                /* core 1 log bytes printed per main-loop pass */
#define LOG1_PREFIX          "[1541] "
static int g_log1_at_line_start = 1;   /* next core 1 log byte starts a line */

/*
 * log1_put -- UART sink of the core 1 log drain: "[1541] " before the first byte of each line.
 * Returns: nothing.
 */
static void log1_put(char c)
{
    if (g_log1_at_line_start) {
        const char *p;
        for (p = LOG1_PREFIX; *p != '\0'; p++) {
            outbyte(*p);
        }
        g_log1_at_line_start = 0;
    }
    outbyte(c);
    if (c == '\n') {
        g_log1_at_line_start = 1;
    }
}

/*
 * fail_stop -- report a failed init step and park the core.
 * Returns: never.
 */
static void fail_stop(const char *what, int status)
{
    Xil_ExceptionDisable();
    xil_printf("\r\nFAIL: %s (%d)\r\n", what, status);
    for (;;) {
    }
}

/*
 * tick_cb -- 1 ms timer callback (called from XTmrCtr_InterruptHandler).
 * Returns: nothing.
 */
static void tick_cb(void *ref, uint8_t timer_no)
{
    (void)ref;
    (void)timer_no;
    g_ms++;
}

/*
 * intc_trampoline -- machine external interrupt entry.
 * Returns: nothing.
 */
static void intc_trampoline(void *ref)
{
    XIntc_InterruptHandler((XIntc *)ref);
}

/*
 * connect -- connect one handler to an INTC input and enable it.
 * Returns: nothing; fail-stop on error.
 */
static void connect(uint8_t id, XInterruptHandler handler, void *ref, const char *name)
{
    const int st = XIntc_Connect(&g_intc, id, handler, ref);

    if (st != XST_SUCCESS) {
        fail_stop(name, st);
    }
    XIntc_Enable(&g_intc, id);
}

/*
 * platform_init -- interrupt controller and 1 ms tick timer.
 * Steps:
 *   1. XIntc_Initialize (axi_intc_0); XTmrCtr_Initialize (axi_timer_0), counter 0 down-counting
 *      auto-reload every millisecond with interrupt.
 *   2. Connect the timer on input 8, start the INTC in real mode, register it as the machine
 *      external interrupt handler (interrupts stay off until main enables them).
 * Returns: nothing; fail-stop on error.
 */
static void platform_init(void)
{
    int st;

    Xil_ExceptionDisable();
    st = XIntc_Initialize(&g_intc, XPAR_AXI_INTC_0_BASEADDR);
    if (st != XST_SUCCESS) {
        fail_stop("XIntc_Initialize", st);
    }
    st = XTmrCtr_Initialize(&g_tmr, XPAR_AXI_TIMER_0_BASEADDR);
    if (st != XST_SUCCESS && st != XST_DEVICE_IS_STARTED) {
        fail_stop("XTmrCtr_Initialize", st);
    }
    XTmrCtr_Stop(&g_tmr, TICK_TIMER);
    XTmrCtr_SetHandler(&g_tmr, tick_cb, NULL);
    XTmrCtr_SetOptions(&g_tmr, TICK_TIMER,
                       XTC_INT_MODE_OPTION | XTC_AUTO_RELOAD_OPTION | XTC_DOWN_COUNT_OPTION);
    XTmrCtr_SetResetValue(&g_tmr, TICK_TIMER, TICK_COUNTS - 1u);
    XTmrCtr_Reset(&g_tmr, TICK_TIMER);
    connect(IRQ_TIMER, (XInterruptHandler)XTmrCtr_InterruptHandler, &g_tmr, "connect timer irq");
    st = XIntc_Start(&g_intc, XIN_REAL_MODE);
    if (st != XST_SUCCESS) {
        fail_stop("XIntc_Start", st);
    }
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT, intc_trampoline, &g_intc);
    XTmrCtr_Start(&g_tmr, TICK_TIMER);
}

/*
 * drive_ready -- OLED idle screen probe: the drive answers a ping.
 * Returns: 1 when present, else 0.
 */
static int drive_ready(void)
{
    return (drive_client_ping_device(DRIVE_DEVICE_SMB) == DRIVE_CLIENT_OK) ? 1 : 0;
}

/*
 * mem_info -- RAM line numbers of the boot screen.
 * Returns: nothing.
 */
static void mem_info(uint32_t *ram_bytes, uint32_t *free_bytes)
{
    *ram_bytes = g_ddr.size_bytes;
    *free_bytes = g_ddr.free_bytes;
}

/*
 * main -- boot and superloop.
 * Returns: never.
 */
int main(void)
{
    basic_config_t cfg;

    platform_init();

    keyboard_init(KEYBOARD_INPUT_IRQ);
    connect(IRQ_UART, keyboard_uart_isr, NULL, "connect uart irq");
    connect(IRQ_PS2, keyboard_ps2_isr, NULL, "connect ps2 irq");

    if (Xil_In32(SYS_REG(C64_SYS_MAGIC_OFS)) != C64_SYS_MAGIC_VALUE) {
        fail_stop("sysregs magic", (int)Xil_In32(SYS_REG(C64_SYS_MAGIC_OFS)));
    }
    xil_printf("\r\nIronKernel 64 core 0, build %08x%s\r\n", Xil_In32(SYS_REG(C64_SYS_BUILD_ID_OFS)),
               ((Xil_In32(SYS_REG(C64_SYS_BUILD_FLAGS_OFS)) & SYS_DIRTY_MASK) != 0u) ? " dirty" : "");

    {
        const ddr_probe_status_t ds = ddr_probe_run(&g_ddr);

        if (ds != DDR_PROBE_OK) {
            fail_stop(ddr_probe_status_text(ds), (int)ds);
        }
        xil_printf("DDR3 calibrated (%d ms), %d MiB\r\n", (int)g_ddr.calib_ms, (int)(g_ddr.size_bytes / MIB));
    }

    cli_init(&g_ddr);
    adau1761_init();            /* fail-stop inside */
    xil_printf("ADAU1761 codec OK\r\n");
    audio_out_init();
    connect(IRQ_AUDIO, audio_out_isr, NULL, "connect audio irq");

    video_init(VIDEO_VSYNC_IRQ);    /* loads the Colodore palette */
    connect(IRQ_VSYNC, video_vsync_isr, NULL, "connect vsync irq");
    c64screen_init();

    cfg.mem_info = mem_info;
    cfg.player = &g_player_ops;
    cfg.load_buf = g_load_buf;
    cfg.load_buf_bytes = LOAD_BUF_BYTES;
    cfg.uart_out = outbyte;
    drive_client_init();
    /* Core 1 loads its firmware from the QSPI flash after configuration and may still be starting:
     * wait for its drive server (any answer, a DOS status included), at most BOOT_DRIVE_WAIT_PINGS
     * PING timeouts (3 s; core 1 idle under the JTAG flow costs that once). */
    for (uint32_t w = 0u; w < BOOT_DRIVE_WAIT_PINGS; w++) {
        if (drive_client_ping_device(DRIVE_DEVICE_BANK) != DRIVE_CLIENT_TIMEOUT) {
            break;
        }
    }
    xil_printf("drive (device 8): %s, tune bank (device 9): %s\r\n",
               (drive_client_ping_device(DRIVE_DEVICE_SMB) == DRIVE_CLIENT_OK) ? "present" : "not answering",
               (drive_client_ping_device(DRIVE_DEVICE_BANK) == DRIVE_CLIENT_OK) ? "present" : "not answering");

    Xil_ExceptionEnable();
    basic_init(&cfg);
    if (oled_init()) {
        oled_ui_init(&g_player_ops, drive_ready);
    }

    for (;;) {
        const uint32_t events = keyboard_poll(g_ms);

        (void)drive_client_log_drain(log1_put, LOG1_DRAIN_MAX);   /* core 1 text: UART only */

        (void)events;   /* Ctrl-B is reported through keyboard_cli_mode() */
        basic_poll();   /* screen, PS/2 keys and the player run in CLI mode too */
        cli_poll(keyboard_cli_mode());
        oled_ui_poll(basic_playing(), video_vsync_count(), g_ms);
    }
}

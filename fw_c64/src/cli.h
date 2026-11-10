/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: cli.h
 * Role: the core 0 engineering CLI transport: UART line editor, output ring and the print
 *   helpers used by the command callbacks (cli_cmds.c). The menu itself is the generated
 *   fw_c64/cli/menu.c.
 *
 * Contract:
 *   - cli_poll() is called from the main loop on every pass. It never blocks: at most
 *     CLI_RX_SLICE input bytes and CLI_TX_SLICE output bytes per call, output only while the
 *     UART transmit FIFO has room.
 *   - Output goes through a CLI_TX_RING byte ring (menu_write / cli_put_*). A command starts
 *     only when the ring is empty, so one command's output (< CLI_TX_RING) always fits; a
 *     write that does not fit is dropped and "[output truncated]" is queued afterwards.
 *   - Commands marked idle in cli_commands.txt call cli_refuse_if_playing(), which refuses
 *     them while a tune plays (they wait on core 1 or the I2C bus).
 *   - Entering CLI mode prints a banner and the prompt; EXIT or Ctrl-B returns to the C64.
 * Headers hold contracts and constants; per-function commentary lives in the .c files.
 */
#ifndef CLI_H
#define CLI_H

#include <stdint.h> /* uint32_t */

#include "ddr_probe.h"

#define CLI_RX_SLICE   (32u)     /* input bytes handled per cli_poll() */
#define CLI_TX_SLICE   (16u)     /* output bytes sent per cli_poll() (UART Lite FIFO depth) */
#define CLI_TX_RING    (2048u)   /* power of two */
#define CLI_PROMPT     "ik64> "

void cli_init(const ddr_probe_result_t *ddr);
void cli_poll(int active);

/* Helpers for the callbacks. */
void cli_put_u32(uint32_t v);
void cli_put_hex(uint32_t v, uint32_t digits);
void cli_put_kv(const char *key, uint32_t v);        /* "key=<dec>" and a space */
int  cli_refuse_if_playing(void);                    /* 1 = refused (message printed) */
const ddr_probe_result_t *cli_ddr(void);

#endif /* CLI_H */

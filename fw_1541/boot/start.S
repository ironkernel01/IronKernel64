/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: start.S
 * Role: reset entry of the core 1 QSPI bootloader (LMB at 0x0): stack, global pointer, call boot_main.
 * The bootloader keeps no initialised data and no bss; boot_main never returns.
 */
    .section .text.init, "ax"
    .global _start
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __stack_top
    call    boot_main
1:  j       1b

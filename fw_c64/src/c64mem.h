/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: c64mem.h
 * Role: the 64 KiB C64 RAM, the I/O view the player needs, the KERNAL stubs and
 *   the 6502 call driver of the core 0 player.
 *
 * Ownership: this file owns the C64 address space and the 6502 instance that
 *   runs in it (cpu6502.c is the interpreter; the CPU struct lives here). The RAM
 *   is one static 64 KiB array; the firmware linker script places this module's
 *   .bss in LMB. SID register traffic leaves through sidbus.h only.
 *
 * Memory map seen by the 6502 (no banking: $00/$01 are plain RAM bytes, the
 *   I/O window is always visible, no ROMs are present):
 *   $0000-$CFFF, $E000-$FFFF  RAM.
 *   $D000-$DFFF  I/O window:
 *     $D400-$D7FF  SID, mirrored every 32 bytes (register = addr & $1F).
 *                  Writes: sidbus_write(cycle offset in the call, reg, val) and a
 *                  register shadow. Reads: registers 25..28 ($D419-$D41C POTX,
 *                  POTY, OSC3, ENV3) -> sidbus_read(reg); all other registers ->
 *                  the last value written (0 after reset), from the shadow.
 *     $D011 bit 7 / $D012  raster line bit 8 / bits 7..0 from the cycle count:
 *                  line = ((cycle - call start) + C64MEM_CALL_START_LINE * 63)
 *                  / 63 mod 312 (PAL). Other $D011 bits read back as written.
 *     $DC04/$DC05  CIA 1 timer A latch: writes update the low/high byte, reads return
 *                  the latch (no down-counter). 0 = never written (c64mem_cia1_ta_latch).
 *     $DC0E        CIA 1 CRA: stored in RAM, reads back as written.
 *     $DC0D, $DD0D  CIA interrupt control: read 0.
 *     everything else  reads/writes RAM.
 *
 * KERNAL stubs written by c64mem_reset. c64mem_check_range reports
 *   C64MEM_RANGE_STUB only for the sentinel byte $FF40 (the call-return path). Tune data
 *   that covers the other stubs ($EA31, $EA81..$EA86, $FF48, vectors $FFFA-$FFFF, RAM
 *   vectors $0314-$0317) simply replaces them: psid_init copies the data after
 *   c64mem_reset, so the tune owns that memory and the stub is not in effect (play calls
 *   do not go through any of them):
 *   $EA31  JMP $EA81                       (C64MEM_STUB_EA31)
 *   $EA81  PLA TAY PLA TAX PLA RTI         (C64MEM_STUB_EA81; $EA86 is the RTI)
 *   $FF40  JMP $FF40                       (C64MEM_SENTINEL; reset vector target)
 *   $FF48  PHA TXA PHA TYA PHA JMP ($0314) (C64MEM_STUB_IRQ, IRQ/BRK entry)
 *   $FFFA/B NMI -> $EA86 (RTI), $FFFC/D RESET -> $FF40, $FFFE/F IRQ -> $FF48
 *   $0314/5 IRQ vector -> $EA31, $0316/7 BRK vector -> $EA81
 *   $0000 = $2F, $0001 = $37 (processor port defaults, stored as RAM)
 *
 * Call driver: c64mem_call sets S = $FF, pushes the return address
 *   C64MEM_SENTINEL - 1, loads A, clears X/Y, sets P = U|I (D clear), sets PC,
 *   calls sidbus_frame_begin() and runs until the routine's RTS lands on
 *   C64MEM_SENTINEL or max_cycles are used. BRK stops the call
 *   (C64MEM_CALL_BRK). No accepted PSID image
 *   may cover the sentinel byte. Play calls use C64MEM_PLAY_MAX_CYCLES.
 *
 * Concurrency: core 0 main loop only.
 * Headers hold signatures, constants, types and contract prose; per-function
 *   commentary lives in c64mem.c.
 */
#ifndef C64MEM_H
#define C64MEM_H

#include "cpu6502.h"

#include <stdint.h> /* uint8_t, uint16_t, uint32_t */

#define C64MEM_BYTES            (65536u)
#define C64MEM_IO_BASE          (0xD000u)
#define C64MEM_IO_MASK          (0xF000u)
#define C64MEM_IO_END           (0xDFFFu)
#define C64MEM_SID_BASE         (0xD400u)
#define C64MEM_SID_END          (0xD7FFu)
#define C64MEM_VIC_CTRL1        (0xD011u)
#define C64MEM_VIC_RASTER       (0xD012u)
#define C64MEM_CIA1_TA_LO       (0xDC04u)
#define C64MEM_CIA1_TA_HI       (0xDC05u)
#define C64MEM_CIA1_ICR         (0xDC0Du)
#define C64MEM_CIA1_CRA         (0xDC0Eu)
#define C64MEM_CIA2_ICR         (0xDD0Du)

#define C64MEM_STUB_EA31        (0xEA31u)
#define C64MEM_STUB_EA81        (0xEA81u)
#define C64MEM_STUB_RTI         (0xEA86u)   /* the RTI of the $EA81 stub; NMI target */
#define C64MEM_SENTINEL         (0xFF40u)
#define C64MEM_STUB_IRQ         (0xFF48u)
#define C64MEM_IRQ_VECTOR       (0x0314u)
#define C64MEM_BRK_VECTOR       (0x0316u)
#define C64MEM_PORT_DDR_RESET   (0x2Fu)
#define C64MEM_PORT_DATA_RESET  (0x37u)

/* PAL timing; SIDBUS_FRAME_CYCLES (sidbus.h) must equal C64MEM_FRAME_CYCLES (checked in c64mem.c). */
#define C64MEM_PAL_LINE_CYCLES  (63u)
#define C64MEM_PAL_LINES        (312u)
#define C64MEM_FRAME_CYCLES     (C64MEM_PAL_LINE_CYCLES * C64MEM_PAL_LINES)   /* 19656 */

/* Raster line at the first cycle of every call (play calls start at the top of the frame). */
#define C64MEM_CALL_START_LINE  (0u)

/* Cycle cap of a play call: c64demo.md Phase 3, 20,000 cycles. The sidbus_log capacity
 * is derived from it (SIDBUS_LOG_PLAY_MAX_CYCLES, checked in c64mem.c). */
#define C64MEM_PLAY_MAX_CYCLES  (20000u)

typedef enum
{
    C64MEM_CALL_RETURNED  = 0,  /* RTS reached the sentinel */
    C64MEM_CALL_CYCLE_CAP = 1,  /* max_cycles used without returning */
    C64MEM_CALL_JAM       = 2,  /* a JAM opcode halted the CPU */
    C64MEM_CALL_BRK       = 3   /* the routine executed BRK */
} c64mem_call_t;

typedef enum
{
    C64MEM_RANGE_OK       = 0,
    C64MEM_RANGE_EMPTY    = 1,  /* zero length */
    C64MEM_RANGE_PAST_END = 2,  /* runs past $FFFF */
    C64MEM_RANGE_IO       = 3,  /* overlaps $D000-$DFFF */
    C64MEM_RANGE_STUB     = 4   /* covers the call-return sentinel byte */
} c64mem_range_t;

void c64mem_reset(void);
void c64mem_fill(uint8_t value);
int c64mem_load(uint32_t addr, const uint8_t *data, uint32_t len);
uint8_t c64mem_peek(uint16_t addr);
void c64mem_poke(uint16_t addr, uint8_t value);
c64mem_range_t c64mem_check_range(uint32_t addr, uint32_t len);
c64mem_call_t c64mem_call(uint16_t addr, uint8_t a_reg, uint32_t max_cycles);
uint32_t c64mem_call_cycles(void);
uint16_t c64mem_cia1_ta_latch(void);
cpu6502_t *c64mem_cpu(void);

#endif /* C64MEM_H */

/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: c64mem.c
 * Role: C64 RAM, I/O view, KERNAL stubs and the 6502 call driver (contract in
 *   c64mem.h).
 *
 * Owns: g_ram (the 64 KiB C64 address space), g_cpu (the player's 6502) and the
 *   SID register shadow. SID traffic goes out through sidbus_write / sidbus_read.
 */
#include "c64mem.h"

#include "sidbus.h"

#include <stddef.h> /* NULL */
#include <string.h> /* memset, memcpy */

#define C64MEM_RASTER_BIT8      (0x80u)
#define C64MEM_RESERVED_RANGES  (4u)

#if SIDBUS_FRAME_CYCLES != C64MEM_FRAME_CYCLES
#error "sidbus.h and c64mem.h disagree on the PAL frame length"
#endif
#if SIDBUS_LOG_PLAY_MAX_CYCLES != C64MEM_PLAY_MAX_CYCLES
#error "sidbus_log capacity is not derived from the c64mem play cap"
#endif

typedef struct
{
    uint16_t first;
    uint16_t last;
} c64mem_span_t;

/* Stub code, sentinel page and hardware vectors (see c64mem.h). */
static const c64mem_span_t g_reserved[C64MEM_RESERVED_RANGES] = {
    { C64MEM_STUB_EA31, C64MEM_STUB_EA31 + 2u },
    { C64MEM_STUB_EA81, C64MEM_STUB_RTI },
    { C64MEM_SENTINEL, C64MEM_SENTINEL + 0x0Fu },
    { CPU6502_VEC_NMI, 0xFFFFu },
};

/* $EA31: JMP $EA81. */
static const uint8_t g_stub_ea31[] = { 0x4Cu, 0x81u, 0xEAu };
/* $EA81: PLA TAY PLA TAX PLA RTI. */
static const uint8_t g_stub_ea81[] = { 0x68u, 0xA8u, 0x68u, 0xAAu, 0x68u, 0x40u };
/* $FF40: JMP $FF40. */
static const uint8_t g_stub_sentinel[] = { 0x4Cu, 0x40u, 0xFFu };
/* $FF48: PHA TXA PHA TYA PHA JMP ($0314). */
static const uint8_t g_stub_irq[] = { 0x48u, 0x8Au, 0x48u, 0x98u, 0x48u, 0x6Cu, 0x14u, 0x03u };

/* The C64 RAM; 64 KiB, linked into LMB with this module's .bss. */
static uint8_t g_ram[C64MEM_BYTES];
static cpu6502_t g_cpu;
static uint8_t g_sid_shadow[SIDBUS_REGS];
static uint32_t g_call_start;
static uint32_t g_call_cycles;
static uint16_t g_cia1_ta_latch;   /* CIA 1 timer A latch; 0 = never written */

/*
 * c64mem_raster_line -- PAL raster line at a cycle stamp of the current call.
 * Returns: 0..311.
 */
static uint32_t c64mem_raster_line(uint32_t cycle)
{
    uint32_t t = (cycle - g_call_start) % C64MEM_FRAME_CYCLES;

    t = (t + C64MEM_CALL_START_LINE * C64MEM_PAL_LINE_CYCLES) % C64MEM_FRAME_CYCLES;
    return t / C64MEM_PAL_LINE_CYCLES;
}

/*
 * c64mem_io_read -- 6502 read in the $D000-$DFFF window.
 * Steps:
 *   1. SID mirror: registers 25..28 from sidbus_read, the others from the shadow.
 *   2. $D012 / $D011: raster line from the cycle stamp.
 *   3. $DC0D / $DD0D: 0.
 *   4. $DC04 / $DC05: the timer A latch (stands in for the down-counter).
 *   5. Anything else: RAM ($DC0E, the CIA 1 CRA, reads back as written).
 * Returns: the byte the 6502 sees.
 */
static uint8_t c64mem_io_read(uint16_t addr, uint32_t cycle)
{
    if (addr >= C64MEM_SID_BASE && addr <= C64MEM_SID_END) {
        const uint8_t reg = (uint8_t)(addr & SIDBUS_REG_MASK);

        if (reg >= SIDBUS_REG_POTX && reg <= SIDBUS_REG_ENV3) {
            return sidbus_read(reg);
        }
        return g_sid_shadow[reg];
    }
    if (addr == C64MEM_VIC_RASTER) {
        return (uint8_t)(c64mem_raster_line(cycle) & 0xFFu);
    }
    if (addr == C64MEM_VIC_CTRL1) {
        const uint32_t line = c64mem_raster_line(cycle);

        return (uint8_t)((g_ram[addr] & (uint8_t)~C64MEM_RASTER_BIT8)
                         | (((line >> 8) & 1u) ? C64MEM_RASTER_BIT8 : 0u));
    }
    if (addr == C64MEM_CIA1_ICR || addr == C64MEM_CIA2_ICR) {
        return 0u;
    }
    if (addr == C64MEM_CIA1_TA_LO) {
        return (uint8_t)(g_cia1_ta_latch & 0xFFu);
    }
    if (addr == C64MEM_CIA1_TA_HI) {
        return (uint8_t)(g_cia1_ta_latch >> 8);
    }
    return g_ram[addr];
}

/*
 * c64mem_io_write -- 6502 write in the $D000-$DFFF window.
 * Steps:
 *   1. SID mirror: update the shadow; sidbus_write(cycle - call start, reg, val).
 *   2. $DC04 / $DC05: update the low / high byte of the CIA 1 timer A latch.
 *   3. Anything else: RAM (this stores $DC0E, the CIA 1 CRA).
 * Returns: nothing.
 */
static void c64mem_io_write(uint16_t addr, uint8_t val, uint32_t cycle)
{
    if (addr >= C64MEM_SID_BASE && addr <= C64MEM_SID_END) {
        const uint8_t reg = (uint8_t)(addr & SIDBUS_REG_MASK);

        g_sid_shadow[reg] = val;
        sidbus_write(cycle - g_call_start, reg, val);
        return;
    }
    if (addr == C64MEM_CIA1_TA_LO) {
        g_cia1_ta_latch = (uint16_t)((g_cia1_ta_latch & 0xFF00u) | val);
        return;
    }
    if (addr == C64MEM_CIA1_TA_HI) {
        g_cia1_ta_latch = (uint16_t)((g_cia1_ta_latch & 0x00FFu) | ((uint16_t)val << 8));
        return;
    }
    g_ram[addr] = val;
}

/*
 * c64mem_reset -- power-on state of the address space and the CPU.
 * Steps:
 *   1. Clear RAM and the SID shadow; processor port $00/$01 defaults.
 *   2. Write the KERNAL stubs, the RAM vectors and the hardware vectors.
 *   3. Bind the 6502 to the bus (I/O window $D000-$DFFF) and reset its registers.
 * Returns: nothing.
 */
void c64mem_reset(void)
{
    cpu6502_bus_t bus;

    memset(g_ram, 0, sizeof(g_ram));
    memset(g_sid_shadow, 0, sizeof(g_sid_shadow));
    g_call_start = 0u;
    g_call_cycles = 0u;
    g_cia1_ta_latch = 0u;

    g_ram[0x0000u] = C64MEM_PORT_DDR_RESET;
    g_ram[0x0001u] = C64MEM_PORT_DATA_RESET;
    memcpy(&g_ram[C64MEM_STUB_EA31], g_stub_ea31, sizeof(g_stub_ea31));
    memcpy(&g_ram[C64MEM_STUB_EA81], g_stub_ea81, sizeof(g_stub_ea81));
    memcpy(&g_ram[C64MEM_SENTINEL], g_stub_sentinel, sizeof(g_stub_sentinel));
    memcpy(&g_ram[C64MEM_STUB_IRQ], g_stub_irq, sizeof(g_stub_irq));
    g_ram[C64MEM_IRQ_VECTOR] = (uint8_t)(C64MEM_STUB_EA31 & 0xFFu);
    g_ram[C64MEM_IRQ_VECTOR + 1u] = (uint8_t)(C64MEM_STUB_EA31 >> 8);
    g_ram[C64MEM_BRK_VECTOR] = (uint8_t)(C64MEM_STUB_EA81 & 0xFFu);
    g_ram[C64MEM_BRK_VECTOR + 1u] = (uint8_t)(C64MEM_STUB_EA81 >> 8);
    g_ram[CPU6502_VEC_NMI] = (uint8_t)(C64MEM_STUB_RTI & 0xFFu);
    g_ram[CPU6502_VEC_NMI + 1u] = (uint8_t)(C64MEM_STUB_RTI >> 8);
    g_ram[CPU6502_VEC_RESET] = (uint8_t)(C64MEM_SENTINEL & 0xFFu);
    g_ram[CPU6502_VEC_RESET + 1u] = (uint8_t)(C64MEM_SENTINEL >> 8);
    g_ram[CPU6502_VEC_IRQ] = (uint8_t)(C64MEM_STUB_IRQ & 0xFFu);
    g_ram[CPU6502_VEC_IRQ + 1u] = (uint8_t)(C64MEM_STUB_IRQ >> 8);

    bus.ram = g_ram;
    bus.io_mask = C64MEM_IO_MASK;
    bus.io_base = C64MEM_IO_BASE;
    bus.io_read = c64mem_io_read;
    bus.io_write = c64mem_io_write;
    cpu6502_init(&g_cpu, &bus);
    cpu6502_reset(&g_cpu);
}

/*
 * c64mem_fill -- set every RAM byte (test images that assume a fill pattern).
 * Returns: nothing.
 */
void c64mem_fill(uint8_t value)
{
    memset(g_ram, value, sizeof(g_ram));
}

/*
 * c64mem_load -- copy bytes into RAM (no I/O side effects, no stub checks).
 * Steps:
 *   1. Reject a NULL source or a range past $FFFF.
 *   2. Copy.
 * Returns: 0 on success, -1 when rejected (RAM unchanged).
 */
int c64mem_load(uint32_t addr, const uint8_t *data, uint32_t len)
{
    if (data == NULL || addr > C64MEM_BYTES || len > C64MEM_BYTES - addr) {
        return -1;
    }
    memcpy(&g_ram[addr], data, len);
    return 0;
}

/*
 * c64mem_peek -- read RAM without I/O side effects.
 * Returns: the RAM byte.
 */
uint8_t c64mem_peek(uint16_t addr)
{
    return g_ram[addr];
}

/*
 * c64mem_poke -- write RAM without I/O side effects.
 * Returns: nothing.
 */
void c64mem_poke(uint16_t addr, uint8_t value)
{
    g_ram[addr] = value;
}

/*
 * c64mem_check_range -- classify a load range against the memory map.
 * Steps:
 *   1. Empty or past $FFFF.
 *   2. Overlap with the I/O window.
 *   3. Overlap with any reserved stub/sentinel/vector span.
 * Returns: C64MEM_RANGE_OK or the first failing class (c64mem_range_t).
 */
c64mem_range_t c64mem_check_range(uint32_t addr, uint32_t len)
{
    uint32_t last;

    if (len == 0u) {
        return C64MEM_RANGE_EMPTY;
    }
    if (addr >= C64MEM_BYTES || len > C64MEM_BYTES - addr) {
        return C64MEM_RANGE_PAST_END;
    }
    last = addr + len - 1u;
    if (addr <= C64MEM_IO_END && last >= C64MEM_IO_BASE) {
        return C64MEM_RANGE_IO;
    }
    for (uint32_t i = 0u; i < C64MEM_RESERVED_RANGES; i++) {
        if (addr <= g_reserved[i].last && last >= g_reserved[i].first) {
            return C64MEM_RANGE_STUB;
        }
    }
    return C64MEM_RANGE_OK;
}

/*
 * c64mem_call -- call a 6502 routine and run it until it returns or the cycle cap.
 * Steps:
 *   1. S = $FF, push C64MEM_SENTINEL - 1 (high byte first), A = a_reg, X = Y = 0,
 *      P = U|I, PC = addr; BRK stops the run.
 *   2. Note the start cycle, sidbus_frame_begin(), run until the sentinel or max_cycles
 *      (SID writes reach sidbus_write with offsets from the start cycle).
 *   3. Record the cycles used; map the stop reason.
 * Returns: the call result (c64mem_call_t).
 */
c64mem_call_t c64mem_call(uint16_t addr, uint8_t a_reg, uint32_t max_cycles)
{
    const uint32_t ret = C64MEM_SENTINEL - 1u;
    cpu6502_regs_t r;
    cpu6502_stop_t stop;

    g_ram[CPU6502_STACK_PAGE + 0xFFu] = (uint8_t)(ret >> 8);
    g_ram[CPU6502_STACK_PAGE + 0xFEu] = (uint8_t)(ret & 0xFFu);
    r.pc = addr;
    r.a = a_reg;
    r.x = 0u;
    r.y = 0u;
    r.s = 0xFDu;
    r.p = (uint8_t)(CPU6502_P_U | CPU6502_P_I);
    cpu6502_set_regs(&g_cpu, &r);
    cpu6502_set_brk_stop(&g_cpu, 1);

    g_call_start = cpu6502_cycles(&g_cpu);
    sidbus_frame_begin();
    stop = cpu6502_run_until(&g_cpu, C64MEM_SENTINEL, max_cycles);
    g_call_cycles = cpu6502_cycles(&g_cpu) - g_call_start;

    switch (stop) {
    case CPU6502_STOP_SENTINEL:
        return C64MEM_CALL_RETURNED;
    case CPU6502_STOP_JAM:
        return C64MEM_CALL_JAM;
    case CPU6502_STOP_BRK:
        return C64MEM_CALL_BRK;
    case CPU6502_STOP_CYCLES:
    default:
        return C64MEM_CALL_CYCLE_CAP;
    }
}

/*
 * c64mem_call_cycles -- 6502 cycles used by the last call.
 * Returns: the cycle count.
 */
uint32_t c64mem_call_cycles(void)
{
    return g_call_cycles;
}

/*
 * c64mem_cia1_ta_latch -- CIA 1 timer A latch as the tune wrote it.
 * Returns: the 16-bit latch; 0 when $DC04/$DC05 were never written since c64mem_reset.
 */
uint16_t c64mem_cia1_ta_latch(void)
{
    return g_cia1_ta_latch;
}

/*
 * c64mem_cpu -- the player's 6502 (for the CPU self-test).
 * Returns: the CPU instance bound to this address space.
 */
cpu6502_t *c64mem_cpu(void)
{
    return &g_cpu;
}

/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: cpu6502.c
 * Role: NMOS 6502 interpreter (contract in cpu6502.h).
 *
 * Structure: cpu6502_run_until copies the registers into locals, dispatches
 *   each opcode through one switch (a jump table on RV32, no per-opcode function
 *   pointers), and writes the registers back on exit. Flags live in locals as
 *   fn (bit 7 = N), fz (0 = Z set), fc, fv, fd, fi (0/1) and are packed only for
 *   PHP, BRK and the register accessors.
 * Cycle accounting: the base count from g_cyc[] is added before the opcode
 *   executes, so `cycles - 1` is the stamp of the instruction's final bus cycle;
 *   page-cross and branch penalties are added where they occur.
 * Decimal mode: the NMOS ADC/SBC algorithms below are the ones Bruce Clark's
 *   decimal_mode tutorial (6502.org) derives for the 6502: ADC N/V from the
 *   high-nibble sum before the +$60 adjust, Z from the binary sum; SBC N/V/Z/C
 *   from the binary difference.
 */
#include "cpu6502.h"

#include <stddef.h> /* NULL */

#define CPU_ADDR_MASK   (0xFFFFu)
#define CPU_BYTE_MASK   (0xFFu)
#define CPU_MAGIC_ANE   (0xEEu)   /* ANE/LXA "magic" constant of the unstable model */

/* NMOS base cycle counts; 0 marks the JAM opcodes. Penalties are added in the switch. */
static const uint8_t g_cyc[256] = {
    /*        0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F */
    /* 0 */   7, 6, 0, 8, 3, 3, 5, 5, 3, 2, 2, 2, 4, 4, 6, 6,
    /* 1 */   2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    /* 2 */   6, 6, 0, 8, 3, 3, 5, 5, 4, 2, 2, 2, 4, 4, 6, 6,
    /* 3 */   2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    /* 4 */   6, 6, 0, 8, 3, 3, 5, 5, 3, 2, 2, 2, 3, 4, 6, 6,
    /* 5 */   2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    /* 6 */   6, 6, 0, 8, 3, 3, 5, 5, 4, 2, 2, 2, 5, 4, 6, 6,
    /* 7 */   2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    /* 8 */   2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4,
    /* 9 */   2, 6, 0, 6, 4, 4, 4, 4, 2, 5, 2, 5, 5, 5, 5, 5,
    /* A */   2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4,
    /* B */   2, 5, 0, 5, 4, 4, 4, 4, 2, 4, 2, 4, 4, 4, 4, 4,
    /* C */   2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6,
    /* D */   2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    /* E */   2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6,
    /* F */   2, 5, 0, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
};

/*
 * cpu6502_pack_p -- build the status byte from the flag parts.
 * Returns: NV1BDIZC with B clear and U set.
 */
static inline uint32_t cpu6502_pack_p(uint32_t fn, uint32_t fv, uint32_t fd, uint32_t fi,
                                      uint32_t fz, uint32_t fc)
{
    return (fn & CPU6502_P_N) | (fv << 6) | CPU6502_P_U | (fd << 3) | (fi << 2)
           | ((fz == 0u) ? CPU6502_P_Z : 0u) | fc;
}

/*
 * cpu6502_init -- bind a CPU to its bus and set the power-on registers.
 * Steps:
 *   1. Copy the bus descriptor.
 *   2. Clear A/X/Y, S = $FD, P = U|I, PC = 0, cycle counter 0, no fault, BRK executes.
 * Returns: nothing.
 */
void cpu6502_init(cpu6502_t *cpu, const cpu6502_bus_t *bus)
{
    cpu->bus = *bus;
    cpu->r.pc = 0u;
    cpu->r.a = 0u;
    cpu->r.x = 0u;
    cpu->r.y = 0u;
    cpu->r.s = 0xFDu;
    cpu->r.p = (uint8_t)(CPU6502_P_U | CPU6502_P_I);
    cpu->cycles = 0u;
    cpu->halted = 0u;
    cpu->jam_opcode = 0u;
    cpu->brk_stops = 0u;
}

/*
 * cpu6502_reset -- the RESET sequence.
 * Steps:
 *   1. Clear the JAM latch; A/X/Y = 0, S = $FD, P = U|I.
 *   2. Load PC from the reset vector in RAM and count the 7 reset cycles.
 * Returns: nothing.
 */
void cpu6502_reset(cpu6502_t *cpu)
{
    const uint8_t *ram = cpu->bus.ram;

    cpu->halted = 0u;
    cpu->jam_opcode = 0u;
    cpu->r.a = 0u;
    cpu->r.x = 0u;
    cpu->r.y = 0u;
    cpu->r.s = 0xFDu;
    cpu->r.p = (uint8_t)(CPU6502_P_U | CPU6502_P_I);
    cpu->r.pc = (uint16_t)(ram[CPU6502_VEC_RESET] | ((uint32_t)ram[CPU6502_VEC_RESET + 1u] << 8));
    cpu->cycles += 7u;
}

/*
 * cpu6502_set_regs -- load all registers.
 * Steps:
 *   1. Copy the registers; force U in P (B is not stored).
 *   2. Clear the JAM latch so the CPU runs from the new PC.
 * Returns: nothing.
 */
void cpu6502_set_regs(cpu6502_t *cpu, const cpu6502_regs_t *regs)
{
    cpu->r = *regs;
    cpu->r.p = (uint8_t)((regs->p | CPU6502_P_U) & (uint8_t)~CPU6502_P_B);
    cpu->halted = 0u;
    cpu->jam_opcode = 0u;
}

/*
 * cpu6502_get_regs -- read all registers.
 * Returns: nothing (registers copied to *regs).
 */
void cpu6502_get_regs(const cpu6502_t *cpu, cpu6502_regs_t *regs)
{
    *regs = cpu->r;
}

/*
 * cpu6502_set_pc -- set the program counter only (clears the JAM latch).
 * Returns: nothing.
 */
void cpu6502_set_pc(cpu6502_t *cpu, uint16_t pc)
{
    cpu->r.pc = pc;
    cpu->halted = 0u;
    cpu->jam_opcode = 0u;
}

/*
 * cpu6502_set_brk_stop -- choose whether BRK stops the run loop.
 * Returns: nothing.
 */
void cpu6502_set_brk_stop(cpu6502_t *cpu, int enable)
{
    cpu->brk_stops = (enable != 0) ? 1u : 0u;
}

/*
 * cpu6502_cycles -- the free-running cycle counter.
 * Returns: cycles executed since cpu6502_init, modulo 2^32.
 */
uint32_t cpu6502_cycles(const cpu6502_t *cpu)
{
    return cpu->cycles;
}

/*
 * cpu6502_jam_opcode -- the latched JAM fault.
 * Returns: the JAM opcode (0x02..0xF2) while the CPU is halted, -1 when it is not halted.
 */
int cpu6502_jam_opcode(const cpu6502_t *cpu)
{
    return (cpu->halted != 0u) ? (int)cpu->jam_opcode : -1;
}

/*
 * cpu6502_step -- execute exactly one instruction.
 * Steps:
 *   1. Run with no sentinel and a one-cycle budget (every instruction takes at least two).
 * Returns: CPU6502_STOP_CYCLES after a normal instruction, CPU6502_STOP_JAM or
 *   CPU6502_STOP_BRK as cpu6502_run_until reports them.
 */
cpu6502_stop_t cpu6502_step(cpu6502_t *cpu)
{
    return cpu6502_run_until(cpu, CPU6502_NO_SENTINEL, 1u);
}

/* ---- run-loop helpers: they use the locals of cpu6502_run_until ---- */

#define IS_IO(ea_)       ((((ea_) & io_mask) == io_base))
#define RD(ea_)          (IS_IO(ea_) ? (uint32_t)io_rd((uint16_t)(ea_), cycles - 1u) \
                                     : (uint32_t)ram[(ea_)])
#define WR(ea_, v_)      do { if (IS_IO(ea_)) { io_wr((uint16_t)(ea_), (uint8_t)(v_), cycles - 1u); } \
                              else { ram[(ea_)] = (uint8_t)(v_); } } while (0)
/* Read-modify-write store: NMOS writes the unmodified value, then the result. */
#define WR_RMW(ea_, old_, v_) do { if (IS_IO(ea_)) { \
                                       io_wr((uint16_t)(ea_), (uint8_t)(old_), cycles - 2u); \
                                       io_wr((uint16_t)(ea_), (uint8_t)(v_), cycles - 1u); } \
                                   else { ram[(ea_)] = (uint8_t)(v_); } } while (0)

#define OPB1()           ((uint32_t)ram[(pc + 1u) & CPU_ADDR_MASK])
#define OPW()            (OPB1() | ((uint32_t)ram[(pc + 2u) & CPU_ADDR_MASK] << 8))
#define PC_ADV(n_)       (pc = (pc + (n_)) & CPU_ADDR_MASK)
#define PAGE_PEN(b_, e_) (cycles += ((((b_) ^ (e_)) >> 8) & 1u))

#define AM_IMM()   do { v = OPB1(); PC_ADV(2u); } while (0)
#define AM_ZP()    do { ea = OPB1(); PC_ADV(2u); } while (0)
#define AM_ZPX()   do { ea = (OPB1() + x) & CPU_BYTE_MASK; PC_ADV(2u); } while (0)
#define AM_ZPY()   do { ea = (OPB1() + y) & CPU_BYTE_MASK; PC_ADV(2u); } while (0)
#define AM_ABS()   do { ea = OPW(); PC_ADV(3u); } while (0)
#define AM_ABX_W() do { t = OPW(); ea = (t + x) & CPU_ADDR_MASK; PC_ADV(3u); } while (0)
#define AM_ABY_W() do { t = OPW(); ea = (t + y) & CPU_ADDR_MASK; PC_ADV(3u); } while (0)
#define AM_ABX_R() do { AM_ABX_W(); PAGE_PEN(t, ea); } while (0)
#define AM_ABY_R() do { AM_ABY_W(); PAGE_PEN(t, ea); } while (0)
#define AM_IZX()   do { t = (OPB1() + x) & CPU_BYTE_MASK; \
                        ea = (uint32_t)ram[t] | ((uint32_t)ram[(t + 1u) & CPU_BYTE_MASK] << 8); \
                        PC_ADV(2u); } while (0)
#define AM_IZY_W() do { t = OPB1(); \
                        t = (uint32_t)ram[t] | ((uint32_t)ram[(t + 1u) & CPU_BYTE_MASK] << 8); \
                        ea = (t + y) & CPU_ADDR_MASK; PC_ADV(2u); } while (0)
#define AM_IZY_R() do { AM_IZY_W(); PAGE_PEN(t, ea); } while (0)

#define SET_NZ(r_)  do { fn = (r_); fz = (r_); } while (0)
#define PUSH(v_)    do { ram[CPU6502_STACK_PAGE | s] = (uint8_t)(v_); \
                         s = (s - 1u) & CPU_BYTE_MASK; } while (0)
#define PULL()      (s = (s + 1u) & CPU_BYTE_MASK, (uint32_t)ram[CPU6502_STACK_PAGE | s])
#define PACK_P()    cpu6502_pack_p(fn, fv, fd, fi, fz, fc)
#define UNPACK_P(p_) do { fn = (p_); fv = ((p_) >> 6) & 1u; fd = ((p_) >> 3) & 1u; \
                          fi = ((p_) >> 2) & 1u; fz = ((p_) & CPU6502_P_Z) ^ CPU6502_P_Z; \
                          fc = (p_) & 1u; } while (0)

/* Branch: offset is the signed operand byte; +1 cycle taken, +1 more across a page. */
#define BRANCH(cond_) do { \
        uint32_t nxt_ = (pc + 2u) & CPU_ADDR_MASK; \
        if (cond_) { \
            uint32_t off_ = OPB1(); \
            uint32_t tgt_ = (nxt_ + off_ - ((off_ & 0x80u) << 1)) & CPU_ADDR_MASK; \
            cycles += 1u + (((nxt_ ^ tgt_) >> 8) & 1u); \
            pc = tgt_; \
        } else { \
            pc = nxt_; \
        } \
    } while (0)

#define OP_ORA() do { a |= v; SET_NZ(a); } while (0)
#define OP_AND() do { a &= v; SET_NZ(a); } while (0)
#define OP_EOR() do { a ^= v; SET_NZ(a); } while (0)
#define OP_LDA() do { a = v; SET_NZ(a); } while (0)
#define OP_CMP() do { fc = (a >= v) ? 1u : 0u; t = (a - v) & CPU_BYTE_MASK; SET_NZ(t); } while (0)
#define OP_CPX() do { fc = (x >= v) ? 1u : 0u; t = (x - v) & CPU_BYTE_MASK; SET_NZ(t); } while (0)
#define OP_CPY() do { fc = (y >= v) ? 1u : 0u; t = (y - v) & CPU_BYTE_MASK; SET_NZ(t); } while (0)
#define OP_ADC() do { if (fd != 0u) { adc_dec(&a, v, &fn, &fz, &fv, &fc); } \
                      else { t = a + v + fc; fv = ((~(a ^ v) & (a ^ t)) >> 7) & 1u; \
                             fc = t >> 8; a = t & CPU_BYTE_MASK; SET_NZ(a); } } while (0)
#define OP_SBC() do { sbc_any(&a, v, fd, &fn, &fz, &fv, &fc); } while (0)
#define OP_LAX() do { a = v; x = v; SET_NZ(v); } while (0)

#define RMW_ASL() do { fc = v >> 7; v = (v << 1) & CPU_BYTE_MASK; SET_NZ(v); } while (0)
#define RMW_LSR() do { fc = v & 1u; v >>= 1; SET_NZ(v); } while (0)
#define RMW_ROL() do { t = (v << 1) | fc; fc = v >> 7; v = t & CPU_BYTE_MASK; SET_NZ(v); } while (0)
#define RMW_ROR() do { t = (v >> 1) | (fc << 7); fc = v & 1u; v = t; SET_NZ(v); } while (0)
#define RMW_INC() do { v = (v + 1u) & CPU_BYTE_MASK; SET_NZ(v); } while (0)
#define RMW_DEC() do { v = (v - 1u) & CPU_BYTE_MASK; SET_NZ(v); } while (0)

/* The eight addressing modes of a read-group ALU opcode column (b = $00,$20,...). */
#define CASES_ALU(b_, OPX) \
    case (b_) | 0x01u: AM_IZX();   v = RD(ea);  OPX(); break; \
    case (b_) | 0x05u: AM_ZP();    v = ram[ea]; OPX(); break; \
    case (b_) | 0x09u: AM_IMM();                OPX(); break; \
    case (b_) | 0x0Du: AM_ABS();   v = RD(ea);  OPX(); break; \
    case (b_) | 0x11u: AM_IZY_R(); v = RD(ea);  OPX(); break; \
    case (b_) | 0x15u: AM_ZPX();   v = ram[ea]; OPX(); break; \
    case (b_) | 0x19u: AM_ABY_R(); v = RD(ea);  OPX(); break; \
    case (b_) | 0x1Du: AM_ABX_R(); v = RD(ea);  OPX(); break

/* Documented read-modify-write column: zp, abs, zp,X, abs,X (accumulator form separate). */
#define CASES_RMW(b_, RMWX) \
    case (b_) | 0x06u: AM_ZP();    v = ram[ea]; RMWX(); ram[ea] = (uint8_t)v; break; \
    case (b_) | 0x0Eu: AM_ABS();   v = RD(ea); old = v; RMWX(); WR_RMW(ea, old, v); break; \
    case (b_) | 0x16u: AM_ZPX();   v = ram[ea]; RMWX(); ram[ea] = (uint8_t)v; break; \
    case (b_) | 0x1Eu: AM_ABX_W(); v = RD(ea); old = v; RMWX(); WR_RMW(ea, old, v); break

/* Undocumented RMW+ALU column: (zp,X) zp abs (zp),Y zp,X abs,Y abs,X, fixed cycles. */
#define CASES_RMW_ALU(b_, RMWX, OPX) \
    case (b_) | 0x03u: AM_IZX();   v = RD(ea); old = v; RMWX(); WR_RMW(ea, old, v); OPX(); break; \
    case (b_) | 0x07u: AM_ZP();    v = ram[ea]; RMWX(); ram[ea] = (uint8_t)v; OPX(); break; \
    case (b_) | 0x0Fu: AM_ABS();   v = RD(ea); old = v; RMWX(); WR_RMW(ea, old, v); OPX(); break; \
    case (b_) | 0x13u: AM_IZY_W(); v = RD(ea); old = v; RMWX(); WR_RMW(ea, old, v); OPX(); break; \
    case (b_) | 0x17u: AM_ZPX();   v = ram[ea]; RMWX(); ram[ea] = (uint8_t)v; OPX(); break; \
    case (b_) | 0x1Bu: AM_ABY_W(); v = RD(ea); old = v; RMWX(); WR_RMW(ea, old, v); OPX(); break; \
    case (b_) | 0x1Fu: AM_ABX_W(); v = RD(ea); old = v; RMWX(); WR_RMW(ea, old, v); OPX(); break

/*
 * adc_dec -- NMOS decimal-mode ADC.
 * Steps:
 *   1. Z from the binary sum A + M + C.
 *   2. Low nibble sum; above 9 add 6 and carry into the high nibble.
 *   3. High nibble sum; N and V from it (before the high adjust).
 *   4. High nibble above 9 (or binary carry out): add $60; C from the adjusted sum.
 * Returns: nothing (A and flags updated through the pointers).
 */
static inline void adc_dec(uint32_t *a, uint32_t v, uint32_t *fn, uint32_t *fz,
                           uint32_t *fv, uint32_t *fc)
{
    uint32_t lo = (*a & 0x0Fu) + (v & 0x0Fu) + *fc;
    uint32_t t;

    *fz = (*a + v + *fc) & CPU_BYTE_MASK;
    if (lo > 0x09u) {
        lo += 0x06u;
    }
    t = (lo & 0x0Fu) + (*a & 0xF0u) + (v & 0xF0u) + ((lo > 0x0Fu) ? 0x10u : 0u);
    *fn = t;
    *fv = ((((*a ^ t) & ~(*a ^ v)) >> 7) & 1u);
    if ((t & 0x1F0u) > 0x90u) {
        t += 0x60u;
    }
    *fc = ((t & 0xFF0u) > 0xF0u) ? 1u : 0u;
    *a = t & CPU_BYTE_MASK;
}

/*
 * sbc_any -- SBC in binary or NMOS decimal mode.
 * Steps:
 *   1. Binary difference A - M - !C; N, Z, V, C from it in both modes.
 *   2. Binary mode: A = difference.
 *   3. Decimal mode: low nibble difference, borrow -> subtract 6 and borrow from the
 *      high nibble; high nibble borrow -> subtract $60; A = adjusted value.
 * Returns: nothing (A and flags updated through the pointers).
 */
static inline void sbc_any(uint32_t *a, uint32_t v, uint32_t fd, uint32_t *fn, uint32_t *fz,
                           uint32_t *fv, uint32_t *fc)
{
    const uint32_t borrow = *fc ^ 1u;
    const uint32_t d = *a - v - borrow;   /* modulo 2^32: bit 8 and up set on borrow */
    uint32_t r = d & CPU_BYTE_MASK;

    if (fd != 0u) {
        uint32_t lo = (*a & 0x0Fu) - (v & 0x0Fu) - borrow;
        uint32_t t;

        if ((lo & 0x10u) != 0u) {
            t = ((lo - 0x06u) & 0x0Fu) | ((*a & 0xF0u) - (v & 0xF0u) - 0x10u);
        } else {
            t = (lo & 0x0Fu) | ((*a & 0xF0u) - (v & 0xF0u));
        }
        if ((t & 0x100u) != 0u) {
            t -= 0x60u;
        }
        *fv = ((((*a ^ v) & (*a ^ d)) >> 7) & 1u);
        *fc = (d < 0x100u) ? 1u : 0u;
        *fn = r;
        *fz = r;
        *a = t & CPU_BYTE_MASK;
        return;
    }
    *fv = ((((*a ^ v) & (*a ^ d)) >> 7) & 1u);
    *fc = (d < 0x100u) ? 1u : 0u;
    *fn = r;
    *fz = r;
    *a = r;
}

/*
 * arr_op -- undocumented ARR (#imm): AND then ROR, with the NMOS decimal-mode fix-ups.
 * Steps:
 *   1. t = A & M; result = t >> 1 with C in bit 7; N, Z from the result.
 *   2. Binary: C = bit 6, V = bit 6 ^ bit 5 of the result.
 *   3. Decimal: V = bit 6 change between t and result; low/high nibble adjusts as on NMOS,
 *      C set when the high nibble is adjusted.
 * Returns: nothing (A and flags updated through the pointers).
 */
static inline void arr_op(uint32_t *a, uint32_t v, uint32_t fd, uint32_t *fn, uint32_t *fz,
                          uint32_t *fv, uint32_t *fc)
{
    const uint32_t t = *a & v;
    uint32_t r = (t >> 1) | (*fc << 7);

    *fn = r;
    *fz = r;
    if (fd == 0u) {
        *fc = (r >> 6) & 1u;
        *fv = ((r >> 6) ^ (r >> 5)) & 1u;
        *a = r;
        return;
    }
    *fv = (((t ^ r) >> 6) & 1u);
    if (((t & 0x0Fu) + (t & 0x01u)) > 0x05u) {
        r = (r & 0xF0u) | ((r + 0x06u) & 0x0Fu);
    }
    if (((t & 0xF0u) + (t & 0x10u)) > 0x50u) {
        r = (r & 0x0Fu) | ((r + 0x60u) & 0xF0u);
        *fc = 1u;
    } else {
        *fc = 0u;
    }
    *a = r & CPU_BYTE_MASK;
}

/*
 * cpu6502_run_until -- interpret instructions until a stop condition.
 * Steps:
 *   1. Return CPU6502_STOP_JAM at once while the JAM latch is set.
 *   2. Load the registers and the bus into locals.
 *   3. Loop while fewer than max_cycles have elapsed (every instruction adds at least two
 *      cycles, so the loop runs at most max_cycles / 2 + 1 times):
 *      a. PC == sentinel_pc: stop with CPU6502_STOP_SENTINEL before executing it;
 *      b. fetch the opcode, add its base cycles, execute it through the switch;
 *      c. a JAM opcode latches the fault and stops; BRK with brk_stops set stops
 *         before executing.
 *   4. Store the registers and the cycle counter.
 * Returns: the stop reason (cpu6502_stop_t).
 */
cpu6502_stop_t cpu6502_run_until(cpu6502_t *cpu, uint32_t sentinel_pc, uint32_t max_cycles)
{
    uint8_t *const ram = cpu->bus.ram;
    const uint32_t io_mask = cpu->bus.io_mask;
    const uint32_t io_base = cpu->bus.io_base;
    const cpu6502_io_read_fn io_rd = cpu->bus.io_read;
    const cpu6502_io_write_fn io_wr = cpu->bus.io_write;
    const uint32_t start = cpu->cycles;
    const uint32_t brk_stops = cpu->brk_stops;
    uint32_t cycles = start;
    uint32_t pc = cpu->r.pc;
    uint32_t a = cpu->r.a;
    uint32_t x = cpu->r.x;
    uint32_t y = cpu->r.y;
    uint32_t s = cpu->r.s;
    uint32_t fn;
    uint32_t fz;
    uint32_t fc;
    uint32_t fv;
    uint32_t fd;
    uint32_t fi;
    cpu6502_stop_t stop = CPU6502_STOP_CYCLES;
    int running = 1;

    if (cpu->halted != 0u) {
        return CPU6502_STOP_JAM;
    }
    UNPACK_P((uint32_t)cpu->r.p);

    while ((running != 0) && ((cycles - start) < max_cycles)) {
        uint32_t op;
        uint32_t ea = 0u;
        uint32_t v = 0u;
        uint32_t t = 0u;
        uint32_t old = 0u;

        if (pc == sentinel_pc) {
            stop = CPU6502_STOP_SENTINEL;
            break;
        }
        op = ram[pc];
        cycles += g_cyc[op];

        switch (op) {
        /* ---- ALU read group ---- */
        CASES_ALU(0x00u, OP_ORA);
        CASES_ALU(0x20u, OP_AND);
        CASES_ALU(0x40u, OP_EOR);
        CASES_ALU(0x60u, OP_ADC);
        CASES_ALU(0xA0u, OP_LDA);
        CASES_ALU(0xC0u, OP_CMP);
        CASES_ALU(0xE0u, OP_SBC);
        case 0xEBu: AM_IMM(); OP_SBC(); break;              /* undocumented SBC #imm */

        /* ---- STA ---- */
        case 0x81u: AM_IZX();   WR(ea, a); break;
        case 0x85u: AM_ZP();    ram[ea] = (uint8_t)a; break;
        case 0x8Du: AM_ABS();   WR(ea, a); break;
        case 0x91u: AM_IZY_W(); WR(ea, a); break;
        case 0x95u: AM_ZPX();   ram[ea] = (uint8_t)a; break;
        case 0x99u: AM_ABY_W(); WR(ea, a); break;
        case 0x9Du: AM_ABX_W(); WR(ea, a); break;

        /* ---- LDX / LDY / STX / STY ---- */
        case 0xA2u: AM_IMM();                x = v; SET_NZ(x); break;
        case 0xA6u: AM_ZP();    v = ram[ea]; x = v; SET_NZ(x); break;
        case 0xB6u: AM_ZPY();   v = ram[ea]; x = v; SET_NZ(x); break;
        case 0xAEu: AM_ABS();   v = RD(ea);  x = v; SET_NZ(x); break;
        case 0xBEu: AM_ABY_R(); v = RD(ea);  x = v; SET_NZ(x); break;
        case 0xA0u: AM_IMM();                y = v; SET_NZ(y); break;
        case 0xA4u: AM_ZP();    v = ram[ea]; y = v; SET_NZ(y); break;
        case 0xB4u: AM_ZPX();   v = ram[ea]; y = v; SET_NZ(y); break;
        case 0xACu: AM_ABS();   v = RD(ea);  y = v; SET_NZ(y); break;
        case 0xBCu: AM_ABX_R(); v = RD(ea);  y = v; SET_NZ(y); break;
        case 0x86u: AM_ZP();    ram[ea] = (uint8_t)x; break;
        case 0x96u: AM_ZPY();   ram[ea] = (uint8_t)x; break;
        case 0x8Eu: AM_ABS();   WR(ea, x); break;
        case 0x84u: AM_ZP();    ram[ea] = (uint8_t)y; break;
        case 0x94u: AM_ZPX();   ram[ea] = (uint8_t)y; break;
        case 0x8Cu: AM_ABS();   WR(ea, y); break;

        /* ---- CPX / CPY / BIT ---- */
        case 0xE0u: AM_IMM();                OP_CPX(); break;
        case 0xE4u: AM_ZP();    v = ram[ea]; OP_CPX(); break;
        case 0xECu: AM_ABS();   v = RD(ea);  OP_CPX(); break;
        case 0xC0u: AM_IMM();                OP_CPY(); break;
        case 0xC4u: AM_ZP();    v = ram[ea]; OP_CPY(); break;
        case 0xCCu: AM_ABS();   v = RD(ea);  OP_CPY(); break;
        case 0x24u: AM_ZP();    v = ram[ea]; fn = v; fv = (v >> 6) & 1u; fz = a & v; break;
        case 0x2Cu: AM_ABS();   v = RD(ea);  fn = v; fv = (v >> 6) & 1u; fz = a & v; break;

        /* ---- shifts, rotates, INC/DEC ---- */
        case 0x0Au: v = a; RMW_ASL(); a = v; PC_ADV(1u); break;
        case 0x2Au: v = a; RMW_ROL(); a = v; PC_ADV(1u); break;
        case 0x4Au: v = a; RMW_LSR(); a = v; PC_ADV(1u); break;
        case 0x6Au: v = a; RMW_ROR(); a = v; PC_ADV(1u); break;
        CASES_RMW(0x00u, RMW_ASL);
        CASES_RMW(0x20u, RMW_ROL);
        CASES_RMW(0x40u, RMW_LSR);
        CASES_RMW(0x60u, RMW_ROR);
        CASES_RMW(0xC0u, RMW_DEC);
        CASES_RMW(0xE0u, RMW_INC);

        /* ---- register transfers and increments ---- */
        case 0xAAu: x = a; SET_NZ(x); PC_ADV(1u); break;            /* TAX */
        case 0x8Au: a = x; SET_NZ(a); PC_ADV(1u); break;            /* TXA */
        case 0xA8u: y = a; SET_NZ(y); PC_ADV(1u); break;            /* TAY */
        case 0x98u: a = y; SET_NZ(a); PC_ADV(1u); break;            /* TYA */
        case 0xBAu: x = s; SET_NZ(x); PC_ADV(1u); break;            /* TSX */
        case 0x9Au: s = x; PC_ADV(1u); break;                       /* TXS */
        case 0xE8u: x = (x + 1u) & CPU_BYTE_MASK; SET_NZ(x); PC_ADV(1u); break;
        case 0xCAu: x = (x - 1u) & CPU_BYTE_MASK; SET_NZ(x); PC_ADV(1u); break;
        case 0xC8u: y = (y + 1u) & CPU_BYTE_MASK; SET_NZ(y); PC_ADV(1u); break;
        case 0x88u: y = (y - 1u) & CPU_BYTE_MASK; SET_NZ(y); PC_ADV(1u); break;

        /* ---- flags ---- */
        case 0x18u: fc = 0u; PC_ADV(1u); break;
        case 0x38u: fc = 1u; PC_ADV(1u); break;
        case 0x58u: fi = 0u; PC_ADV(1u); break;
        case 0x78u: fi = 1u; PC_ADV(1u); break;
        case 0xB8u: fv = 0u; PC_ADV(1u); break;
        case 0xD8u: fd = 0u; PC_ADV(1u); break;
        case 0xF8u: fd = 1u; PC_ADV(1u); break;

        /* ---- stack ---- */
        case 0x48u: PUSH(a); PC_ADV(1u); break;
        case 0x08u: PUSH(PACK_P() | CPU6502_P_B); PC_ADV(1u); break;
        case 0x68u: a = PULL(); SET_NZ(a); PC_ADV(1u); break;
        case 0x28u: v = PULL(); UNPACK_P(v); PC_ADV(1u); break;

        /* ---- branches ---- */
        case 0x10u: BRANCH((fn & 0x80u) == 0u); break;
        case 0x30u: BRANCH((fn & 0x80u) != 0u); break;
        case 0x50u: BRANCH(fv == 0u); break;
        case 0x70u: BRANCH(fv != 0u); break;
        case 0x90u: BRANCH(fc == 0u); break;
        case 0xB0u: BRANCH(fc != 0u); break;
        case 0xD0u: BRANCH(fz != 0u); break;
        case 0xF0u: BRANCH(fz == 0u); break;

        /* ---- jumps, subroutines, interrupts ---- */
        case 0x4Cu: pc = OPW(); break;
        case 0x6Cu:                                                  /* JMP (ind), page-wrap bug */
            t = OPW();
            pc = (uint32_t)ram[t] | ((uint32_t)ram[(t & 0xFF00u) | ((t + 1u) & CPU_BYTE_MASK)] << 8);
            break;
        case 0x20u:
            t = OPW();
            v = (pc + 2u) & CPU_ADDR_MASK;
            PUSH(v >> 8);
            PUSH(v & CPU_BYTE_MASK);
            pc = t;
            break;
        case 0x60u:
            v = PULL();
            v |= PULL() << 8;
            pc = (v + 1u) & CPU_ADDR_MASK;
            break;
        case 0x40u:
            v = PULL();
            UNPACK_P(v);
            v = PULL();
            v |= PULL() << 8;
            pc = v;
            break;
        case 0x00u:
            if (brk_stops != 0u) {
                cycles -= g_cyc[0x00u];
                stop = CPU6502_STOP_BRK;
                running = 0;
                break;
            }
            v = (pc + 2u) & CPU_ADDR_MASK;
            PUSH(v >> 8);
            PUSH(v & CPU_BYTE_MASK);
            PUSH(PACK_P() | CPU6502_P_B);
            fi = 1u;
            pc = (uint32_t)ram[CPU6502_VEC_IRQ] | ((uint32_t)ram[CPU6502_VEC_IRQ + 1u] << 8);
            break;

        /* ---- NOPs (documented and undocumented) ---- */
        case 0xEAu: case 0x1Au: case 0x3Au: case 0x5Au: case 0x7Au: case 0xDAu: case 0xFAu:
            PC_ADV(1u);
            break;
        case 0x80u: case 0x82u: case 0x89u: case 0xC2u: case 0xE2u:   /* NOP #imm */
        case 0x04u: case 0x44u: case 0x64u:                           /* NOP zp */
        case 0x14u: case 0x34u: case 0x54u: case 0x74u: case 0xD4u: case 0xF4u: /* NOP zp,X */
            PC_ADV(2u);
            break;
        case 0x0Cu:                                                   /* NOP abs */
            PC_ADV(3u);
            break;
        case 0x1Cu: case 0x3Cu: case 0x5Cu: case 0x7Cu: case 0xDCu: case 0xFCu: /* NOP abs,X */
            AM_ABX_R();
            break;

        /* ---- stable undocumented ---- */
        CASES_RMW_ALU(0x00u, RMW_ASL, OP_ORA);                       /* SLO */
        CASES_RMW_ALU(0x20u, RMW_ROL, OP_AND);                       /* RLA */
        CASES_RMW_ALU(0x40u, RMW_LSR, OP_EOR);                       /* SRE */
        CASES_RMW_ALU(0x60u, RMW_ROR, OP_ADC);                       /* RRA */
        CASES_RMW_ALU(0xC0u, RMW_DEC, OP_CMP);                       /* DCP */
        CASES_RMW_ALU(0xE0u, RMW_INC, OP_SBC);                       /* ISC */
        case 0xA3u: AM_IZX();   v = RD(ea);  OP_LAX(); break;
        case 0xA7u: AM_ZP();    v = ram[ea]; OP_LAX(); break;
        case 0xAFu: AM_ABS();   v = RD(ea);  OP_LAX(); break;
        case 0xB3u: AM_IZY_R(); v = RD(ea);  OP_LAX(); break;
        case 0xB7u: AM_ZPY();   v = ram[ea]; OP_LAX(); break;
        case 0xBFu: AM_ABY_R(); v = RD(ea);  OP_LAX(); break;
        case 0x83u: AM_IZX();   WR(ea, a & x); break;                /* SAX */
        case 0x87u: AM_ZP();    ram[ea] = (uint8_t)(a & x); break;
        case 0x8Fu: AM_ABS();   WR(ea, a & x); break;
        case 0x97u: AM_ZPY();   ram[ea] = (uint8_t)(a & x); break;
        case 0x0Bu: case 0x2Bu:                                       /* ANC #imm */
            AM_IMM(); a &= v; SET_NZ(a); fc = a >> 7; break;
        case 0x4Bu:                                                   /* ALR #imm */
            AM_IMM(); a &= v; fc = a & 1u; a >>= 1; SET_NZ(a); break;
        case 0x6Bu:                                                   /* ARR #imm */
            AM_IMM(); arr_op(&a, v, fd, &fn, &fz, &fv, &fc); break;
        case 0xCBu:                                                   /* SBX #imm */
            AM_IMM(); t = a & x; fc = (t >= v) ? 1u : 0u; x = (t - v) & CPU_BYTE_MASK;
            SET_NZ(x); break;

        /* ---- unstable undocumented (common model, see cpu6502.h) ---- */
        case 0x8Bu:                                                   /* ANE #imm */
            AM_IMM(); a = (a | CPU_MAGIC_ANE) & x & v; SET_NZ(a); break;
        case 0xABu:                                                   /* LXA #imm */
            AM_IMM(); a = (a | CPU_MAGIC_ANE) & v; x = a; SET_NZ(a); break;
        case 0xBBu:                                                   /* LAS abs,Y */
            AM_ABY_R(); v = RD(ea) & s; a = v; x = v; s = v; SET_NZ(v); break;
        case 0x9Fu:                                                   /* SHA abs,Y */
            AM_ABY_W(); v = a & x & ((t >> 8) + 1u);
            if (((t ^ ea) & 0x100u) != 0u) { ea = (ea & CPU_BYTE_MASK) | ((v & CPU_BYTE_MASK) << 8); }
            WR(ea, v); break;
        case 0x93u:                                                   /* SHA (zp),Y */
            AM_IZY_W(); v = a & x & ((t >> 8) + 1u);
            if (((t ^ ea) & 0x100u) != 0u) { ea = (ea & CPU_BYTE_MASK) | ((v & CPU_BYTE_MASK) << 8); }
            WR(ea, v); break;
        case 0x9Eu:                                                   /* SHX abs,Y */
            AM_ABY_W(); v = x & ((t >> 8) + 1u);
            if (((t ^ ea) & 0x100u) != 0u) { ea = (ea & CPU_BYTE_MASK) | ((v & CPU_BYTE_MASK) << 8); }
            WR(ea, v); break;
        case 0x9Cu:                                                   /* SHY abs,X */
            AM_ABX_W(); v = y & ((t >> 8) + 1u);
            if (((t ^ ea) & 0x100u) != 0u) { ea = (ea & CPU_BYTE_MASK) | ((v & CPU_BYTE_MASK) << 8); }
            WR(ea, v); break;
        case 0x9Bu:                                                   /* TAS abs,Y */
            AM_ABY_W(); s = a & x; v = s & ((t >> 8) + 1u);
            if (((t ^ ea) & 0x100u) != 0u) { ea = (ea & CPU_BYTE_MASK) | ((v & CPU_BYTE_MASK) << 8); }
            WR(ea, v); break;

        /* ---- JAM ---- */
        default:
            cpu->halted = 1u;
            cpu->jam_opcode = (uint8_t)op;
            stop = CPU6502_STOP_JAM;
            running = 0;
            break;
        }
    }

    cpu->r.pc = (uint16_t)pc;
    cpu->r.a = (uint8_t)a;
    cpu->r.x = (uint8_t)x;
    cpu->r.y = (uint8_t)y;
    cpu->r.s = (uint8_t)s;
    cpu->r.p = (uint8_t)PACK_P();
    cpu->cycles = cycles;
    return stop;
}

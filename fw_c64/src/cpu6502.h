/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: cpu6502.h
 * Role: NMOS 6502 (6510 core) instruction interpreter of the core 0 player.
 *
 * Contract:
 *   - All 151 documented opcodes with NMOS flag behaviour, including decimal-mode
 *     ADC/SBC with the NMOS N/V/Z results (N and V from the intermediate sum of
 *     the BCD adder, Z from the binary sum; SBC flags all from the binary
 *     difference), as Bruce Clark's decimal test (third_party/dormann/6502_decimal_test.bin with
 *     chk_n/v/z/c = 1) predicts for the 6502.
 *   - The stable undocumented opcodes LAX SAX DCP ISC SLO RLA SRE RRA ANC ALR ARR
 *     SBX, SBC #imm at $EB, and every NOP variant with its operand bytes and
 *     cycles. The unstable group (ANE $8B, LXA $AB, SHA $93/$9F, SHX $9E,
 *     SHY $9C, TAS $9B, LAS $BB) uses the common emulator model (magic constant
 *     $EE for ANE/LXA; SHx store value AND (base high byte + 1), the high byte of
 *     the address replaced by that value on a page cross).
 *   - The twelve JAM opcodes ($02 $12 $22 $32 $42 $52 $62 $72 $92 $B2 $D2 $F2)
 *     halt the CPU: PC stays on the JAM byte, the fault is latched and every
 *     later run returns CPU6502_STOP_JAM until cpu6502_reset or cpu6502_set_regs.
 *   - Cycle counts: exact NMOS base counts, +1 on a page cross for indexed reads
 *     (abs,X abs,Y (zp),Y of the read group, LAX, LAS, NOP abs,X), +1 for a taken
 *     branch and +1 more when it lands on another page. Stores and
 *     read-modify-write instructions always take their fixed count.
 *   - IRQ and NMI lines are not modelled; BRK and RTI are.
 *
 * Memory: every access goes through the bus (cpu6502_bus_t). Addresses whose
 *   (addr & io_mask) == io_base go to the io_read / io_write callbacks; all
 *   others hit bus.ram[] directly. Zero page, stack, vector and opcode/operand
 *   fetches always read bus.ram[] (code never executes from the I/O window).
 *   The callbacks receive a cycle stamp: the cpu cycle counter value of the bus
 *   cycle doing the access (instruction start + base cycles - 1 for the final
 *   access; read-modify-write instructions issue the NMOS dummy write of the
 *   unmodified value one cycle earlier).
 *
 * Concurrency: a cpu6502_t is used from one context only (the core 0 main loop).
 * Headers hold signatures, constants, types and contract prose; per-function
 *   commentary lives in cpu6502.c.
 */
#ifndef CPU6502_H
#define CPU6502_H

#include <stdint.h> /* uint8_t, uint16_t, uint32_t */

/* Status register bits. */
#define CPU6502_P_C            (0x01u)
#define CPU6502_P_Z            (0x02u)
#define CPU6502_P_I            (0x04u)
#define CPU6502_P_D            (0x08u)
#define CPU6502_P_B            (0x10u)
#define CPU6502_P_U            (0x20u) /* always reads 1 */
#define CPU6502_P_V            (0x40u)
#define CPU6502_P_N            (0x80u)

/* Vectors. */
#define CPU6502_VEC_NMI        (0xFFFAu)
#define CPU6502_VEC_RESET      (0xFFFCu)
#define CPU6502_VEC_IRQ        (0xFFFEu)

#define CPU6502_STACK_PAGE     (0x0100u)
#define CPU6502_MEM_BYTES      (65536u) /* bus.ram[] must hold this many bytes */

/* sentinel_pc value that never matches a 16-bit PC. */
#define CPU6502_NO_SENTINEL    (0x10000u)

/* Why cpu6502_run_until returned. */
typedef enum
{
    CPU6502_STOP_SENTINEL = 0, /* PC reached sentinel_pc (that instruction is not executed) */
    CPU6502_STOP_CYCLES   = 1, /* max_cycles were used up */
    CPU6502_STOP_JAM      = 2, /* a JAM opcode halted the CPU (PC on the JAM byte) */
    CPU6502_STOP_BRK      = 3  /* BRK with brk_stops set (PC on the BRK byte, not executed) */
} cpu6502_stop_t;

typedef uint8_t (*cpu6502_io_read_fn)(uint16_t addr, uint32_t cycle);
typedef void (*cpu6502_io_write_fn)(uint16_t addr, uint8_t val, uint32_t cycle);

/* Memory bus. ram points at CPU6502_MEM_BYTES bytes owned by the bus provider. */
typedef struct
{
    uint8_t            *ram;
    uint32_t            io_mask;   /* e.g. 0xF000 */
    uint32_t            io_base;   /* e.g. 0xD000; a value above 0xFFFF disables the window */
    cpu6502_io_read_fn  io_read;
    cpu6502_io_write_fn io_write;
} cpu6502_bus_t;

/* Programmer-visible registers. */
typedef struct
{
    uint16_t pc;
    uint8_t  a;
    uint8_t  x;
    uint8_t  y;
    uint8_t  s;
    uint8_t  p;   /* packed NV-BDIZC; U reads as 1, B is not a stored flag */
} cpu6502_regs_t;

/* CPU state. Treat the fields as private; use the functions below. */
typedef struct
{
    cpu6502_bus_t  bus;
    cpu6502_regs_t r;
    uint32_t       cycles;      /* free-running cycle counter, wraps at 2^32 */
    uint8_t        halted;      /* 1 after a JAM */
    uint8_t        jam_opcode;  /* the JAM byte that halted the CPU */
    uint8_t        brk_stops;   /* 1: BRK returns CPU6502_STOP_BRK instead of executing */
} cpu6502_t;

void cpu6502_init(cpu6502_t *cpu, const cpu6502_bus_t *bus);
void cpu6502_reset(cpu6502_t *cpu);
void cpu6502_set_regs(cpu6502_t *cpu, const cpu6502_regs_t *regs);
void cpu6502_get_regs(const cpu6502_t *cpu, cpu6502_regs_t *regs);
void cpu6502_set_pc(cpu6502_t *cpu, uint16_t pc);
void cpu6502_set_brk_stop(cpu6502_t *cpu, int enable);
uint32_t cpu6502_cycles(const cpu6502_t *cpu);
int cpu6502_jam_opcode(const cpu6502_t *cpu);
cpu6502_stop_t cpu6502_step(cpu6502_t *cpu);
cpu6502_stop_t cpu6502_run_until(cpu6502_t *cpu, uint32_t sentinel_pc, uint32_t max_cycles);

#endif /* CPU6502_H */

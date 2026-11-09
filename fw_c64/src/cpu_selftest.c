/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: cpu_selftest.c
 * Role: runs a Dormann test image on the player's 6502 and classifies the end
 *   state (contract in cpu_selftest.h).
 */
#include "cpu_selftest.h"

#include "c64mem.h"
#include "cpu6502.h"

#include <stddef.h> /* NULL */

static const char *const g_status_text[] = {
    "PASS",
    "FAIL (ERROR TRAP)",
    "FAIL (JAM)",
    "FAIL (TIMEOUT)",
    "FAIL (BAD IMAGE)",
};

_Static_assert(sizeof(g_status_text) / sizeof(g_status_text[0]) == (size_t)CPU_SELFTEST_FAIL_IMAGE + 1u,
               "g_status_text must have one entry per cpu_selftest_status_t");

/*
 * cpu_selftest_load -- place an image in the C64 RAM.
 * Steps:
 *   1. Check the descriptor: segments present, at most CPU_SELFTEST_MAX_SEGS, each
 *      non-NULL and inside $0000-$FFFF.
 *   2. Reset c64mem, fill RAM with the image's fill byte, copy every segment.
 * Returns: 0 when loaded, -1 for a bad descriptor (RAM state then unspecified).
 */
static int cpu_selftest_load(const cpu_selftest_image_t *img)
{
    if (img->segs == NULL || img->n_segs == 0u || img->n_segs > CPU_SELFTEST_MAX_SEGS) {
        return -1;
    }
    c64mem_reset();
    c64mem_fill(img->fill);
    for (uint32_t i = 0u; i < img->n_segs; i++) {
        if (c64mem_load(img->segs[i].load, img->segs[i].data, img->segs[i].len) != 0) {
            return -1;
        }
    }
    return 0;
}

/*
 * cpu_selftest_run -- run one test image to its success trap or a failure.
 * Steps:
 *   1. Load the image; PC = start, A = X = Y = 0, S = $FF, P = U|I; BRK executes.
 *   2. Run in slices of CPU_SELFTEST_CHUNK_CYCLES with the success trap as sentinel,
 *      at most max_cycles / CPU_SELFTEST_CHUNK_CYCLES + 1 slices:
 *      a. sentinel (or a slice ending on the success PC): PASS;
 *      b. JAM: FAIL_JAM at the JAM byte;
 *      c. otherwise step one instruction: a PC that does not move is an error trap
 *         (FAIL_TRAP at that PC).
 *   3. Budget used up: FAIL_TIMEOUT.
 * Returns: the status (also in res->status); res receives PC, cycles and JAM opcode.
 */
cpu_selftest_status_t cpu_selftest_run(const cpu_selftest_image_t *img, cpu_selftest_result_t *res)
{
    cpu6502_t *cpu = c64mem_cpu();
    cpu6502_regs_t r;
    uint32_t start_cycles;
    uint32_t spent = 0u;
    const uint32_t max_slices = (img != NULL) ? img->max_cycles / CPU_SELFTEST_CHUNK_CYCLES + 1u : 0u;

    res->status = CPU_SELFTEST_FAIL_IMAGE;
    res->pc = 0u;
    res->cycles = 0u;
    res->jam_opcode = -1;
    if (img == NULL || cpu_selftest_load(img) != 0) {
        return res->status;
    }

    r.pc = img->start_pc;
    r.a = 0u;
    r.x = 0u;
    r.y = 0u;
    r.s = 0xFFu;
    r.p = (uint8_t)(CPU6502_P_U | CPU6502_P_I);
    cpu6502_set_regs(cpu, &r);
    cpu6502_set_brk_stop(cpu, 0);
    start_cycles = cpu6502_cycles(cpu);

    res->status = CPU_SELFTEST_FAIL_TIMEOUT;
    for (uint32_t slice = 0u; slice < max_slices && spent < img->max_cycles; slice++) {
        const uint32_t left = img->max_cycles - spent;
        const uint32_t chunk = (left < CPU_SELFTEST_CHUNK_CYCLES) ? left : CPU_SELFTEST_CHUNK_CYCLES;
        const cpu6502_stop_t stop = cpu6502_run_until(cpu, img->success_pc, chunk);
        uint16_t pc_before;

        cpu6502_get_regs(cpu, &r);
        spent = cpu6502_cycles(cpu) - start_cycles;
        if (stop == CPU6502_STOP_SENTINEL || r.pc == img->success_pc) {
            res->status = CPU_SELFTEST_PASS;
            break;
        }
        if (stop == CPU6502_STOP_JAM) {
            res->status = CPU_SELFTEST_FAIL_JAM;
            res->jam_opcode = cpu6502_jam_opcode(cpu);
            break;
        }
        pc_before = r.pc;
        if (cpu6502_step(cpu) == CPU6502_STOP_JAM) {
            res->status = CPU_SELFTEST_FAIL_JAM;
            res->jam_opcode = cpu6502_jam_opcode(cpu);
            break;
        }
        cpu6502_get_regs(cpu, &r);
        spent = cpu6502_cycles(cpu) - start_cycles;
        if (r.pc == pc_before) {
            res->status = CPU_SELFTEST_FAIL_TRAP;
            break;
        }
    }
    cpu6502_get_regs(cpu, &r);
    res->pc = r.pc;
    res->cycles = spent;
    return res->status;
}

/*
 * cpu_selftest_status_text -- CLI text for a status.
 * Returns: a fixed string; "FAIL (UNKNOWN)" out of range.
 */
const char *cpu_selftest_status_text(cpu_selftest_status_t status)
{
    if ((uint32_t)status > (uint32_t)CPU_SELFTEST_FAIL_IMAGE) {
        return "FAIL (UNKNOWN)";
    }
    return g_status_text[status];
}

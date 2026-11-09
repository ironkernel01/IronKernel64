/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: cpu_selftest.h
 * Role: 6502 interpreter self-test: runs Klaus Dormann's 6502_functional_test and
 *   Bruce Clark's decimal test (Dormann's configuration, NMOS, all flags checked)
 *   inside c64mem and reports PASS/FAIL with the trap PC. Backs the `cputest` CLI
 *   command (selftest.c).
 *
 * Test images (third_party/dormann/, GPL-3.0, provenance in third_party/dormann/SOURCE.txt):
 *   image                       load   start  success trap  fill  budget
 *   6502_functional_test.bin    $0000  $0400  $3469         $FF   CPU_SELFTEST_FUNC_MAX_CYCLES
 *   6502_decimal_test.bin       $0200  $0200  $024F         $00   CPU_SELFTEST_DEC_MAX_CYCLES
 *   The functional image is a full 64 KiB dump whose unused bytes are $FF; it is
 *   embedded as its non-fill segments ($0000-$0059, $0200-$0269, $0400-$3834,
 *   $FFFA-$FFFF) and replayed over RAM filled with $FF, which reproduces it byte
 *   for byte.
 *   The decimal image ends in "lda ERROR / bne fail / jmp * (success) / jmp *
 *   (failure)" at $024B; its failure trap is $0252.
 *
 * NOTE FOR THE BUILD (fw_c64/build.ps1, owned by the lead): the images are embedded
 *   by a generated C file, not by objcopy, so no extern linker symbols are needed:
 *     python -I tools/dormann_bin2c.py third_party/dormann/6502_functional_test.bin \
 *         third_party/dormann/6502_decimal_test.bin <build>/gen/cpu_selftest_images.c
 *   then compile <build>/gen/cpu_selftest_images.c with the firmware sources. It
 *   defines cpu_selftest_image_count() and cpu_selftest_image() below, verifies
 *   the start and success-trap bytes of each image at generation time and fails
 *   loudly on a mismatch. The generated file holds 13,834 bytes of image data in
 *   .rodata (13,567 functional, 267 decimal). third_party/dormann/6502_decimal_test.bin
 *   itself is rebuilt from the upstream source with
 *     python -I tools/dormann_decimal.py third_party/dormann/6502_decimal_test.a65 third_party/dormann/6502_decimal_test.bin
 *
 * Pass/fail rule: the run passes when PC reaches the image's success trap. Any
 *   other PC that loops onto itself (JMP * or a branch to itself: every Dormann
 *   error trap) fails with that PC, a JAM fails with its PC, and running out of
 *   the cycle budget fails as a timeout. BRK executes normally (the functional
 *   test checks it); IRQ/NMI are not used.
 * Concurrency: core 0 main loop; the test overwrites the whole C64 RAM (reload
 *   the tune afterwards).
 * Headers hold signatures, constants, types and contract prose; per-function
 *   commentary lives in cpu_selftest.c.
 */
#ifndef CPU_SELFTEST_H
#define CPU_SELFTEST_H

#include <stdint.h> /* uint8_t, uint16_t, uint32_t */

#define CPU_SELFTEST_MAX_SEGS        (8u)       /* functional image: 4 segments */
#define CPU_SELFTEST_CHUNK_CYCLES    (1000000u)   /* run slice between trap checks */

/* Image addresses (also checked by tools/dormann_bin2c.py against the image bytes). */
#define CPU_SELFTEST_FUNC_START      (0x0400u)
#define CPU_SELFTEST_FUNC_SUCCESS    (0x3469u)
#define CPU_SELFTEST_DEC_START       (0x0200u)
#define CPU_SELFTEST_DEC_SUCCESS     (0x024Fu)
/*
 * Cycle budgets: upper bounds, not expected values (the exact counts are measured
 * on the board; cputest prints them).
 *   decimal: 2 carry values x 256 x 256 operand pairs x about 350 cycles per pair
 *            (ADD/SUB, the predictions and two compares) = about 46 M; budget 100 M.
 *   functional: tens of millions of cycles for the published image; budget 200 M.
 * At 100 MHz a 200 M-cycle budget is a bound of tens of seconds of core 0 time.
 */
#define CPU_SELFTEST_FUNC_MAX_CYCLES (200000000u)
#define CPU_SELFTEST_DEC_MAX_CYCLES  (100000000u)

typedef struct
{
    const uint8_t *data;
    uint32_t       len;
    uint32_t       load;       /* load address; load + len <= 0x10000 */
} cpu_selftest_seg_t;

typedef struct
{
    const char               *name;
    const cpu_selftest_seg_t *segs;
    uint32_t                  n_segs;      /* 1..CPU_SELFTEST_MAX_SEGS */
    uint8_t                   fill;        /* RAM fill before the segments are loaded */
    uint16_t                  start_pc;
    uint16_t                  success_pc;
    uint32_t                  max_cycles;
} cpu_selftest_image_t;

typedef enum
{
    CPU_SELFTEST_PASS         = 0,
    CPU_SELFTEST_FAIL_TRAP    = 1,  /* looped on an error trap; pc = trap PC */
    CPU_SELFTEST_FAIL_JAM     = 2,  /* JAM opcode; pc = its address */
    CPU_SELFTEST_FAIL_TIMEOUT = 3,  /* budget used up; pc = PC at the end */
    CPU_SELFTEST_FAIL_IMAGE   = 4   /* bad descriptor (NULL, no segments, range past $FFFF) */
} cpu_selftest_status_t;

typedef struct
{
    cpu_selftest_status_t status;
    uint16_t              pc;          /* success, trap or final PC */
    uint32_t              cycles;      /* 6502 cycles executed */
    int                   jam_opcode;  /* -1 unless FAIL_JAM */
} cpu_selftest_result_t;

cpu_selftest_status_t cpu_selftest_run(const cpu_selftest_image_t *img, cpu_selftest_result_t *res);
const char *cpu_selftest_status_text(cpu_selftest_status_t status);

/* Defined by the generated cpu_selftest_images.c (tools/dormann_bin2c.py). */
uint32_t cpu_selftest_image_count(void);
const cpu_selftest_image_t *cpu_selftest_image(uint32_t index);

#endif /* CPU_SELFTEST_H */

/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * sid_envmodel_host_test.c -- host test of fw_c64/src/sid_envmodel.c: rate table, gate on
 * ramp, sustain hold, release to 0, exponential decay, per-voice registers, stamp handling.
 *
 * Build and run (MSYS2 UCRT64):
 *   gcc -std=c11 -Wall -Wextra -Werror -pedantic -Ifw_c64/src tools/sid_envmodel_host_test.c \
 *       fw_c64/src/sid_envmodel.c -o build/sid_envmodel_host_test.exe
 *   build/sid_envmodel_host_test.exe [+INJECT_FAILURE]
 * Prints "TEST PASS: sid_envmodel_host" or "TEST FAIL" (exit 1).
 */
#include "sid_envmodel.h"

#include <stdio.h>
#include <string.h>

#define PHI2_HZ  (985248u)

static int g_fail;

static void check(const char *what, uint32_t got, uint32_t want)
{
    if (got != want) {
        printf("  FAIL %s: got %u, want %u\n", what, (unsigned)got, (unsigned)want);
        g_fail = 1;
    }
}

static void check_range(const char *what, uint32_t got, uint32_t lo, uint32_t hi)
{
    if (got < lo || got > hi) {
        printf("  FAIL %s: got %u, want %u..%u\n", what, (unsigned)got, (unsigned)lo, (unsigned)hi);
        g_fail = 1;
    }
}

/* Documented SID attack times in ms, and decay/release (x3). */
static const uint32_t ATTACK_MS[16] = { 2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000,
                                        5000, 8000 };

static void test_rates(void)
{
    char what[40];

    for (uint32_t n = 0u; n < 16u; n++) {
        const uint32_t ms = (uint32_t)(((uint64_t)sid_envmodel_rate_period((uint8_t)n) * 255u * 1000u) / PHI2_HZ);
        const uint32_t want = ATTACK_MS[n];

        /* within 12 % (+1 ms rounding) of the data sheet value */
        snprintf(what, sizeof(what), "attack ms nibble %u", (unsigned)n);
        check_range(what, ms, (want * 88u) / 100u, ((want * 112u) / 100u) + 1u);
    }
    check("period[0]", sid_envmodel_rate_period(0u), 9u);
    check("period[15]", sid_envmodel_rate_period(15u), 31251u);
    check("period masks nibble", sid_envmodel_rate_period(0x1Fu), 31251u);
    check("exp 255", sid_envmodel_exp_period(255u), 1u);
    check("exp 94", sid_envmodel_exp_period(94u), 1u);
    check("exp 93", sid_envmodel_exp_period(93u), 2u);
    check("exp 54", sid_envmodel_exp_period(54u), 4u);
    check("exp 26", sid_envmodel_exp_period(26u), 8u);
    check("exp 14", sid_envmodel_exp_period(14u), 16u);
    check("exp 6", sid_envmodel_exp_period(6u), 30u);
    check("exp 0", sid_envmodel_exp_period(0u), 30u);
}

static void test_adsr(void)
{
    sid_envmodel_t m;
    uint32_t t = 100u;
    uint8_t prev;

    sid_envmodel_reset(&m, t);
    check("reset level", sid_envmodel_level(&m, 0u), 0u);

    /* AD = $00 (attack 9 cycles/step), SR = $A3 (sustain 170, release nibble 3 = 95). */
    sid_envmodel_write(&m, t, 5u, 0x00u);
    sid_envmodel_write(&m, t, 6u, 0xA3u);
    sid_envmodel_write(&m, t, 4u, 0x41u);                 /* gate on */
    sid_envmodel_advance(&m, t + 9u * 100u);
    check("ramp after 100 steps", sid_envmodel_level(&m, 0u), 100u);
    sid_envmodel_advance(&m, t + 9u * 100u + 9u * 27u + 4u);
    check("ramp after 127 steps", sid_envmodel_level(&m, 0u), 127u);
    check("other voices untouched", (uint32_t)sid_envmodel_level(&m, 1u) + sid_envmodel_level(&m, 2u), 0u);

    /* Past the peak: decay (nibble 0) falls exponentially to the sustain level and holds. */
    t += 9u * 255u;
    sid_envmodel_advance(&m, t + 1u);
    check_range("peak entered decay", sid_envmodel_level(&m, 0u), 250u, 255u);
    t += 100000u;
    sid_envmodel_advance(&m, t);
    check("sustain hold 170", sid_envmodel_level(&m, 0u), 170u);
    t += 5000000u;
    sid_envmodel_advance(&m, t);
    check("sustain still held", sid_envmodel_level(&m, 0u), 170u);

    /* Release (nibble 3: 95 cycles/step) falls monotonically to 0. */
    sid_envmodel_write(&m, t, 4u, 0x40u);
    prev = sid_envmodel_level(&m, 0u);
    for (uint32_t i = 0u; i < 200u; i++) {
        t += 5000u;
        sid_envmodel_advance(&m, t);
        if (sid_envmodel_level(&m, 0u) > prev) {
            check("release monotone", 1u, 0u);
        }
        prev = sid_envmodel_level(&m, 0u);
    }
    check("release to 0", sid_envmodel_level(&m, 0u), 0u);

    /* Retrigger from the present level continues the attack. */
    sid_envmodel_write(&m, t, 4u, 0x41u);
    sid_envmodel_advance(&m, t + 9u * 10u);
    check("retrigger attack", sid_envmodel_level(&m, 0u), 10u);
}

static void test_decay_time(void)
{
    sid_envmodel_t m;
    uint32_t ticks = 0u;
    uint32_t cycles;

    /* Decay nibble 0, sustain 0: the full 255 -> 0 fall takes the sum of the exp periods. */
    for (uint32_t l = 255u; l > 0u; l--) {
        ticks += sid_envmodel_exp_period((uint8_t)l);
    }
    sid_envmodel_reset(&m, 0u);
    sid_envmodel_write(&m, 0u, 5u, 0x00u);
    sid_envmodel_write(&m, 0u, 6u, 0x00u);
    sid_envmodel_write(&m, 0u, 4u, 0x01u);
    sid_envmodel_advance(&m, 9u * 255u);
    check("decay start level", sid_envmodel_level(&m, 0u), 255u);
    cycles = 9u * ticks;
    sid_envmodel_advance(&m, (9u * 255u) + cycles - 9u);
    check_range("decay one step before end", sid_envmodel_level(&m, 0u), 1u, 2u);
    sid_envmodel_advance(&m, (9u * 255u) + cycles);
    check("decay end", sid_envmodel_level(&m, 0u), 0u);
    /* about 3 x the linear time: 6 ms nominal */
    check_range("decay ticks about 3x", ticks, 700u, 800u);
    check_range("decay ms", (cycles * 1000u) / PHI2_HZ, 5u, 8u);

    /* Slowest attack takes about 8 s. */
    sid_envmodel_reset(&m, 0u);
    sid_envmodel_write(&m, 0u, 12u, 0xF0u);           /* voice 2 AD */
    sid_envmodel_write(&m, 0u, 13u, 0xF0u);           /* voice 2 SR: sustain 15 */
    sid_envmodel_write(&m, 0u, 11u, 0x01u);
    sid_envmodel_advance(&m, 7u * PHI2_HZ);
    check_range("attack 15 at 7 s", sid_envmodel_level(&m, 1u), 200u, 235u);
    sid_envmodel_advance(&m, 9u * PHI2_HZ);
    check("attack 15 at 9 s", sid_envmodel_level(&m, 1u), 255u);
}

static void test_voices_and_time(void)
{
    sid_envmodel_t m;

    sid_envmodel_reset(&m, 0xFFFFFF00u);               /* stamps wrap past 2^32 */
    sid_envmodel_write(&m, 0xFFFFFF00u, 19u, 0x00u);   /* voice 3 AD */
    sid_envmodel_write(&m, 0xFFFFFF00u, 20u, 0xF0u);   /* voice 3 SR */
    sid_envmodel_write(&m, 0xFFFFFF00u, 18u, 0x01u);   /* voice 3 gate */
    sid_envmodel_write(&m, 0xFFFFFF00u, 4u, 0x01u);    /* voice 1 gate: AD = 0, 9 cycles/step */
    sid_envmodel_advance(&m, 0x00000090u);             /* 0x190 = 400 cycles later */
    check_range("wrapped time voice 3", sid_envmodel_level(&m, 2u), 40u, 46u);
    check("voice 1 same rate", sid_envmodel_level(&m, 0u), sid_envmodel_level(&m, 2u));
    check("voice 2 idle", sid_envmodel_level(&m, 1u), 0u);
    {
        const uint8_t before = sid_envmodel_level(&m, 2u);

        sid_envmodel_advance(&m, 0xFFFFFF00u);           /* backwards: ignored */
        check("backwards stamp ignored", sid_envmodel_level(&m, 2u), before);
    }
    sid_envmodel_write(&m, 0u, 21u, 0xFFu);              /* register 21: ignored */
    sid_envmodel_write(&m, 0u, 24u, 0xFFu);
    check("voice index range", sid_envmodel_level(&m, 3u), 0u);
}

int main(int argc, char **argv)
{
    const int inject = (argc > 1 && strcmp(argv[1], "+INJECT_FAILURE") == 0);

    test_rates();
    test_adsr();
    test_decay_time();
    test_voices_and_time();
    if (inject) {
        check("injected failure", 1u, 2u);
    }
    if (g_fail != 0) {
        printf("TEST FAIL\n");
        return 1;
    }
    printf("TEST PASS: sid_envmodel_host\n");
    return 0;
}

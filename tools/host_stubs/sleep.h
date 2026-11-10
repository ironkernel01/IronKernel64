/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Host stand-in for the BSP's sleep.h (used by tools/np_switch_host_test.c): a delay is a no-op. */
#ifndef HOST_STUB_SLEEP_H
#define HOST_STUB_SLEEP_H

#include <stdint.h>

static inline void usleep(uint32_t us)
{
    (void)us;
}

#endif /* HOST_STUB_SLEEP_H */

/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: main.c
 * Role: core 1 ("1541" drive) firmware entry: network bring-up and the SMB
 *   proof against the NAS share, with the log in the shared-BRAM ring that
 *   core 0 prints on its UART ("[1541] " prefix). Superloop, no RTOS, no
 *   interrupts (c64demo.md Phase 4, decision "Core 1 software: no RTOS").
 *
 * Flow (all waits bounded by the named constants below; a failed step is
 *   logged and retried, never silent):
 *   1. drive_log_init, banner (build ID and git hash from the board system
 *      registers, node MAC), caches.
 *   2. Drive server up with both backends (device 8 SMB, device 9 tune bank): device 9 answers from
 *      here on, without the network; every wait loop below services it (drive_server_idle).
 *   2b. ik64_net_init: PHY, MAC, node MAC, DHCP leaf, CPU path, DMA, lwIP.
 *   3. LINK: log link state once per second (every 10 s after
 *      MAIN_LINK_FAST_MS) until the PHY link is up.
 *   4. LEASE (NETSHARE_IP_DHCP): log once per second (every 10 s after
 *      MAIN_LEASE_FAST_MS) until the RTL DHCP leaf holds a lease; its address
 *      is logged by the network manager.
 *   5. SMB: mount the share, list the base folder (name, size, dir flag for
 *      every entry), log the free space and keep the share mounted. On any
 *      error log the status text (libsmb2 error string and NTSTATUS, never
 *      credentials), unmount and retry after MAIN_SMB_RETRY_MS (the mount
 *      itself retries a bounded number of times: session entry only).
 *   6. DONE: the drive is ready (drive_server_set_ready(1)); every loop pass
 *      services lwIP and takes one drive request (drive_server.c); log a
 *      heartbeat every MAIN_HEARTBEAT_MS. A backend failure inside a request
 *      clears ready and returns to phase 5.
 *   A link loss in phases 4-6 unmounts, clears ready and returns to phase 3.
 *
 * Caches: the 8 KiB I/D caches of the MicroBlaze V cover the DDR3 window and
 *   are enabled by the hardware (the BSP's Xil_ICacheEnable/Xil_DCacheEnable
 *   are empty macros on this CPU); main invalidates both once, because the ELF
 *   was written to DDR3 by the JTAG loader behind the caches.
 */
#include "backend_ram.h"
#include "backend_smb.h"
#include "drive_log.h"
#include "drive_server.h"
#include "fatal.h"
#include "ik64_netcore.h"
#include "ik64_sysregs.h"
#include "smb_alloc.h"

#include "xil_cache.h"      /* Xil_ICacheInvalidate, Xil_DCacheInvalidate */

#include <stddef.h>
#include <stdint.h>

#include "netshare_config.h"   /* NETSHARE_SERVER, NETSHARE_SHARE, NETSHARE_BASE_PATH, NETSHARE_IP_MODE, NETSHARE_STATIC_* (no credentials) */

#define MAIN_LINK_LOG_MS         (1000u)     /* link/lease wait log period */
#define MAIN_LINK_FAST_MS        (30000u)    /* after this long the wait log slows down */
#define MAIN_LEASE_FAST_MS       (30000u)
#define MAIN_SLOW_LOG_MS         (10000u)    /* slowed wait log period, also the "still retrying" cadence */
#define MAIN_SMB_RETRY_MS        (10000u)
#define MAIN_HEARTBEAT_MS        (30000u)
#define MAIN_LOG_SPACE_WAIT_MS   (2000u)     /* longest wait for core 0 to drain the ring before a line is dropped */
#define MAIN_NAME_LOG_MAX        (96u)       /* characters of a directory entry name that are logged */

typedef enum
{
    PHASE_LINK = 0,
    PHASE_LEASE,
    PHASE_SMB,
    PHASE_DONE
} phase_t;

static const backend_ops_t g_smb_ops = BACKEND_OPS(smb);
static const backend_ops_t g_ram_ops = BACKEND_OPS(ram);

static phase_t  g_phase;
static uint32_t g_phase_t0;        /* uptime (ms) when the phase was entered */
static uint32_t g_next_log;        /* uptime (ms) of the next wait/heartbeat/retry action */
static uint32_t g_smb_tries;
static uint32_t g_smb_entries;

/*
 * due -- wrap-safe "now has reached deadline".
 * Returns: 1 when now >= deadline.
 */
static int due(uint32_t now, uint32_t deadline)
{
    return ((int32_t)(now - deadline) >= 0) ? 1 : 0;
}

/*
 * enter -- switch phase.
 * Returns: nothing.
 */
static void enter(phase_t p, uint32_t now)
{
    g_phase = p;
    g_phase_t0 = now;
    g_next_log = now;
}

/*
 * wait_log_space -- let core 0 drain the ring before a long listing overruns it.
 * Steps:
 *   1. While less than DRIVE_LOG_LINE_BYTES are free, service the network and the drive server,
 *      for at most MAIN_LOG_SPACE_WAIT_MS; then log anyway (the line is
 *      dropped and counted by the ring, never blocking).
 * Returns: nothing.
 */
static void wait_log_space(void)
{
    const uint32_t t0 = (uint32_t)ik64_uptime_ms64();

    while ((drive_log_free_bytes() < DRIVE_LOG_LINE_BYTES) &&
           ((uint32_t)((uint32_t)ik64_uptime_ms64() - t0) < MAIN_LOG_SPACE_WAIT_MS)) {
        ik64_net_service();
        drive_server_idle();
    }
}

/*
 * log_entry -- one directory entry: size (or <DIR>) and a printable-ASCII name.
 * Returns: nothing.
 */
static void log_entry(const backend_dirent_t *e)
{
    char name[MAIN_NAME_LOG_MAX + 1u];
    size_t i;

    for (i = 0u; (i < MAIN_NAME_LOG_MAX) && (e->name[i] != '\0'); i++) {
        const char c = e->name[i];

        name[i] = ((c >= 0x20) && (c < 0x7f)) ? c : '?';
    }
    name[i] = '\0';
    wait_log_space();
    if (e->type == BACKEND_ENT_DIR) {
        drive_log_printf("SMB:   <DIR>        %s\r\n", name);
    } else if ((e->size >> 32) == 0u) {
        drive_log_printf("SMB:   %10lu B  %s%s\r\n", (unsigned long)e->size, name,
                         (e->type == BACKEND_ENT_OTHER) ? " (other)" : "");
    } else {
        drive_log_printf("SMB:   %10lu KiB %s\r\n", (unsigned long)(e->size >> 10), name);
    }
}

/*
 * smb_prove -- mount, list the base folder, report the free space, stay mounted.
 * Steps:
 *   1. backend_smb_mount (bounded retries inside; logs the dialect).
 *   2. opendir on the share root folder (NETSHARE_BASE_PATH), readdir until
 *      BACKEND_END (the listing is already in memory, so every call consumes
 *      one entry), log each entry, closedir.
 *   3. free_bytes of the volume; the share stays mounted for the drive server.
 *   Every failure logs the backend's status text, which carries the libsmb2
 *   error and NTSTATUS and never the credentials.
 * Returns: 0 on success, -1 on any failure (the session is dropped).
 */
static int smb_prove(void)
{
    char text[BACKEND_STATUS_TEXT_BYTES];
    backend_dirent_t ent;
    backend_status_t st;
    uint64_t freeb = 0u;

    g_smb_entries = 0u;
    st = backend_smb_mount();
    if (st != BACKEND_OK) {
        (void)backend_smb_status_text(text, sizeof(text));
        drive_log_printf("SMB: mount failed (status %d): %s\r\n", (int)st, text);
        return -1;
    }
    st = backend_smb_opendir("");
    if (st != BACKEND_OK) {
        (void)backend_smb_status_text(text, sizeof(text));
        drive_log_printf("SMB: opendir of \"%s\" failed (status %d): %s\r\n", NETSHARE_BASE_PATH, (int)st, text);
        (void)backend_smb_unmount();
        return -1;
    }
    drive_log_printf("SMB: listing of \\\\%s\\%s\\%s\r\n", NETSHARE_SERVER, NETSHARE_SHARE, NETSHARE_BASE_PATH);
    for (;;) {
        st = backend_smb_readdir(&ent);
        if (st == BACKEND_END) {
            break;
        }
        if (st != BACKEND_OK) {
            (void)backend_smb_status_text(text, sizeof(text));
            drive_log_printf("SMB: readdir failed (status %d): %s\r\n", (int)st, text);
            (void)backend_smb_unmount();
            return -1;
        }
        log_entry(&ent);
        g_smb_entries++;
    }
    (void)backend_smb_closedir();
    drive_log_printf("SMB: %lu entries\r\n", (unsigned long)g_smb_entries);
    st = backend_smb_free_bytes(&freeb);
    if (st == BACKEND_OK) {
        drive_log_printf("SMB: free space %lu MiB\r\n", (unsigned long)(freeb >> 20));
    } else {
        (void)backend_smb_status_text(text, sizeof(text));
        drive_log_printf("SMB: free space query failed (status %d): %s\r\n", (int)st, text);
    }
    smb_alloc_log_stats();
    return 0;
}

/*
 * step -- one pass of the phase machine.
 * Returns: nothing.
 */
static void step(void)
{
    ik64_net_status_t ns;
    const uint32_t now = (uint32_t)ik64_uptime_ms64();

    ik64_net_status(&ns);
    if ((g_phase != PHASE_LINK) && !ns.link_up) {
        drive_log_printf("MAIN: link lost, waiting for link\r\n");
        drive_server_set_ready(0);
        (void)backend_smb_unmount();
        enter(PHASE_LINK, now);
    }
    switch (g_phase) {
    case PHASE_LINK:
        if (ns.link_up) {
            enter((NETSHARE_IP_MODE == NETSHARE_IP_DHCP) ? PHASE_LEASE : PHASE_SMB, now);
        } else if (due(now, g_next_log)) {
            const uint32_t waited = now - g_phase_t0;

            drive_log_printf("MAIN: waiting for link (%lu s), sysregs eth_link %d\r\n",
                             (unsigned long)(waited / 1000u), ik64_sys_eth_link() ? 1 : 0);
            g_next_log = now + ((waited < MAIN_LINK_FAST_MS) ? MAIN_LINK_LOG_MS : MAIN_SLOW_LOG_MS);
        }
        break;
    case PHASE_LEASE:
        if (ns.lease) {
            enter(PHASE_SMB, now);
        } else if (due(now, g_next_log)) {
            const uint32_t waited = now - g_phase_t0;

            drive_log_printf("MAIN: link %u Mb/s %s, waiting for a DHCP lease (%lu s)\r\n",
                             (unsigned)ns.speed_mbps, ns.full_duplex ? "full" : "half",
                             (unsigned long)(waited / 1000u));
            g_next_log = now + ((waited < MAIN_LEASE_FAST_MS) ? MAIN_LINK_LOG_MS : MAIN_SLOW_LOG_MS);
        }
        break;
    case PHASE_SMB:
        if (due(now, g_next_log)) {
            g_smb_tries++;
            drive_log_printf("MAIN: SMB attempt %lu to %s share %s\r\n", (unsigned long)g_smb_tries,
                             NETSHARE_SERVER, NETSHARE_SHARE);
            if (smb_prove() == 0) {
                drive_log_printf("MAIN: SMB access proven, drive ready\r\n");
                drive_server_set_ready(1);
                enter(PHASE_DONE, (uint32_t)ik64_uptime_ms64());
                g_next_log = g_phase_t0 + MAIN_HEARTBEAT_MS;
            } else {
                g_next_log = (uint32_t)ik64_uptime_ms64() + MAIN_SMB_RETRY_MS;
                drive_log_printf("MAIN: SMB failed, retry in %lu s\r\n", (unsigned long)(MAIN_SMB_RETRY_MS / 1000u));
            }
        }
        break;
    case PHASE_DONE:
        if (!drive_server_ready()) {
            drive_log_printf("MAIN: share lost, remounting\r\n");
            (void)backend_smb_unmount();
            enter(PHASE_SMB, now);
            break;
        }
        if (due(now, g_next_log)) {
            drive_log_printf("HB: uptime %lu s, link %u Mb/s, %s " "%u.%u.%u.%u, rx %lu tx %lu frames\r\n",
                             (unsigned long)(now / 1000u), (unsigned)ns.speed_mbps,
                             ns.lease ? "lease" : "address", (unsigned)(ns.lease_ip >> 24),
                             (unsigned)((ns.lease_ip >> 16) & 0xFFu), (unsigned)((ns.lease_ip >> 8) & 0xFFu),
                             (unsigned)(ns.lease_ip & 0xFFu), (unsigned long)ns.rx_frames,
                             (unsigned long)ns.tx_frames);
            g_next_log = now + MAIN_HEARTBEAT_MS;
        }
        break;
    default:
        ik64_fatal("main: bad phase", (int32_t)g_phase);
    }
}

int main(void);

/* Address configuration of the network library, from netshare_config.h. */
static const ik64_net_config_t g_net_cfg = {
    .use_dhcp       = (NETSHARE_IP_MODE == NETSHARE_IP_DHCP),
    .static_addr    = NETSHARE_STATIC_ADDR,
    .static_netmask = NETSHARE_STATIC_NETMASK,
    .static_gateway = NETSHARE_STATIC_GATEWAY,
};

/*
 * main -- firmware entry, called by the BSP start-up.
 * Returns: never.
 */
int main(void)
{
    static const uint8_t mac[6] = IK64_NET_MAC_OCTETS;
    const uint32_t flags = ik64_sys_read(C64_SYS_BUILD_FLAGS_OFS);

    Xil_ICacheInvalidate();
    Xil_DCacheInvalidate();
    drive_log_init();
    drive_log_printf("\r\nIronKernel 64 core 1 (1541) firmware, built " __DATE__ " " __TIME__ "\r\n");
    drive_log_printf("Board: sysregs magic %s, build ID (git) %08lx%s, core index %lu, DDR3 %s\r\n",
                     (ik64_sys_read(C64_SYS_MAGIC_OFS) == C64_SYS_MAGIC_VALUE) ? "ok" : "BAD",
                     (unsigned long)ik64_sys_read(C64_SYS_BUILD_ID_OFS),
                     ((flags & IK64_SYS_FLAGS_DIRTY_MASK) != 0u) ? "-dirty" : "",
                     (unsigned long)((flags >> IK64_SYS_FLAGS_CORE_SHIFT) & IK64_SYS_FLAGS_CORE_MASK),
                     ik64_sys_ddr_calibrated() ? "calibrated" : "NOT calibrated");
    drive_log_printf("Node MAC %02x:%02x:%02x:%02x:%02x:%02x, I/D caches on (hardware), share %s\\%s\r\n",
                     mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], NETSHARE_SERVER, NETSHARE_SHARE);

    (void)backend_smb_init();
    (void)backend_ram_init();
    drive_server_init(&g_smb_ops, &g_ram_ops);
    if (ik64_net_init(&g_net_cfg) != 0) {
        drive_log_printf("MAIN: network bring-up incomplete, continuing (the monitor keeps retrying the link)\r\n");
    }
    enter(PHASE_LINK, (uint32_t)ik64_uptime_ms64());
    for (;;) {
        ik64_net_service();
        drive_server_poll();
        step();
    }
}

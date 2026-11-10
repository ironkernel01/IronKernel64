/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: ik64_netcore.h (fw_1541/lib/)
 * Role: the interface of libik64_netcore.a, the closed network library of core 1 ("1541" drive): the
 *   network service the main loop and the BSD-socket shim call. The library brings up the network core
 *   (fpga/netlist/ik64_net_core.md: MAC, PHY over MDIO, protocol wrapper with the node MAC address,
 *   DHCP leaf, CPU-path classifier and checksum offload, AXI DMA, lwIP netif), runs the link and lease
 *   monitor, and provides lwIP's time base and newlib's system clock. This header declares only what
 *   fw_1541 calls.
 *
 * Context: the main superloop only. ik64_net_service is the single place that advances lwIP; it is
 *   bounded (frame budget of the netif, one timer pass).
 *
 * What the library needs from core 1 (undefined symbols, defined in fw_1541/src): drive_log_write,
 *   drive_log_printf and ik64_fatal, plus lwIP 2.2.0 (NO_SYS = 1, compiled from the Vitis install with
 *   fw_1541/net/lwipopts.h) and the standalone BSP (AXI DMA and timer drivers, cache routines). It
 *   depends on the lwIP option set of fw_1541/net/lwipopts.h (struct pbuf and struct netif layouts,
 *   checksum and zero-copy settings): fw_1541/build.ps1 compares that file's SHA-256 with
 *   fw_1541/lib/ik64_netcore.lwipopts.sha256 and stops on a mismatch.
 *
 * Revision: 11-09-2026
 *   * 11-09-2026: initial version.
 */
#ifndef IK64_NETCORE_H
#define IK64_NETCORE_H

#include <stdint.h> /* uint8_t, uint32_t, uint64_t */

/* Node MAC address of core 1 (02 = locally administered unicast); the library writes it to the protocol
 * wrapper before DHCP or lwIP start. */
#define IK64_NET_MAC_OCTETS      { 0x02u, 0x1Cu, 0x64u, 0x00u, 0x00u, 0x01u }

/* Address configuration passed to ik64_net_init. The strings are dotted IPv4 and stay valid during the
 * call. In DHCP mode the static values are the fallback programmed into the protocol wrapper. */
typedef struct
{
    int         use_dhcp;           /* 1: acquire a lease on link-up; 0: static address only */
    const char *static_addr;        /* node address, e.g. "192.168.1.64" */
    const char *static_netmask;     /* e.g. "255.255.255.0" */
    const char *static_gateway;     /* e.g. "192.168.1.1" */
} ik64_net_config_t;

typedef struct
{
    int      link_up;       /* PHY link (resolved speed) */
    uint32_t speed_mbps;
    int      full_duplex;
    int      rx_ready;      /* MAC qualified RXC after the last link up */
    int      lease;         /* DHCP lease held */
    uint32_t lease_ip;      /* host order, first octet in [31:24] */
    uint32_t lease_mask;
    uint32_t lease_router;
    int      lwip_rc;       /* last lwIP netif start result */
    uint8_t  mac[6];        /* as programmed into the protocol wrapper */
    uint32_t rx_frames;     /* frames delivered to lwIP */
    uint32_t tx_frames;     /* frames sent by lwIP */
} ik64_net_status_t;

/* Milliseconds since ik64_net_init (64-bit). */
uint64_t ik64_uptime_ms64(void);

/* Bring up the whole path; prints one line per step to the core 1 log. 0 = ready, -1 = a core is absent. */
int  ik64_net_init(const ik64_net_config_t *cfg);
/* One bounded service step: DMA receive, lwIP timers, link/lease monitor (acts every 250 ms). */
void ik64_net_service(void);
/* Busy-wait ms while servicing the network (ik64_net_service in a loop). */
void ik64_net_delay_ms(uint32_t ms);
/* Snapshot of link, lease and counters. */
void ik64_net_status(ik64_net_status_t *out);

#endif /* IK64_NETCORE_H */

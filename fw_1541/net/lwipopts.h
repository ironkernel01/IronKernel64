/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: lwipopts.h (fw_1541/net/)
 * Role: the one configuration of lwIP 2.2.0 on core 1 ("1541" drive). lwIP is
 *   compiled in place from the AMD install
 *   (Vitis/data/embeddedsw/ThirdParty/sw_services/lwip220_v1_4/src/lwip-2.2.0),
 *   never copied.
 *
 * System: NO_SYS = 1, raw API, no RTOS: everything runs in the main superloop
 *   (src/main.c), including the BSD-socket shim (net/ik64_sock.c) that gives
 *   libsmb2 its TCP socket on top of the raw API. No interrupt ever calls lwIP,
 *   so SYS_LIGHTWEIGHT_PROT is 0.
 * Base: RTLNet's microblaze/firmware/src/lwip/lwipopts.h (commit f8435ad),
 *   which carries the measured 95 Mbit/s CPU path on the same DMA and BRAM
 *   layout. Differences, each for core 1's needs:
 *   - no DNS and no UDP (the server is a dotted IP; DHCP runs in RTL);
 *   - one TCP connection (libsmb2) instead of echo + iperf: smaller PCB and
 *     segment counts, a 16 x MSS window (the wrapper's 32 KiB CPU receive FIFO
 *     is the bound: one window fits it);
 *   - keepalive off (the raw-API shim does not expose SO_KEEPALIVE).
 *   IK64_DEVIATION 9 (fw_1541/DEVIATIONS.md).
 *
 * Address: the RTL DHCP leaf owns the node address; InitLWIP (ik64_lwip.c)
 *   copies it into the netif, so LWIP_DHCP stays 0 here.
 *
 * Memory (all .bss in core 1's DDR3 partition; the DMA buffers alone sit in the
 *   network BRAM, rtlnet_lwip_netif.c):
 *   MEM_SIZE 64 KiB: tcp_write copies of outgoing SMB requests (small: the
 *     drive is read-only) and headers.
 *   PBUF_POOL_SIZE 32 x 1536 B: pool pbufs for non-zero-copy paths; the
 *     received frames themselves travel as custom pbufs (zero-copy receive).
 *     Drift rule: PBUF_POOL_SIZE >= (TCP_WND / TCP_MSS) + 16.
 *
 * Headers hold contracts; per-function commentary lives in the .c files.
 */
#ifndef LWIPOPTS_H
#define LWIPOPTS_H

/* Byte order of MicroBlaze V (RV32, little-endian). */
#define PROCESSOR_LITTLE_ENDIAN

/* System: bare metal, raw API, timers from sys_now() in the main loop. */
#define NO_SYS                          1
#define NO_SYS_NO_TIMERS                0
#define LWIP_TIMERS                     1
#define SYS_LIGHTWEIGHT_PROT            0
#define LWIP_NETCONN                    0
#define LWIP_SOCKET                     0
#define LWIP_NETIF_API                  0
#define LWIP_TCPIP_CORE_LOCKING         0

/* Memory: lwIP's own static heap and pools; never the C library heap. */
#define MEM_LIBC_MALLOC                 0
#define MEMP_MEM_MALLOC                 0
#define MEM_ALIGNMENT                   4
#define MEM_SIZE                        (64 * 1024)
#define MEMP_NUM_PBUF                   48
#define MEMP_NUM_RAW_PCB                1
#define MEMP_NUM_UDP_PCB                1
#define MEMP_NUM_TCP_PCB                4
#define MEMP_NUM_TCP_PCB_LISTEN         1
#define MEMP_NUM_TCP_SEG                64
#define MEMP_NUM_REASSDATA              2
#define MEMP_NUM_FRAG_PBUF              4
#define MEMP_NUM_ARP_QUEUE              8
#define MEMP_NUM_SYS_TIMEOUT            (LWIP_NUM_SYS_TIMEOUT_INTERNAL + 2)
#define PBUF_POOL_SIZE                  32
#define PBUF_POOL_BUFSIZE               1536
#define PBUF_LINK_HLEN                  14
#define ETH_PAD_SIZE                    0

/* Protocols: IPv4, ARP, TCP, ICMP (the RTL leaf answers ping; lwIP's copy is the fallback). */
#define LWIP_IPV4                       1
#define LWIP_IPV6                       0
#define LWIP_ARP                        1
#define LWIP_ETHERNET                   1
#define ARP_TABLE_SIZE                  10
#define ARP_QUEUEING                    1
#define ETHARP_SUPPORT_STATIC_ENTRIES   0
#define LWIP_DHCP                       0
#define LWIP_AUTOIP                     0
#define LWIP_ACD                        0
#define LWIP_IGMP                       0
#define LWIP_DNS                        0
#define LWIP_ICMP                       1
#define LWIP_RAW                        0
#define LWIP_UDP                        0
#define LWIP_TCP                        1
#define IP_FORWARD                      0
#define IP_OPTIONS_ALLOWED              0
#define IP_REASSEMBLY                   0
#define IP_FRAG                         1
#define IP_DEFAULT_TTL                  64

/* TCP: SMB2 READ replies arrive as one stream; a 10 x MSS window keeps a
 * 100 Mbit/s LAN busy. Rule: TCP_WND + one 1518-byte frame <= the gateware's
 * CPU_RX_FIFO_KB * 1024 (c64_top u_protocol, 16 KiB: 14,600 + 1518 = 16,118).
 * The shim's receive ring (IK64_SOCK_RX_BYTES) must be at least TCP_WND. */
#define TCP_MSS                         1460
#define TCP_WND                         (10 * TCP_MSS)
#define TCP_SND_BUF                     (8 * TCP_MSS)
#define TCP_SND_QUEUELEN                ((4 * (TCP_SND_BUF) + (TCP_MSS - 1)) / (TCP_MSS))
#define TCP_QUEUE_OOSEQ                 1
#define TCP_OVERSIZE                    TCP_MSS
#define LWIP_TCP_KEEPALIVE              0
#define LWIP_LISTEN_BACKLOG             0
#define LWIP_TCP_SACK_OUT               0

/* Checksums (software unless rtlnet_offload_apply clears the per-netif flags). */
#define CHECKSUM_GEN_IP                 1
#define CHECKSUM_GEN_UDP                1
#define CHECKSUM_GEN_TCP                1
#define CHECKSUM_GEN_ICMP               1
#define CHECKSUM_CHECK_IP               1
#define CHECKSUM_CHECK_UDP              1
#define CHECKSUM_CHECK_TCP              1
#define CHECKSUM_CHECK_ICMP             1
#define LWIP_CHECKSUM_ON_COPY           0
#define LWIP_CHKSUM_ALGORITHM           3

/* Netif. */
#define LWIP_NETIF_STATUS_CALLBACK      0
#define LWIP_NETIF_LINK_CALLBACK        0
#define LWIP_NETIF_HOSTNAME             0
#define LWIP_SINGLE_NETIF               1
#define LWIP_NETIF_TX_SINGLE_PBUF       0

/* Statistics (the heartbeat and the netif read them). */
#define LWIP_STATS                      1
#define LWIP_STATS_DISPLAY              0
#define LWIP_STATS_LARGE                1
#define LINK_STATS                      1
#define ETHARP_STATS                    1
#define IP_STATS                        1
#define TCP_STATS                       1
#define MEM_STATS                       1
#define MEMP_STATS                      1
#define UDP_STATS                       0
#define ICMP_STATS                      0
#define IPFRAG_STATS                    0
#define SYS_STATS                       0

/* Checksum offload and zero copy (rtlnet_offload.c, rtlnet_lwip_netif.c): as RTLNet's default. */
#define LWIP_CHECKSUM_CTRL_PER_NETIF    1
#define LWIP_SUPPORT_CUSTOM_PBUF        1
#ifndef RTLNET_NETIF_ZERO_COPY_RX
#define RTLNET_NETIF_ZERO_COPY_RX       1
#endif
#ifndef RTLNET_NETIF_ZERO_COPY_TX
#define RTLNET_NETIF_ZERO_COPY_TX       0
#endif

/* LWIP_DEBUG stays undefined (lwIP tests it with #ifdef). */

#endif /* LWIPOPTS_H */

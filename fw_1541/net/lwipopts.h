/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: lwipopts.h
 * Role: the one configuration of lwIP 2.2.0 on core 1 ("1541" drive). lwIP is
 *   compiled in place from the AMD install
 *   (Vitis/data/embeddedsw/ThirdParty/sw_services/lwip220_v1_4/src/lwip-2.2.0),
 *   never copied.
 *
 * System: NO_SYS = 0 under FreeRTOS. The tcpip thread owns the stack; libsmb2
 *   reaches it through the BSD socket API (socket, connect, poll, readv,
 *   writev, getaddrinfo, setsockopt/getsockopt, fcntl O_NONBLOCK), which is
 *   what its PICO_PLATFORM (Pico W, FreeRTOS + lwIP) path calls.
 *   Peer configuration: libsmb2's include/picow/lwipopts.h and
 *   lwipopts_examples_common.h; RTLNet's NO_SYS = 1 lwipopts.h for the DMA
 *   netif sizes (microblaze/firmware/src/lwip/lwipopts.h).
 *
 * Address: the RTL DHCP leaf owns the node address (c64demo.md Phase 4); the
 *   netif glue copies it into lwIP, so LWIP_DHCP stays 0 here.
 *
 * Memory (core 1 runs from its 64 MiB DDR3 partition, c64_platform.h, so the
 *   sizes favour throughput over footprint):
 *   MEM_SIZE 64 KiB: outgoing SMB requests are small (< 1 KiB) except
 *     WRITE, which the read-only drive does not issue; headroom for socket
 *     send copies (lwip_send copies into the heap, TCP_SND_BUF bounds it).
 *   PBUF_POOL_SIZE 48 x 1536 B: TCP_WND / TCP_MSS = 16 segments for the one
 *     SMB connection, x2 for the out-of-sequence queue, + 16 margin.
 *     Drift rule: PBUF_POOL_SIZE >= 2 x (TCP_WND / TCP_MSS) + 16. A smaller
 *     pool makes the netif drop frames (rx_no_pbuf) and TCP retransmit,
 *     which shows as low throughput, not as an error.
 *   MEMP_NUM_NETCONN 4: one SMB socket, one being torn down during a
 *     reconnect, two spare.
 * Headers hold contracts; per-function commentary lives in the .c files.
 */
#ifndef LWIPOPTS_H
#define LWIPOPTS_H

/* newlib's file-status flags first: lwip/sockets.h defines F_GETFL, F_SETFL and
 * O_NONBLOCK only when they are missing, so including <fcntl.h> here gives lwIP
 * (sockets.c) and libsmb2 (socket.c, libsmb2.c) one O_NONBLOCK value. It also
 * keeps newlib's fcntl() prototype ahead of lwIP's fcntl() macro. Drift
 * failure mode and the compile-time check: fw_1541/net/smb2_port.c.
 * IK64_DEVIATION 3 (fw_1541/DEVIATIONS.md). */
#include <fcntl.h> /* O_NONBLOCK, F_GETFL, F_SETFL */

/* Byte order of MicroBlaze V (RV32, little-endian; Xilinx port cpu.h). */
#define PROCESSOR_LITTLE_ENDIAN

/* System: FreeRTOS, tcpip thread, sockets. */
#define NO_SYS                          0
#define LWIP_TIMERS                     1
#define SYS_LIGHTWEIGHT_PROT            1
#define LWIP_NETCONN                    1   /* sockets are built on netconn */
#define LWIP_SOCKET                     1
#define LWIP_COMPAT_SOCKETS             1   /* socket(), connect(), ... names */
#define LWIP_POSIX_SOCKETS_IO_NAMES     1   /* close(), readv(), writev(), fcntl() names */
#define LWIP_SOCKET_POLL                1   /* poll(): libsmb2's sync loop */
#define LWIP_SOCKET_SELECT              1
#define LWIP_SO_RCVTIMEO                1
#define LWIP_SO_SNDTIMEO                1
#define LWIP_SO_RCVBUF                  1
#define LWIP_TIMEVAL_PRIVATE            0   /* struct timeval from newlib <sys/time.h> */
#define LWIP_ERRNO_STDINCLUDE           1   /* newlib <errno.h>: the values libsmb2 compares */
#define LWIP_NETIF_API                  0
#define LWIP_TCPIP_CORE_LOCKING         1
#define LWIP_TCPIP_CORE_LOCKING_INPUT   0
#define LWIP_NETCONN_SEM_PER_THREAD     0
#define LWIP_MPU_COMPATIBLE             0

/* Threads (stack depths are in words: configSTACK_DEPTH_TYPE of the RISC-V port). */
#define TCPIP_THREAD_NAME               "tcpip"
#define TCPIP_THREAD_STACKSIZE          2048
#define TCPIP_THREAD_PRIO               4   /* above the drive task (FreeRTOSConfig.h) */
#define TCPIP_MBOX_SIZE                 32
#define DEFAULT_THREAD_STACKSIZE        1024
#define DEFAULT_RAW_RECVMBOX_SIZE       8
#define DEFAULT_UDP_RECVMBOX_SIZE       8
#define DEFAULT_TCP_RECVMBOX_SIZE       32
#define DEFAULT_ACCEPTMBOX_SIZE         4

/* Memory: lwIP's own static heap and pools; never the C library heap. */
#define MEM_LIBC_MALLOC                 0
#define MEMP_MEM_MALLOC                 0
#define MEM_ALIGNMENT                   4
#define MEM_SIZE                        (64 * 1024)
#define MEMP_NUM_PBUF                   32
#define MEMP_NUM_RAW_PCB                1
#define MEMP_NUM_UDP_PCB                4
#define MEMP_NUM_TCP_PCB                4
#define MEMP_NUM_TCP_PCB_LISTEN         1
#define MEMP_NUM_TCP_SEG                64
#define MEMP_NUM_NETBUF                 8
#define MEMP_NUM_NETCONN                4
#define MEMP_NUM_TCPIP_MSG_API          8
#define MEMP_NUM_TCPIP_MSG_INPKT        32
#define MEMP_NUM_SYS_TIMEOUT            (LWIP_NUM_SYS_TIMEOUT_INTERNAL + 2)
#define PBUF_POOL_SIZE                  48
#define PBUF_POOL_BUFSIZE               1536
#define PBUF_LINK_HLEN                  14
#define ETH_PAD_SIZE                    0

/* Protocols: IPv4 TCP to the NAS; DNS only for getaddrinfo() (the server is
 * given as a dotted IP, which lwIP resolves without a query). */
#define LWIP_IPV4                       1
#define LWIP_IPV6                       0
#define LWIP_ARP                        1
#define LWIP_ETHERNET                   1
#define ARP_TABLE_SIZE                  10
#define ARP_QUEUEING                    1
#define LWIP_DHCP                       0
#define LWIP_AUTOIP                     0
#define LWIP_ACD                        0
#define LWIP_IGMP                       0
#define LWIP_DNS                        1
#define DNS_TABLE_SIZE                  2
#define LWIP_ICMP                       1
#define LWIP_RAW                        0
#define LWIP_UDP                        1   /* DNS */
#define LWIP_TCP                        1
#define IP_FORWARD                      0
#define IP_REASSEMBLY                   0
#define IP_FRAG                         1
#define IP_DEFAULT_TTL                  64

/* TCP: SMB2 READ responses arrive as one stream of up to the negotiated read
 * size; a 16 x MSS window keeps a 100 Mbit/s LAN busy. */
#define TCP_MSS                         1460
#define TCP_WND                         (16 * TCP_MSS)
#define TCP_SND_BUF                     (8 * TCP_MSS)
#define TCP_SND_QUEUELEN                ((4 * (TCP_SND_BUF) + (TCP_MSS - 1)) / (TCP_MSS))
#define TCP_QUEUE_OOSEQ                 1
#define LWIP_TCP_KEEPALIVE              1   /* libsmb2 sets SO_KEEPALIVE / TCP_KEEP* */
#define LWIP_LISTEN_BACKLOG             0

/* Checksums in software (the CPU path carries frames without offload, as RTLNet). */
#define LWIP_CHKSUM_ALGORITHM           3

/* Netif. */
#define LWIP_NETIF_STATUS_CALLBACK      1
#define LWIP_NETIF_LINK_CALLBACK        1   /* cable pull -> 74,DRIVE NOT READY */
#define LWIP_SINGLE_NETIF               1

/* Statistics and debug. */
#define LWIP_STATS                      1
#define LWIP_STATS_DISPLAY              0
#define LWIP_DEBUG                      0

#endif /* LWIPOPTS_H */

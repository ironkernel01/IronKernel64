/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: ik64_sock.h
 * Role: the BSD-socket surface that libsmb2's client path uses on core 1,
 *   implemented by ik64_sock.c over the lwIP raw TCP API (NO_SYS = 1).
 *   Bare-metal newlib ships no <sys/socket.h>, <netdb.h>, <netinet/in.h>,
 *   <arpa/inet.h> or <poll.h>, so this header declares the types, constants
 *   and prototypes libsmb2 expects, with the BSD names. The build
 *   force-includes it (-include) into every libsmb2 translation unit together
 *   with fw_1541/net/smb2cfg_nosys/config.h; no libsmb2 file is edited
 *   (IK64_DEVIATION 7, fw_1541/DEVIATIONS.md). ik64_sock.c includes it too.
 *
 * What is provided (exactly the calls of libsmb2's client path, NETWORK_SPIKE.md
 *   section 2): socket, fcntl (F_GETFL/F_SETFL), setsockopt, getsockopt
 *   (SO_ERROR), connect (non-blocking), poll, readv, writev, close,
 *   getaddrinfo/freeaddrinfo (dotted IPv4 only), plus getlogin_r, be64toh and
 *   getpid for libsmb2's platform expectations. newlib's time() runs on
 *   _gettimeofday (ik64_platform.c).
 *
 * Limits (by design, one SMB session): ONE TCP socket at a time, always
 *   non-blocking, descriptor IK64_SOCK_FD; receive ring IK64_SOCK_RX_BYTES; a
 *   second socket() fails with ENFILE. server-side calls (bind, listen,
 *   accept, select) are declared so libsmb2's server code compiles; they are
 *   not implemented and are discarded by --gc-sections (a link error would
 *   show if the client path ever referenced them).
 * poll() runs ik64_net_service() steps (netif receive, lwIP timers, link
 *   monitor) until a descriptor is ready or the timeout expires: libsmb2's
 *   synchronous loop therefore drives the whole network from the superloop.
 * Context: the main superloop only.
 */
#ifndef IK64_SOCK_H
#define IK64_SOCK_H

#include <errno.h>        /* EINPROGRESS, EAGAIN, ... newlib values */
#include <fcntl.h>        /* O_NONBLOCK, F_GETFL, F_SETFL (newlib values) */
#include <stddef.h>       /* size_t */
#include <stdint.h>       /* uint16_t, uint32_t */
#include <sys/select.h>   /* fd_set, FD_* (server code of libsmb2) */
#include <sys/time.h>     /* struct timeval */
#include <sys/types.h>    /* ssize_t */
#include <time.h>         /* time_t */

/* Descriptor of the one socket, and the receive ring behind it. The ring must hold a whole TCP window
 * (lwipopts.h TCP_WND = 23,360), because the window is only re-opened as bytes are consumed. */
#define IK64_SOCK_FD             (3)
#define IK64_SOCK_RX_BYTES       (32768u)
/* poll() with a negative timeout (wait forever) is cut at this many milliseconds. */
#define IK64_SOCK_POLL_MAX_MS    (60000)

/* Types. */
#ifndef IK64_SOCKLEN_T_DEFINED
#define IK64_SOCKLEN_T_DEFINED
typedef unsigned int socklen_t;
#endif
typedef unsigned int nfds_t;
typedef unsigned short sa_family_t;

struct iovec
{
    void   *iov_base;
    size_t  iov_len;
};

struct in_addr
{
    uint32_t s_addr;                 /* network byte order */
};

struct sockaddr
{
    sa_family_t sa_family;
    char        sa_data[14];
};

struct sockaddr_in
{
    sa_family_t     sin_family;
    uint16_t        sin_port;        /* network byte order */
    struct in_addr  sin_addr;
    char            sin_zero[8];
};

struct sockaddr_storage
{
    sa_family_t ss_family;
    char        ss_pad[126];
};

struct addrinfo
{
    int              ai_flags;
    int              ai_family;
    int              ai_socktype;
    int              ai_protocol;
    socklen_t        ai_addrlen;
    struct sockaddr *ai_addr;
    char            *ai_canonname;
    struct addrinfo *ai_next;
};

struct pollfd
{
    int   fd;
    short events;
    short revents;
};

struct linger
{
    int l_onoff;
    int l_linger;
};

/* Constants (BSD / lwIP values). */
#define AF_INET        (2)
#define SOCK_STREAM    (1)
#define IPPROTO_TCP    (6)
#define SOL_SOCKET     (0xfff)
#define SOL_TCP        (6)
#define TCP_NODELAY    (0x01)
#define SO_REUSEADDR   (0x0004)
#define SO_KEEPALIVE   (0x0008)
#define SO_LINGER      (0x0080)
#define SO_ERROR       (0x1007)
#define POLLIN         (0x0001)
#define POLLPRI        (0x0002)
#define POLLOUT        (0x0004)
#define POLLERR        (0x0008)
#define POLLHUP        (0x0010)
#define POLLNVAL       (0x0020)
#define INADDR_ANY     ((uint32_t)0)
#define EAI_AGAIN      (2)
#define EAI_FAIL       (4)
#define EAI_MEMORY     (6)
#define EAI_NONAME     (8)
#define EAI_SERVICE    (9)

#ifndef htons
#define htons(x)       ((uint16_t)__builtin_bswap16((uint16_t)(x)))
#define ntohs(x)       ((uint16_t)__builtin_bswap16((uint16_t)(x)))
#define htonl(x)       ((uint32_t)__builtin_bswap32((uint32_t)(x)))
#define ntohl(x)       ((uint32_t)__builtin_bswap32((uint32_t)(x)))
#endif

/* Client path (implemented in ik64_sock.c). */
int socket(int domain, int type, int protocol);
int connect(int fd, const struct sockaddr *addr, socklen_t len);
int getsockopt(int fd, int level, int optname, void *optval, socklen_t *optlen);
int setsockopt(int fd, int level, int optname, const void *optval, socklen_t optlen);
int fcntl(int fd, int cmd, ...);
int poll(struct pollfd *fds, nfds_t nfds, int timeout_ms);
ssize_t readv(int fd, const struct iovec *iov, int iovcnt);
ssize_t writev(int fd, const struct iovec *iov, int iovcnt);
int close(int fd);
int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res);
void freeaddrinfo(struct addrinfo *res);

/* Platform functions libsmb2 expects (compat.h declares the first two for PICO_PLATFORM only). */
long long int be64toh(long long int x);
int getlogin_r(char *buf, size_t size);

/* Server side: declared so libsmb2's server code compiles; never linked. */
int bind(int fd, const struct sockaddr *addr, socklen_t len);
int listen(int fd, int backlog);
int accept(int fd, struct sockaddr *addr, socklen_t *len);
int select(int nfds, fd_set *rd, fd_set *wr, fd_set *ex, struct timeval *tv);
int gethostname(char *name, size_t len);

#endif /* IK64_SOCK_H */

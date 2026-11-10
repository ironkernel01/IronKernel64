/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: ik64_sock.c
 * Role: BSD-socket shim for libsmb2 over the lwIP raw TCP API (contract and
 *   limits: ik64_sock.h). One non-blocking TCP socket, descriptor
 *   IK64_SOCK_FD. The function names and signatures are fixed by libsmb2's
 *   client path (vendor-visible), so they carry no module prefix.
 *   IK64_DEVIATION 7 (fw_1541/DEVIATIONS.md).
 *
 * State machine (g_s.state):
 *   FREE -> socket() -> OPEN -> connect() -> CONNECTING -> (on_connected) ->
 *   CONNECTED; (on_err) -> ERRORED from CONNECTING or CONNECTED; close() -> FREE.
 *   lwIP callbacks run only from inside ik64_net_service (called by poll), so
 *   they never interleave with a shim call.
 * Receive: on_recv copies the pbuf chain into a ring (free-running head/tail
 *   counters) and frees it. The TCP window is re-opened with tcp_recved only
 *   for the bytes readv hands to libsmb2, so the peer cannot send more than
 *   the ring holds (TCP_WND <= IK64_SOCK_RX_BYTES, checked below).
 * Send: writev copies as much as tcp_sndbuf allows with tcp_write
 *   (TCP_WRITE_FLAG_COPY) and calls tcp_output; a full send buffer is EAGAIN,
 *   which libsmb2 retries on the next POLLOUT.
 * Remote close: a FIN (on_recv with p == NULL) sets peer_closed; poll reports
 *   POLLIN so libsmb2 calls readv, which returns 0 once the ring is drained.
 *   POLLHUP is never reported (libsmb2 would drop unread data).
 * Errors: on_err stores the errno of the lwIP error in so_error; poll reports
 *   POLLERR (+ requested bits) and getsockopt(SO_ERROR) returns it.
 * Bounds: poll() with timeout t spins ik64_net_service until ready or t ms;
 *   t < 0 means IK64_SOCK_POLL_MAX_MS. close() never waits.
 */
#include "lwip/err.h"
#include "lwip/ip4_addr.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"

#include "ik64_sock.h"

#include "ik64_netcore.h"  /* ik64_net_service, ik64_uptime_ms64 */

#include <stdarg.h>        /* va_list for fcntl */
#include <stdlib.h>        /* strtoul */
#include <string.h>        /* memcpy, memset */

_Static_assert(IK64_SOCK_RX_BYTES >= TCP_WND, "receive ring smaller than the TCP window");
_Static_assert(IK64_SOCK_FD >= 0, "descriptor must be valid for libsmb2 (SMB2_VALID_SOCKET)");

typedef enum
{
    SOCK_FREE = 0,
    SOCK_OPEN,
    SOCK_CONNECTING,
    SOCK_CONNECTED,
    SOCK_ERRORED
} sock_state_t;

/* getaddrinfo results live in static storage; libsmb2 holds one list per context and frees it before the next. */
#define IK64_SOCK_AI_SLOTS       (2u)

typedef struct
{
    sock_state_t     state;
    struct tcp_pcb  *pcb;
    int              flags;          /* fcntl F_SETFL value (O_NONBLOCK) */
    int              so_error;       /* errno of the last asynchronous failure */
    int              nodelay;
    int              peer_closed;
    uint32_t         rx_head;        /* free-running write counter */
    uint32_t         rx_tail;        /* free-running read counter */
    uint8_t          rx[IK64_SOCK_RX_BYTES];
} sock_t;

typedef struct
{
    int                used;
    struct addrinfo    ai;
    struct sockaddr_in sin;
} ai_slot_t;

static sock_t    g_s;
static ai_slot_t g_ai[IK64_SOCK_AI_SLOTS];

/*
 * err_to_errno -- map an lwIP err_t to the errno libsmb2 compares against.
 * Returns: a positive errno value.
 */
static int err_to_errno(err_t e)
{
    switch (e) {
    case ERR_MEM:
    case ERR_BUF:      return ENOMEM;
    case ERR_TIMEOUT:  return ETIMEDOUT;
    case ERR_RTE:      return EHOSTUNREACH;
    case ERR_INPROGRESS: return EINPROGRESS;
    case ERR_VAL:
    case ERR_ARG:      return EINVAL;
    case ERR_USE:      return EADDRINUSE;
    case ERR_ISCONN:   return EISCONN;
    case ERR_ABRT:     return ECONNABORTED;
    case ERR_RST:      return ECONNRESET;
    case ERR_CLSD:
    case ERR_CONN:     return ENOTCONN;
    default:           return EIO;
    }
}

/*
 * rx_used -- bytes waiting in the receive ring.
 * Returns: head - tail.
 */
static uint32_t rx_used(void)
{
    return g_s.rx_head - g_s.rx_tail;
}

/*
 * on_connected -- lwIP callback: the three-way handshake finished.
 * Returns: ERR_OK.
 */
static err_t on_connected(void *arg, struct tcp_pcb *pcb, err_t err)
{
    (void)arg;
    if (err == ERR_OK) {
        g_s.state = SOCK_CONNECTED;
        g_s.so_error = 0;
        if (g_s.nodelay) {
            tcp_nagle_disable(pcb);
        }
    }
    return ERR_OK;
}

/*
 * on_recv -- lwIP callback: data (p) or the remote FIN (p == NULL).
 * Steps:
 *   1. FIN: remember it; the pcb stays until close().
 *   2. Error: free the pbuf, pass the error on.
 *   3. Copy the chain into the ring (two segments at the wrap) and free it.
 *      A chain that does not fit (cannot happen within TCP_WND) is refused
 *      with ERR_MEM, which makes lwIP keep it and redeliver.
 * Returns: ERR_OK, or ERR_MEM / the lwIP error.
 */
static err_t on_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    uint32_t len;
    uint32_t pos;
    uint32_t first;

    (void)arg;
    (void)pcb;
    if (p == NULL) {
        g_s.peer_closed = 1;
        return ERR_OK;
    }
    if (err != ERR_OK) {
        pbuf_free(p);
        return err;
    }
    len = p->tot_len;
    if (len > (IK64_SOCK_RX_BYTES - rx_used())) {
        return ERR_MEM;
    }
    pos = g_s.rx_head % IK64_SOCK_RX_BYTES;
    first = IK64_SOCK_RX_BYTES - pos;
    if (first > len) {
        first = len;
    }
    (void)pbuf_copy_partial(p, &g_s.rx[pos], (u16_t)first, 0u);
    if (first < len) {
        (void)pbuf_copy_partial(p, &g_s.rx[0], (u16_t)(len - first), (u16_t)first);
    }
    g_s.rx_head += len;
    pbuf_free(p);
    return ERR_OK;
}

/*
 * on_err -- lwIP callback: the connection failed or was reset; the pcb is
 *   already freed by lwIP.
 * Steps:
 *   1. Drop the pcb pointer, record the errno (a reset while connecting is
 *      ECONNREFUSED), enter ERRORED.
 * Returns: nothing.
 */
static void on_err(void *arg, err_t err)
{
    (void)arg;
    g_s.pcb = NULL;
    if (g_s.state == SOCK_FREE) {
        return;
    }
    g_s.so_error = ((g_s.state == SOCK_CONNECTING) && (err == ERR_RST)) ? ECONNREFUSED : err_to_errno(err);
    g_s.state = SOCK_ERRORED;
}

/*
 * socket -- create the one TCP socket.
 * Returns: IK64_SOCK_FD, or -1 (EAFNOSUPPORT, ENFILE, ENOMEM).
 */
int socket(int domain, int type, int protocol)
{
    (void)protocol;
    if ((domain != AF_INET) || (type != SOCK_STREAM)) {
        errno = EAFNOSUPPORT;
        return -1;
    }
    if (g_s.state != SOCK_FREE) {
        errno = ENFILE;
        return -1;
    }
    memset(&g_s, 0, sizeof(g_s));
    g_s.pcb = tcp_new();
    if (g_s.pcb == NULL) {
        errno = ENOMEM;
        return -1;
    }
    tcp_arg(g_s.pcb, NULL);
    tcp_err(g_s.pcb, on_err);
    tcp_recv(g_s.pcb, on_recv);
    g_s.state = SOCK_OPEN;
    return IK64_SOCK_FD;
}

/*
 * fcntl -- F_GETFL / F_SETFL only (the shim is always non-blocking; the flags
 *   are kept so libsmb2's read-modify-write works).
 * Returns: the flags (F_GETFL), 0 (F_SETFL), or -1 (EBADF, EINVAL).
 */
int fcntl(int fd, int cmd, ...)
{
    va_list ap;
    int arg = 0;

    if ((fd != IK64_SOCK_FD) || (g_s.state == SOCK_FREE)) {
        errno = EBADF;
        return -1;
    }
    if (cmd == F_GETFL) {
        return g_s.flags | O_NONBLOCK;
    }
    if (cmd == F_SETFL) {
        va_start(ap, cmd);
        arg = va_arg(ap, int);
        va_end(ap);
        g_s.flags = arg;
        return 0;
    }
    errno = EINVAL;
    return -1;
}

/*
 * setsockopt -- TCP_NODELAY is applied; every other option libsmb2 sets
 *   (SO_REUSEADDR, SO_LINGER, SO_KEEPALIVE) is accepted and ignored.
 * Returns: 0, or -1 (EBADF).
 */
int setsockopt(int fd, int level, int optname, const void *optval, socklen_t optlen)
{
    if ((fd != IK64_SOCK_FD) || (g_s.state == SOCK_FREE)) {
        errno = EBADF;
        return -1;
    }
    if ((level == SOL_TCP) && (optname == TCP_NODELAY) && (optval != NULL) && (optlen >= sizeof(int))) {
        g_s.nodelay = (*(const int *)optval != 0);
        if ((g_s.pcb != NULL) && g_s.nodelay) {
            tcp_nagle_disable(g_s.pcb);
        }
    }
    return 0;
}

/*
 * getsockopt -- SO_ERROR only.
 * Returns: 0 with the stored errno (0 = connected or no error), or -1 (EBADF, ENOPROTOOPT).
 */
int getsockopt(int fd, int level, int optname, void *optval, socklen_t *optlen)
{
    if ((fd != IK64_SOCK_FD) || (g_s.state == SOCK_FREE)) {
        errno = EBADF;
        return -1;
    }
    if ((level != SOL_SOCKET) || (optname != SO_ERROR) || (optval == NULL) || (optlen == NULL) ||
        (*optlen < sizeof(int))) {
        errno = ENOPROTOOPT;
        return -1;
    }
    *(int *)optval = g_s.so_error;
    *optlen = sizeof(int);
    return 0;
}

/*
 * connect -- start the TCP handshake (non-blocking).
 * Steps:
 *   1. Only an AF_INET address on an OPEN socket.
 *   2. tcp_connect with the BSD sockaddr_in (network byte order fields).
 *   3. Success of the call means "in progress": CONNECTING, errno EINPROGRESS,
 *      return -1, as a POSIX non-blocking connect does; poll reports POLLOUT
 *      when on_connected ran.
 * Returns: -1 always (EINPROGRESS on a started connect, else the failure's errno).
 */
int connect(int fd, const struct sockaddr *addr, socklen_t len)
{
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    ip4_addr_t ip;
    err_t e;

    if ((fd != IK64_SOCK_FD) || (g_s.state != SOCK_OPEN)) {
        errno = (g_s.state == SOCK_FREE) ? EBADF : EISCONN;
        return -1;
    }
    if ((addr == NULL) || (len < sizeof(struct sockaddr_in)) || (sin->sin_family != AF_INET)) {
        errno = EAFNOSUPPORT;
        return -1;
    }
    ip4_addr_set_u32(&ip, sin->sin_addr.s_addr);
    g_s.state = SOCK_CONNECTING;
    g_s.so_error = 0;
    e = tcp_connect(g_s.pcb, &ip, ntohs(sin->sin_port), on_connected);
    if (e != ERR_OK) {
        g_s.state = SOCK_OPEN;
        errno = err_to_errno(e);
        return -1;
    }
    errno = EINPROGRESS;
    return -1;
}

/*
 * revents_now -- ready bits of the socket for the requested events.
 * Returns: POLL* bits (POLLNVAL for no socket).
 */
static short revents_now(short events)
{
    short r = 0;

    switch (g_s.state) {
    case SOCK_CONNECTED:
        if (((events & POLLIN) != 0) && ((rx_used() != 0u) || (g_s.peer_closed != 0))) {
            r |= POLLIN;
        }
        if (((events & POLLOUT) != 0) && (tcp_sndbuf(g_s.pcb) > 0u)) {
            r |= POLLOUT;
        }
        break;
    case SOCK_ERRORED:
        r = (short)(POLLERR | (events & (POLLIN | POLLOUT)));
        break;
    case SOCK_FREE:
        r = POLLNVAL;
        break;
    default:
        break;
    }
    return r;
}

/*
 * poll -- readiness of the one socket, driving the network while it waits.
 * Steps:
 *   1. Loop: ik64_net_service (frames in, lwIP timers, link monitor), compute
 *      the ready bits; return as soon as the socket is ready.
 *   2. Otherwise return 0 when the timeout has elapsed (one pass for 0).
 * Returns: number of ready descriptors (0 or 1; an entry for another fd gets POLLNVAL and counts).
 */
int poll(struct pollfd *fds, nfds_t nfds, int timeout_ms)
{
    const uint32_t t0 = (uint32_t)ik64_uptime_ms64();
    const uint32_t span = (timeout_ms < 0) ? (uint32_t)IK64_SOCK_POLL_MAX_MS : (uint32_t)timeout_ms;
    nfds_t i;
    int ready;

    for (;;) {
        ik64_net_service();
        ready = 0;
        for (i = 0u; i < nfds; i++) {
            fds[i].revents = (fds[i].fd == IK64_SOCK_FD) ? revents_now(fds[i].events) : (short)POLLNVAL;
            if (fds[i].revents != 0) {
                ready++;
            }
        }
        if ((ready != 0) || ((uint32_t)((uint32_t)ik64_uptime_ms64() - t0) >= span)) {
            return ready;
        }
    }
}

/*
 * readv -- copy ring bytes into the caller's vectors and re-open the window.
 * Returns: bytes copied; 0 after the peer's FIN once the ring is empty; -1
 *   with EAGAIN when nothing is available, so_error after an error, EBADF /
 *   ENOTCONN otherwise.
 */
ssize_t readv(int fd, const struct iovec *iov, int iovcnt)
{
    uint32_t total = 0u;
    int i;

    if ((fd != IK64_SOCK_FD) || (g_s.state == SOCK_FREE)) {
        errno = EBADF;
        return -1;
    }
    if ((g_s.state != SOCK_CONNECTED) && (g_s.state != SOCK_ERRORED)) {
        errno = ENOTCONN;
        return -1;
    }
    for (i = 0; i < iovcnt; i++) {
        uint8_t *dst = (uint8_t *)iov[i].iov_base;
        uint32_t want = (uint32_t)iov[i].iov_len;

        while ((want != 0u) && (rx_used() != 0u)) {
            const uint32_t pos = g_s.rx_tail % IK64_SOCK_RX_BYTES;
            uint32_t n = IK64_SOCK_RX_BYTES - pos;

            if (n > rx_used()) {
                n = rx_used();
            }
            if (n > want) {
                n = want;
            }
            memcpy(dst, &g_s.rx[pos], n);
            g_s.rx_tail += n;
            dst += n;
            want -= n;
            total += n;
        }
    }
    if (total != 0u) {
        if (g_s.pcb != NULL) {
            tcp_recved(g_s.pcb, (u16_t)total);
        }
        return (ssize_t)total;
    }
    if (g_s.state == SOCK_ERRORED) {
        errno = g_s.so_error;
        return -1;
    }
    if (g_s.peer_closed) {
        return 0;
    }
    errno = EAGAIN;
    return -1;
}

/*
 * writev -- queue as many bytes as the TCP send buffer takes, then push them.
 * Steps:
 *   1. For each vector copy min(len, tcp_sndbuf) with tcp_write; a full
 *      buffer or segment shortage (ERR_MEM) ends the loop.
 *   2. tcp_output once for everything queued.
 * Returns: bytes queued; -1 with EAGAIN when nothing fit, so_error after an
 *   error, EBADF / ENOTCONN otherwise.
 */
ssize_t writev(int fd, const struct iovec *iov, int iovcnt)
{
    uint32_t total = 0u;
    uint32_t asked = 0u;
    int i;
    err_t e = ERR_OK;

    if ((fd != IK64_SOCK_FD) || (g_s.state == SOCK_FREE)) {
        errno = EBADF;
        return -1;
    }
    if (g_s.state == SOCK_ERRORED) {
        errno = g_s.so_error;
        return -1;
    }
    if (g_s.state != SOCK_CONNECTED) {
        errno = ENOTCONN;
        return -1;
    }
    for (i = 0; (i < iovcnt) && (e == ERR_OK); i++) {
        uint32_t len = (uint32_t)iov[i].iov_len;
        uint32_t room = tcp_sndbuf(g_s.pcb);
        uint32_t n = (len < room) ? len : room;

        asked += len;
        if (n == 0u) {
            if (len != 0u) {
                break;
            }
            continue;
        }
        e = tcp_write(g_s.pcb, iov[i].iov_base, (u16_t)n, TCP_WRITE_FLAG_COPY);
        if (e == ERR_OK) {
            total += n;
            if (n < len) {
                break;
            }
        }
    }
    if (total != 0u) {
        (void)tcp_output(g_s.pcb);
        return (ssize_t)total;
    }
    if ((e != ERR_OK) && (e != ERR_MEM)) {
        errno = err_to_errno(e);
        return -1;
    }
    if (asked == 0u) {
        return 0;
    }
    errno = EAGAIN;
    return -1;
}

/*
 * close -- release the socket; never waits.
 * Steps:
 *   1. Detach the callbacks, tcp_close (graceful FIN); if lwIP cannot queue
 *      the close, tcp_abort.
 *   2. Reset the shim state (ring included).
 * Returns: 0, or -1 (EBADF).
 */
int close(int fd)
{
    if ((fd != IK64_SOCK_FD) || (g_s.state == SOCK_FREE)) {
        errno = EBADF;
        return -1;
    }
    if (g_s.pcb != NULL) {
        tcp_arg(g_s.pcb, NULL);
        tcp_recv(g_s.pcb, NULL);
        tcp_err(g_s.pcb, NULL);
        tcp_sent(g_s.pcb, NULL);
        if (tcp_close(g_s.pcb) != ERR_OK) {
            tcp_abort(g_s.pcb);
        }
    }
    memset(&g_s, 0, sizeof(g_s));
    return 0;
}

/*
 * getaddrinfo -- dotted IPv4 address and decimal port only (lwIP has no
 *   resolver here; backend_smb.c gives the server as an IP).
 * Steps:
 *   1. node must parse with ip4addr_aton; service must be a decimal port
 *      (libsmb2 passes "445" or the port it parsed).
 *   2. Fill a static slot: one AF_INET SOCK_STREAM entry.
 * Returns: 0, EAI_NONAME (not a dotted IP), EAI_SERVICE (bad port) or EAI_MEMORY (no free slot).
 */
int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res)
{
    ip4_addr_t ip;
    char *end = NULL;
    unsigned long port;
    uint32_t i;

    (void)hints;
    if ((node == NULL) || (res == NULL) || !ip4addr_aton(node, &ip)) {
        return EAI_NONAME;
    }
    port = (service != NULL) ? strtoul(service, &end, 10) : 0ul;
    if ((service == NULL) || (end == service) || (*end != '\0') || (port == 0ul) || (port > 65535ul)) {
        return EAI_SERVICE;
    }
    for (i = 0u; i < IK64_SOCK_AI_SLOTS; i++) {
        if (!g_ai[i].used) {
            ai_slot_t *s = &g_ai[i];

            memset(s, 0, sizeof(*s));
            s->used = 1;
            s->sin.sin_family = AF_INET;
            s->sin.sin_port = htons((uint16_t)port);
            s->sin.sin_addr.s_addr = ip4_addr_get_u32(&ip);
            s->ai.ai_family = AF_INET;
            s->ai.ai_socktype = SOCK_STREAM;
            s->ai.ai_protocol = IPPROTO_TCP;
            s->ai.ai_addrlen = sizeof(s->sin);
            s->ai.ai_addr = (struct sockaddr *)&s->sin;
            *res = &s->ai;
            return 0;
        }
    }
    return EAI_MEMORY;
}

/*
 * freeaddrinfo -- release the static slot a getaddrinfo result lives in.
 * Returns: nothing.
 */
void freeaddrinfo(struct addrinfo *res)
{
    uint32_t i;

    for (i = 0u; i < IK64_SOCK_AI_SLOTS; i++) {
        if (res == &g_ai[i].ai) {
            g_ai[i].used = 0;
        }
    }
}

/*
 * getlogin_r -- fixed login name for libsmb2's default user (backend_smb.c always sets one).
 * Returns: 0, or ERANGE when buf is too small or NULL.
 */
int getlogin_r(char *buf, size_t size)
{
    static const char login[] = "ik64";

    if ((buf == NULL) || (size < sizeof(login))) {
        return ERANGE;
    }
    memcpy(buf, login, sizeof(login));
    return 0;
}

/*
 * be64toh -- big-endian 64-bit to host order (RV32 is little-endian).
 * Returns: the swapped value.
 */
long long int be64toh(long long int x)
{
    return (long long int)__builtin_bswap64((uint64_t)x);
}

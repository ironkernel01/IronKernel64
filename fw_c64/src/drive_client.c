/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: drive_client.c
 * Role: core 0 requester of the drive protocol (common/drive_proto.h): PING, OPEN, READ,
 *   CLOSE, CMD and STATUS to the 1541 emulation on core 1, plus LOAD (OPEN ch 0, READ loop,
 *   CLOSE) and the core 1 log ring reader.
 *
 * Ownership: this file is the only core 0 file that touches the AXI Mailbox (mailbox_0, S0
 *   interface, XMbox driver) and the shared BRAM (C64_PLAT_SHM_BASE, uncached). Contract:
 *   drive_client.h.
 * Doorbell: core 0 writes the request seq as one 32-bit mailbox word; core 1 answers with
 *   the same seq. The reply wait polls the mailbox (no interrupt) every DC_POLL_US and is
 *   bounded by the per-request timeout. Each timed-out request leaves one possible late
 *   reply; g_stale counts them, and a later word carrying an older seq is discarded while
 *   g_stale > 0. Any other unexpected word is a protocol fault (fail-stop).
 * Ordering: a fence separates the request stores from the doorbell write, and the reply
 *   doorbell read from the reply loads (the BRAM and the mailbox are different AXI slaves).
 * Fail-stop: a failing XMbox call or a protocol fault prints the cause and parks the CPU.
 */
#include "drive_client.h"

#include "c64_platform.h"

#include <stddef.h>         /* offsetof (field addresses in the shared BRAM) */

#include "sleep.h"          /* usleep (bounded reply wait) */
#include "xil_exception.h"  /* Xil_ExceptionDisable (fail-stop park) */
#include "xil_io.h"         /* Xil_In8, Xil_In32, Xil_Out8, Xil_Out32 */
#include "xil_printf.h"     /* xil_printf (fail-stop report) */
#include "xmbox.h"          /* XMbox_* */
#include "xparameters.h"    /* XPAR_MBOX_0_BASEADDR */
#include "xstatus.h"        /* XST_SUCCESS, XST_FIFO_NO_ROOM */

#define DC_MBOX_BASE        (XPAR_MBOX_0_BASEADDR)
#define DC_REQ_BASE         (C64_PLAT_SHM_BASE + DRIVE_REQ_OFS)
#define DC_REP_BASE         (C64_PLAT_SHM_BASE + DRIVE_REP_OFS)
#define DC_DATA_BASE        (C64_PLAT_SHM_BASE + DRIVE_DATA_OFS)
#define DC_LOG_BASE         (C64_PLAT_SHM_BASE + DRIVE_LOG_OFS)
#define DC_LOG_TEXT_BASE    (DC_LOG_BASE + DRIVE_LOG_HDR_BYTES)
#define DC_POLL_US          (20u)
#define DC_POLLS_PER_MS     (1000u / DC_POLL_US)
#define DC_DRAIN_MAX        (16u)       /* mailbox words read before a request (FIFO depth) */
#define DC_WORD_BYTES       (4u)
#define DC_SEQ_HALF         (0x80000000u)

#if C64_PLAT_SHM_RANGE != DRIVE_SHM_BYTES
#error "shared BRAM range (c64_platform.h) differs from DRIVE_SHM_BYTES (drive_proto.h)"
#endif

_Static_assert(sizeof(drive_req_t) <= DRIVE_REQ_BYTES, "drive_req_t exceeds DRIVE_REQ_BYTES");
_Static_assert(sizeof(drive_rep_t) <= DRIVE_REP_BYTES, "drive_rep_t exceeds DRIVE_REP_BYTES");
_Static_assert(sizeof(drive_log_t) <= DRIVE_LOG_HDR_BYTES,
               "drive_log_t exceeds DRIVE_LOG_HDR_BYTES");
_Static_assert((DRIVE_DATA_OFS % DC_WORD_BYTES) == 0u, "data area must be word aligned");

static XMbox    g_mbox;
static uint32_t g_seq;
static uint8_t  g_device = DRIVE_DEVICE;          /* target of the requests: 8 or 9 */
static uint32_t g_stale;                           /* timed-out requests whose reply may come */
static uint8_t  g_last_status;
static char     g_last_text[DRIVE_STATUS_TEXT_BYTES];

/*
 * dc_fail -- fail-stop: report the failing API or protocol check and park.
 * Steps:
 *   1. Print the name and code on the console.
 *   2. Disable interrupts and park the CPU.
 * Returns: never.
 */
static void dc_fail(const char *what, int code)
{
    xil_printf("FATAL drive_client: %s (%d)\r\n", what, code);
    Xil_ExceptionDisable();
    for (;;) {
    }
}

/*
 * dc_fence -- order earlier loads/stores before later ones across AXI slaves.
 * Returns: nothing.
 */
static inline void dc_fence(void)
{
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
}

/*
 * drive_client_init -- set up the mailbox and the protocol state.
 * Steps:
 *   1. XMbox_LookupConfig / XMbox_CfgInitialize for mailbox_0 (fail-stop).
 *   2. Reset this interface's FIFOs (drops doorbells left by an earlier run).
 *   3. Start the seq counter; clear the last status ("00, OK,00,00" until a reply).
 * Returns: nothing.
 */
void drive_client_init(void)
{
    XMbox_Config *cfg = XMbox_LookupConfig(DC_MBOX_BASE);
    int st;

    if (cfg == NULL) {
        dc_fail("XMbox_LookupConfig", 0);
    }
    st = XMbox_CfgInitialize(&g_mbox, cfg, cfg->BaseAddress);
    if (st != XST_SUCCESS) {
        dc_fail("XMbox_CfgInitialize", st);
    }
    XMbox_ResetFifos(&g_mbox);
    g_seq = 0u;
    g_stale = 0u;
    g_device = DRIVE_DEVICE;
    g_last_status = DRIVE_ST_OK;
    for (uint32_t i = 0u; i < DRIVE_STATUS_TEXT_BYTES; i++) {
        g_last_text[i] = '\0';
    }
}

/*
 * read_word -- take one word from the mailbox when one is waiting.
 * Returns: 1 and *word set, 0 when the receive FIFO is empty.
 */
static int read_word(uint32_t *word)
{
    u32 got = 0u;
    int st;

    if (XMbox_IsEmpty(&g_mbox)) {
        return 0;
    }
    st = XMbox_Read(&g_mbox, word, DC_WORD_BYTES, &got);
    if (st != XST_SUCCESS || got != DC_WORD_BYTES) {
        dc_fail("XMbox_Read", st);
    }
    return 1;
}

/*
 * is_stale -- a word is the late reply of an earlier, timed-out request.
 * Returns: 1 (and one stale reply is accounted for) or 0.
 */
static int is_stale(uint32_t word)
{
    uint32_t age = g_seq - word;

    if (g_stale > 0u && age != 0u && age < DC_SEQ_HALF) {
        g_stale--;
        return 1;
    }
    return 0;
}

/*
 * store_text -- copy a NUL-terminated string into the request name field.
 * Returns: 1 when it fits (with its NUL), else 0 and nothing written.
 */
static int store_text(const char *text)
{
    uint32_t n = 0u;

    while (text[n] != '\0') {
        if (++n >= DRIVE_NAME_BYTES) {
            return 0;
        }
    }
    for (uint32_t i = 0u; i <= n; i++) {
        Xil_Out8(DC_REQ_BASE + offsetof(drive_req_t, name) + i, (uint8_t)text[i]);
    }
    return 1;
}

/*
 * transact -- one request/reply exchange.
 * Steps:
 *   1. Read off waiting mailbox words (at most DC_DRAIN_MAX): late replies are dropped,
 *      anything else is a protocol fault.
 *   2. Fill the request block (magic, next seq, op, current device, channel, len; the name was
 *      stored by the caller), fence, ring the doorbell with the seq. A full send FIFO
 *      means core 1 is not taking requests: DRIVE_CLIENT_TIMEOUT.
 *   3. Poll for the reply seq every DC_POLL_US for at most timeout_ms; drop late replies.
 *   4. Fence, check the reply magic and seq (fail-stop on mismatch), and keep status,
 *      track, sector and the status text.
 * Returns: DRIVE_CLIENT_OK, DRIVE_CLIENT_DOS_ERROR (status >= 20) or DRIVE_CLIENT_TIMEOUT.
 */
static drive_client_result_t transact(drive_op_t op, uint8_t channel, uint32_t len,
                                      uint32_t timeout_ms)
{
    uint32_t word;
    u32 sent = 0u;
    int st;
    int answered = 0;

    for (uint32_t i = 0u; i < DC_DRAIN_MAX && read_word(&word); i++) {
        if (!is_stale(word)) {
            dc_fail("unexpected mailbox word", (int)word);
        }
    }

    g_seq++;
    Xil_Out32(DC_REQ_BASE + offsetof(drive_req_t, magic), DRIVE_MAGIC);
    Xil_Out32(DC_REQ_BASE + offsetof(drive_req_t, seq), g_seq);
    Xil_Out8(DC_REQ_BASE + offsetof(drive_req_t, op), (uint8_t)op);
    Xil_Out8(DC_REQ_BASE + offsetof(drive_req_t, device), g_device);
    Xil_Out8(DC_REQ_BASE + offsetof(drive_req_t, channel), channel);
    Xil_Out8(DC_REQ_BASE + offsetof(drive_req_t, reserved0), 0u);
    Xil_Out32(DC_REQ_BASE + offsetof(drive_req_t, len), len);
    dc_fence();

    word = g_seq;
    st = XMbox_Write(&g_mbox, &word, DC_WORD_BYTES, &sent);
    if (st == XST_FIFO_NO_ROOM) {
        return DRIVE_CLIENT_TIMEOUT;
    }
    if (st != XST_SUCCESS || sent != DC_WORD_BYTES) {
        dc_fail("XMbox_Write", st);
    }

    for (uint32_t poll = 0u; poll < timeout_ms * DC_POLLS_PER_MS && !answered; poll++) {
        if (read_word(&word)) {
            if (word == g_seq) {
                answered = 1;
            } else if (!is_stale(word)) {
                dc_fail("reply seq mismatch", (int)word);
            }
        } else {
            usleep(DC_POLL_US);
        }
    }
    if (!answered) {
        g_stale++;
        return DRIVE_CLIENT_TIMEOUT;
    }
    dc_fence();

    if (Xil_In32(DC_REP_BASE + offsetof(drive_rep_t, magic)) != DRIVE_MAGIC) {
        dc_fail("reply magic", (int)Xil_In32(DC_REP_BASE + offsetof(drive_rep_t, magic)));
    }
    if (Xil_In32(DC_REP_BASE + offsetof(drive_rep_t, seq)) != g_seq) {
        dc_fail("reply block seq", (int)Xil_In32(DC_REP_BASE + offsetof(drive_rep_t, seq)));
    }
    g_last_status = Xil_In8(DC_REP_BASE + offsetof(drive_rep_t, status));
    for (uint32_t i = 0u; i < DRIVE_STATUS_TEXT_BYTES; i++) {
        g_last_text[i] = (char)Xil_In8(DC_REP_BASE + offsetof(drive_rep_t, text) + i);
    }
    g_last_text[DRIVE_STATUS_TEXT_BYTES - 1u] = '\0';
    return (g_last_status >= DRIVE_CLIENT_DOS_ERROR_MIN) ? DRIVE_CLIENT_DOS_ERROR
                                                          : DRIVE_CLIENT_OK;
}

/*
 * drive_client_set_device -- choose the device (8 or 9) that later requests address.
 * Returns: nothing; any other number is ignored (the caller validated it).
 */
void drive_client_set_device(uint8_t device)
{
    if (device == DRIVE_DEVICE_SMB || device == DRIVE_DEVICE_BANK) {
        g_device = device;
    }
}

/*
 * drive_client_device -- the device later requests address.
 * Returns: 8 or 9.
 */
uint8_t drive_client_device(void)
{
    return g_device;
}

/*
 * drive_client_ping_device -- PING one device without changing the current one.
 * Returns: as drive_client_ping.
 */
drive_client_result_t drive_client_ping_device(uint8_t device)
{
    const uint8_t keep = g_device;
    drive_client_result_t r;

    drive_client_set_device(device);
    r = drive_client_ping();
    g_device = keep;
    return r;
}

/*
 * drive_client_ping -- is the current device there?
 * Returns: DRIVE_CLIENT_OK, or DRIVE_CLIENT_TIMEOUT after DRIVE_CLIENT_PING_TIMEOUT_MS.
 */
drive_client_result_t drive_client_ping(void)
{
    (void)store_text("");
    return transact(DRIVE_OP_PING, DRIVE_CH_COMMAND, 0u, DRIVE_CLIENT_PING_TIMEOUT_MS);
}

/*
 * drive_client_open -- OPEN a channel with a file name ("$" on channel 0 = directory).
 * Returns: OK, DOS_ERROR (e.g. 62 FILE NOT FOUND), TIMEOUT or BAD_ARG.
 */
drive_client_result_t drive_client_open(uint8_t channel, const char *name)
{
    if (channel > DRIVE_CH_COMMAND || !store_text(name)) {
        return DRIVE_CLIENT_BAD_ARG;
    }
    return transact(DRIVE_OP_OPEN, channel, 0u, DRIVE_CLIENT_OP_TIMEOUT_MS);
}

/*
 * drive_client_read -- READ up to max bytes from an open channel.
 * Steps:
 *   1. Ask for min(max, DRIVE_DATA_BYTES) bytes.
 *   2. Check the reply length: more than asked, or 0 without EOI, is a protocol fault.
 *   3. Copy the bytes out of the data area (word reads, byte tail).
 * Returns: OK with *len and *eoi set, DOS_ERROR, TIMEOUT or BAD_ARG.
 */
drive_client_result_t drive_client_read(uint8_t channel, uint8_t *buf, uint32_t max,
                                        uint32_t *len, int *eoi)
{
    uint32_t want = (max < DRIVE_DATA_BYTES) ? max : DRIVE_DATA_BYTES;
    uint32_t got;
    uint32_t i = 0u;
    drive_client_result_t r;

    *len = 0u;
    *eoi = 0;
    if (channel > DRIVE_CH_COMMAND || want == 0u) {
        return DRIVE_CLIENT_BAD_ARG;
    }
    (void)store_text("");
    r = transact(DRIVE_OP_READ, channel, want, DRIVE_CLIENT_OP_TIMEOUT_MS);
    if (r != DRIVE_CLIENT_OK) {
        return r;
    }
    got = Xil_In32(DC_REP_BASE + offsetof(drive_rep_t, len));
    *eoi = (Xil_In8(DC_REP_BASE + offsetof(drive_rep_t, eoi)) != 0u) ? 1 : 0;
    if (got > want || (got == 0u && !*eoi)) {
        dc_fail("READ reply length", (int)got);
    }
    for (; i + DC_WORD_BYTES <= got; i += DC_WORD_BYTES) {
        uint32_t w = Xil_In32(DC_DATA_BASE + i);
        buf[i] = (uint8_t)w;
        buf[i + 1u] = (uint8_t)(w >> 8);
        buf[i + 2u] = (uint8_t)(w >> 16);
        buf[i + 3u] = (uint8_t)(w >> 24);
    }
    for (; i < got; i++) {
        buf[i] = Xil_In8(DC_DATA_BASE + i);
    }
    *len = got;
    return DRIVE_CLIENT_OK;
}

/*
 * drive_client_close -- CLOSE a channel.
 * Returns: OK, DOS_ERROR, TIMEOUT or BAD_ARG.
 */
drive_client_result_t drive_client_close(uint8_t channel)
{
    if (channel > DRIVE_CH_COMMAND) {
        return DRIVE_CLIENT_BAD_ARG;
    }
    (void)store_text("");
    return transact(DRIVE_OP_CLOSE, channel, 0u, DRIVE_CLIENT_OP_TIMEOUT_MS);
}

/*
 * drive_client_cmd -- send a DOS command on channel 15 (CD:name, CD//, CD:<-, I, UI).
 * Returns: OK, DOS_ERROR, TIMEOUT or BAD_ARG; the status line is in drive_client_last_text.
 */
drive_client_result_t drive_client_cmd(const char *text)
{
    if (!store_text(text)) {
        return DRIVE_CLIENT_BAD_ARG;
    }
    return transact(DRIVE_OP_CMD, DRIVE_CH_COMMAND, 0u, DRIVE_CLIENT_OP_TIMEOUT_MS);
}

/*
 * drive_client_status -- read the channel 15 status line (the drive's error channel).
 * Returns: OK or DOS_ERROR (the status itself), or TIMEOUT.
 */
drive_client_result_t drive_client_status(void)
{
    (void)store_text("");
    return transact(DRIVE_OP_STATUS, DRIVE_CH_COMMAND, 0u, DRIVE_CLIENT_OP_TIMEOUT_MS);
}

/*
 * drive_client_load -- load a whole file: PING, OPEN channel 0, READ until EOI, CLOSE.
 * Steps:
 *   1. PING with the short timeout (no answer: TIMEOUT = DEVICE NOT PRESENT).
 *   2. OPEN channel 0 with the name; a DOS error (62 FILE NOT FOUND) ends here.
 *   3. READ into buf until EOI; each READ returns at least one byte, so the loop ends
 *      after at most max reads; a full buffer without EOI is DRIVE_CLIENT_TOO_BIG.
 *   4. CLOSE channel 0 whenever the OPEN succeeded.
 * Returns: OK with *len = file length (load address included), or the first failure.
 */
drive_client_result_t drive_client_load(const char *name, uint8_t *buf, uint32_t max,
                                        uint32_t *len)
{
    drive_client_result_t r;
    drive_client_result_t rc;
    uint32_t total = 0u;
    int eoi = 0;

    *len = 0u;
    if (max == 0u) {
        return DRIVE_CLIENT_BAD_ARG;
    }
    r = drive_client_ping();
    if (r != DRIVE_CLIENT_OK) {
        return r;
    }
    r = drive_client_open(DRIVE_CH_LOAD, name);
    if (r != DRIVE_CLIENT_OK) {
        return r;
    }
    for (uint32_t reads = 0u; reads < max && !eoi && r == DRIVE_CLIENT_OK; reads++) {
        uint32_t got = 0u;
        if (total == max) {
            r = DRIVE_CLIENT_TOO_BIG;
            break;
        }
        r = drive_client_read(DRIVE_CH_LOAD, &buf[total], max - total, &got, &eoi);
        total += got;
    }
    rc = drive_client_close(DRIVE_CH_LOAD);
    if (r == DRIVE_CLIENT_OK && !eoi) {
        r = DRIVE_CLIENT_TOO_BIG;
    }
    if (r == DRIVE_CLIENT_OK && rc == DRIVE_CLIENT_TIMEOUT) {
        r = rc;
    }
    *len = total;
    return r;
}

/*
 * drive_client_last_status -- CBM DOS code of the last reply.
 * Returns: the code (0 = OK).
 */
uint8_t drive_client_last_status(void)
{
    return g_last_status;
}

/*
 * drive_client_last_text -- status line of the last reply ("62,FILE NOT FOUND,00,00").
 * Returns: nothing; text holds at most size - 1 characters and a NUL.
 */
void drive_client_last_text(char *text, uint32_t size)
{
    uint32_t i = 0u;

    if (size == 0u) {
        return;
    }
    for (; i + 1u < size && i < DRIVE_STATUS_TEXT_BYTES && g_last_text[i] != '\0'; i++) {
        text[i] = g_last_text[i];
    }
    text[i] = '\0';
}

/*
 * drive_client_log_drain -- print waiting core 1 log text through put().
 * Steps:
 *   1. Return 0 until core 1 has written DRIVE_LOG_MAGIC.
 *   2. If head runs more than the ring size ahead of tail, skip to the oldest byte kept.
 *   3. Pass at most max bytes to put(), then publish the new tail (core 0 owns tail).
 * Returns: number of bytes passed to put().
 */
uint32_t drive_client_log_drain(void (*put)(char c), uint32_t max)
{
    uint32_t head;
    uint32_t tail;
    uint32_t n = 0u;

    if (Xil_In32(DC_LOG_BASE + offsetof(drive_log_t, magic)) != DRIVE_LOG_MAGIC) {
        return 0u;
    }
    head = Xil_In32(DC_LOG_BASE + offsetof(drive_log_t, head));
    tail = Xil_In32(DC_LOG_BASE + offsetof(drive_log_t, tail));
    if (head - tail > DRIVE_LOG_TEXT_BYTES) {
        tail = head - DRIVE_LOG_TEXT_BYTES;
    }
    dc_fence();
    while (n < max && n < DRIVE_LOG_TEXT_BYTES && tail != head) {
        put((char)Xil_In8(DC_LOG_TEXT_BASE + (tail % DRIVE_LOG_TEXT_BYTES)));
        tail++;
        n++;
    }
    dc_fence();
    Xil_Out32(DC_LOG_BASE + offsetof(drive_log_t, tail), tail);
    return n;
}

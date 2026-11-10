/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: drive_server.c
 * Role: core 1 side of the drive protocol; contract in drive_server.h and
 *   common/drive_proto.h, mirror image of fw_c64/src/drive_client.c.
 *
 * Doorbell: core 0 writes the request seq as one mailbox word after it filled
 *   the request block. The loop polls the mailbox (no interrupt). A word whose
 *   seq differs from the request block's (stale doorbell) or a bad magic is
 *   dropped without a reply (core 0 times out). The reply is written, fenced,
 *   and its seq goes back through the mailbox.
 * Data: READ goes through a static staging buffer in DDR3 (backend reads are
 *   cached DDR3 writes) and is copied to the uncached BRAM data area in words.
 * Devices: 8 is the SMB share (ready flag from main), 9 the tune bank (backend_ram, ready when the
 *   bank image validates; no network involved). cbmdos_select switches backend and directory
 *   header before each request. Any other device number is answered 74.
 * Idle: drive_server_idle lets the blocking waits of the bring-up (network wait loops, SMB mount
 *   retries) keep device 9 alive; it does nothing while a request is being served.
 * Log: one line per OPEN, CMD, failure and file end (never credentials).
 */
#include "drive_server.h"

#include "backend_ram.h"
#include "cbmdos.h"
#include "drive_log.h"
#include "drive_proto.h"

#include "c64_platform.h"

#include <stddef.h>         /* offsetof */

#include "xil_io.h"         /* Xil_In8, Xil_In32, Xil_Out8, Xil_Out32 */
#include "xmbox.h"          /* XMbox_* */
#include "xparameters.h"    /* XPAR_MBOX_0_BASEADDR */
#include "xstatus.h"        /* XST_SUCCESS */

#define DS_MBOX_BASE        (XPAR_MBOX_0_BASEADDR)
#define DS_REQ_BASE         (C64_PLAT_SHM_BASE + DRIVE_REQ_OFS)
#define DS_REP_BASE         (C64_PLAT_SHM_BASE + DRIVE_REP_OFS)
#define DS_DATA_BASE        (C64_PLAT_SHM_BASE + DRIVE_DATA_OFS)
#define DS_WORD_BYTES       (4u)

_Static_assert(sizeof(drive_req_t) <= DRIVE_REQ_BYTES, "drive_req_t exceeds DRIVE_REQ_BYTES");
_Static_assert(sizeof(drive_rep_t) <= DRIVE_REP_BYTES, "drive_rep_t exceeds DRIVE_REP_BYTES");
_Static_assert((DRIVE_DATA_OFS % DS_WORD_BYTES) == 0u, "data area must be word aligned");

static XMbox    g_mbox;
static int      g_up;                        /* mailbox initialised */
static int      g_ready;
static int      g_busy;                      /* a request is being served (idle hook must not re-enter) */
static int      g_bank_ok;                   /* last bank validation passed */
static const backend_ops_t *g_smb;
static const backend_ops_t *g_bank;
static uint8_t  g_stage[DRIVE_DATA_BYTES];   /* READ staging (DDR3) */

typedef struct
{
    uint8_t  status;
    uint8_t  eoi;
    uint32_t len;
} ds_result_t;

static inline void ds_fence(void)
{
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
}

/*
 * drive_server_init -- mailbox setup and cbmdos start.
 * Steps:
 *   1. XMbox lookup and init for the S1 interface (a failure is logged and the
 *      server stays disabled: poll then does nothing).
 *   2. Reset this interface's FIFOs (drops doorbells of an earlier run).
 *   3. cbmdos_init with the share backend (device 8, not ready); device 9's backend is kept.
 * Returns: nothing.
 */
void drive_server_init(const backend_ops_t *smb_ops, const backend_ops_t *bank_ops)
{
    XMbox_Config *cfg = XMbox_LookupConfig(DS_MBOX_BASE);

    g_ready = 0;
    g_up = 0;
    g_busy = 0;
    g_bank_ok = 0;
    g_smb = smb_ops;
    g_bank = bank_ops;
    cbmdos_init(smb_ops);
    if (cfg == NULL || XMbox_CfgInitialize(&g_mbox, cfg, cfg->BaseAddress) != XST_SUCCESS) {
        drive_log_printf("DRV: mailbox init FAILED\r\n");
        return;
    }
    XMbox_ResetFifos(&g_mbox);
    g_up = 1;
    drive_log_printf("DRV: server up, mailbox S1 at 0x%08lx\r\n", (unsigned long)DS_MBOX_BASE);
}

/*
 * drive_server_set_ready -- main's "share mounted" flag. Clearing it drops the
 *   open channel (the backend unmount closes the handle).
 * Returns: nothing.
 */
void drive_server_set_ready(int ready)
{
    if (!ready && g_ready) {
        cbmdos_abort();
    }
    g_ready = ready ? 1 : 0;
}

int drive_server_ready(void)
{
    return g_ready;
}

/*
 * drive_server_idle -- take a request from inside a bring-up wait loop.
 * Context: called by the network wait loops (ik64_sock poll, SMB mount retry, log-space wait).
 *   While device 8 is not ready every device 8 request is answered 74 without touching the
 *   backend, and device 9 only touches backend_ram, so serving here cannot disturb the SMB
 *   session being brought up. While a request is already being served (the SMB read that is
 *   waiting in poll) it returns at once.
 * Returns: nothing.
 */
void drive_server_idle(void)
{
    if (!g_busy) {
        drive_server_poll();
    }
}

/*
 * put_reply -- fill the reply block.
 * Returns: nothing.
 */
static void put_reply(uint32_t seq, const ds_result_t *r, const char *text)
{
    Xil_Out32(DS_REP_BASE + offsetof(drive_rep_t, magic), DRIVE_MAGIC);
    Xil_Out32(DS_REP_BASE + offsetof(drive_rep_t, seq), seq);
    Xil_Out8(DS_REP_BASE + offsetof(drive_rep_t, status), r->status);
    Xil_Out8(DS_REP_BASE + offsetof(drive_rep_t, track), 0u);
    Xil_Out8(DS_REP_BASE + offsetof(drive_rep_t, sector), 0u);
    Xil_Out8(DS_REP_BASE + offsetof(drive_rep_t, eoi), r->eoi);
    Xil_Out32(DS_REP_BASE + offsetof(drive_rep_t, len), r->len);
    for (uint32_t i = 0u; i < DRIVE_STATUS_TEXT_BYTES; i++) {
        Xil_Out8(DS_REP_BASE + offsetof(drive_rep_t, text) + i, (uint8_t)*text);
        if (*text != '\0') {
            text++;
        }
    }
    Xil_Out8(DS_REP_BASE + offsetof(drive_rep_t, text) + DRIVE_STATUS_TEXT_BYTES - 1u, 0u);
}

/*
 * put_data -- copy len staged bytes to the BRAM data area (words, byte tail).
 * Returns: nothing.
 */
static void put_data(uint32_t len)
{
    uint32_t i = 0u;

    for (; i + DS_WORD_BYTES <= len; i += DS_WORD_BYTES) {
        Xil_Out32(DS_DATA_BASE + i, (uint32_t)g_stage[i] | ((uint32_t)g_stage[i + 1u] << 8) |
                                    ((uint32_t)g_stage[i + 2u] << 16) | ((uint32_t)g_stage[i + 3u] << 24));
    }
    for (; i < len; i++) {
        Xil_Out8(DS_DATA_BASE + i, g_stage[i]);
    }
}

/*
 * log_name -- printable-ASCII copy of a request name for the log.
 * Returns: nothing.
 */
static void log_name(const char *name, char *out, uint32_t size)
{
    uint32_t i;

    for (i = 0u; i + 1u < size && name[i] != '\0'; i++) {
        out[i] = (name[i] >= 0x20 && name[i] < 0x7F) ? name[i] : '?';
    }
    out[i] = '\0';
}

/*
 * select_device -- point cbmdos at the device's backend and decide whether it can serve.
 * Steps:
 *   1. Device 8: the ready flag from main. Device 9: backend_ram_mount re-validates the bank on
 *      every OPEN and PING; other requests (READ, CLOSE, CMD, STATUS) use the state it left.
 *   2. Any other number: not served.
 * Returns: 1 when requests of this device can be served now, else 0.
 */
static int select_device(uint8_t device, uint8_t op)
{
    if (device == DRIVE_DEVICE_SMB) {
        cbmdos_select(g_smb, CBMDOS_LABEL_NET);
        return g_ready;
    }
    if (device == DRIVE_DEVICE_BANK) {
        cbmdos_select(g_bank, CBMDOS_LABEL_ROM);
        if (op == DRIVE_OP_OPEN || op == DRIVE_OP_PING) {
            g_bank_ok = (backend_ram_mount() == BACKEND_OK) ? 1 : 0;
        }
        return g_bank_ok;
    }
    return 0;
}

/*
 * dispatch -- run one request.
 * Steps:
 *   1. Device not servable (select_device): 74 for everything except CLOSE (which only tidies cbmdos).
 *   2. PING: OK. OPEN, READ (into the staging buffer), CLOSE, CMD, STATUS: cbmdos.
 *   3. A backend failure inside cbmdos clears ready.
 * Returns: nothing; r is set.
 */
static void dispatch(uint8_t device, uint8_t op, uint8_t ch, uint32_t want, const char *name, ds_result_t *r)
{
    char shown[DRIVE_NAME_BYTES];

    r->status = DRIVE_ST_OK;
    r->eoi = 0u;
    r->len = 0u;
    log_name(name, shown, sizeof(shown));
    if (!select_device(device, op) && op != DRIVE_OP_CLOSE) {
        r->status = DRIVE_ST_DRIVE_NOT_READY;
        return;
    }
    switch (op) {
    case DRIVE_OP_PING:
        break;
    case DRIVE_OP_OPEN:
        r->status = cbmdos_open(ch, name);
        drive_log_printf("DRV: OPEN %u,%u \"%s\" -> %s\r\n", (unsigned)device, (unsigned)ch, shown,
                         (r->status == CBMDOS_OK) ? cbmdos_info() : cbmdos_text(r->status));
        break;
    case DRIVE_OP_READ: {
        uint32_t got = 0u;
        int eoi = 0;

        if (want == 0u) {
            want = 1u;
        } else if (want > DRIVE_DATA_BYTES) {
            want = DRIVE_DATA_BYTES;
        }
        r->status = cbmdos_read(ch, g_stage, want, &got, &eoi);
        r->len = got;
        r->eoi = eoi ? 1u : 0u;
        if (r->status != CBMDOS_OK) {
            drive_log_printf("DRV: READ %u -> %s\r\n", (unsigned)ch, cbmdos_text(r->status));
        } else if (eoi) {
            drive_log_printf("DRV: READ %u -> EOI, last chunk %lu B\r\n", (unsigned)ch, (unsigned long)got);
        }
        break;
    }
    case DRIVE_OP_CLOSE:
        r->status = cbmdos_close(ch);
        drive_log_printf("DRV: CLOSE %u\r\n", (unsigned)ch);
        break;
    case DRIVE_OP_CMD:
        r->status = cbmdos_cmd(name);
        drive_log_printf("DRV: CMD \"%s\" -> %s\r\n", shown, cbmdos_text(r->status));
        break;
    case DRIVE_OP_STATUS:
        r->status = cbmdos_take_status();
        break;
    default:
        r->status = CBMDOS_SYNTAX;
        drive_log_printf("DRV: unknown op %u\r\n", (unsigned)op);
        break;
    }
    if (cbmdos_take_backend_lost() && device == DRIVE_DEVICE_SMB) {
        drive_log_printf("DRV: backend lost, drive not ready until remount\r\n");
        drive_server_set_ready(0);
    }
}

/*
 * drive_server_poll -- take at most one request and answer it.
 * Steps:
 *   1. Mailbox empty: return.
 *   2. Read the doorbell word, fence, read the request block; drop a bad
 *      magic or a seq that differs from the doorbell.
 *   3. dispatch; write the data area and reply block, fence, ring the reply
 *      doorbell with the seq (a full FIFO is logged and the reply dropped).
 * Returns: nothing.
 */
void drive_server_poll(void)
{
    char name[DRIVE_NAME_BYTES];
    ds_result_t r;
    uint32_t word = 0u;
    u32 got = 0u;
    u32 sent = 0u;
    uint32_t seq;
    uint32_t want;
    uint8_t op;
    uint8_t ch;
    uint8_t device;

    if (!g_up || XMbox_IsEmpty(&g_mbox)) {
        return;
    }
    if (XMbox_Read(&g_mbox, &word, DS_WORD_BYTES, &got) != XST_SUCCESS || got != DS_WORD_BYTES) {
        drive_log_printf("DRV: mailbox read failed\r\n");
        return;
    }
    ds_fence();
    seq = Xil_In32(DS_REQ_BASE + offsetof(drive_req_t, seq));
    if (Xil_In32(DS_REQ_BASE + offsetof(drive_req_t, magic)) != DRIVE_MAGIC || seq != word) {
        drive_log_printf("DRV: bad request dropped (doorbell %lu, block %lu)\r\n",
                         (unsigned long)word, (unsigned long)seq);
        return;
    }
    op = Xil_In8(DS_REQ_BASE + offsetof(drive_req_t, op));
    ch = Xil_In8(DS_REQ_BASE + offsetof(drive_req_t, channel));
    device = Xil_In8(DS_REQ_BASE + offsetof(drive_req_t, device));
    want = Xil_In32(DS_REQ_BASE + offsetof(drive_req_t, len));
    for (uint32_t i = 0u; i < DRIVE_NAME_BYTES; i++) {
        name[i] = (char)Xil_In8(DS_REQ_BASE + offsetof(drive_req_t, name) + i);
    }
    name[DRIVE_NAME_BYTES - 1u] = '\0';

    g_busy = 1;
    dispatch(device, op, ch, want, name, &r);
    g_busy = 0;
    if (r.len > 0u) {
        put_data(r.len);
    }
    put_reply(seq, &r, cbmdos_text(r.status));
    ds_fence();
    word = seq;
    if (XMbox_Write(&g_mbox, &word, DS_WORD_BYTES, &sent) != XST_SUCCESS || sent != DS_WORD_BYTES) {
        drive_log_printf("DRV: reply doorbell failed (FIFO full)\r\n");
    }
}

/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: backend_smb.c
 * Role: drive backend over an SMB2/3 share with libsmb2's synchronous API
 *   (contract: backend.h, backend_smb.h). The only file that calls libsmb2.
 *
 * Configuration: netshare.h picks fw_1541/netshare_config.h (gitignored,
 *   filled in by the user from netshare_config.example.h), or the example's
 *   placeholders in a PUBLIC build. The build stops here when a field is missing.
 */
#include "backend_smb.h"

#include "drive_log.h"     /* drive_log_printf */
#include "drive_server.h"  /* drive_server_idle (device 9 keeps being served during the retry wait) */
#include "drive_proto.h"   /* DRIVE_DATA_BYTES */

#include "ik64_netcore.h" /* ik64_net_service, ik64_uptime_ms64 */

#include <stdint.h>            /* fixed-width types libsmb2's headers use */
#include <time.h>              /* time_t: libsmb2's headers do not include it */
#include <smb2/smb2.h>         /* SMB2_NEGOTIATE_SIGNING_ENABLED */
#include <smb2/libsmb2.h>      /* smb2_* synchronous API */
#include <smb2/smb2-errors.h>  /* SMB2_STATUS_* */

#include <errno.h>         /* ENOENT, ENOTDIR, EISDIR, ENOMEM, EACCES */
#include <fcntl.h>         /* O_RDONLY for smb2_open */
#include <stdio.h>         /* snprintf */
#include <string.h>        /* strlen, memcpy, strcmp */

#include "netshare.h"   /* netshare_config.h, or the example placeholders in a PUBLIC build */

#if !defined(NETSHARE_SERVER) || !defined(NETSHARE_SHARE) || !defined(NETSHARE_BASE_PATH)
#error "netshare_config.h must define NETSHARE_SERVER, NETSHARE_SHARE and NETSHARE_BASE_PATH"
#endif
#if !defined(NETSHARE_DOMAIN) || !defined(NETSHARE_USER) || !defined(NETSHARE_PASSWORD)
#error "netshare_config.h must define NETSHARE_DOMAIN, NETSHARE_USER and NETSHARE_PASSWORD"
#endif
#if !defined(NETSHARE_SMB_VERSION) || !defined(NETSHARE_SEAL) || !defined(NETSHARE_SIGN)
#error "netshare_config.h must define NETSHARE_SMB_VERSION, NETSHARE_SEAL and NETSHARE_SIGN"
#endif
#if !defined(NETSHARE_TIMEOUT_S) || !defined(NETSHARE_IP_MODE)
#error "netshare_config.h must define NETSHARE_TIMEOUT_S and NETSHARE_IP_MODE"
#endif

#if BACKEND_SMB_READ_CHUNK > DRIVE_DATA_BYTES
#error "BACKEND_SMB_READ_CHUNK exceeds the drive data area (common/drive_proto.h)"
#endif

/* Workstation name sent in NTLMSSP (shows in the NAS's session list). */
#define BACKEND_SMB_WORKSTATION  "IK64-1541"

typedef struct
{
    struct smb2fh *fh;      /* NULL = slot free */
    uint64_t       size;    /* bytes, from smb2_fstat at open */
    uint64_t       pos;     /* bytes read so far */
} smb_file_t;

static struct smb2_context *g_smb2;              /* NULL = not mounted */
static struct smb2dir *g_dir;                    /* the one open listing */
static smb_file_t g_files[BACKEND_MAX_FILES];
static char g_status[BACKEND_STATUS_TEXT_BYTES]; /* last failure, or "OK" */
static char g_path[BACKEND_PATH_BYTES];          /* share-relative path scratch */

/*
 * set_status -- record the status line for status_text and the log.
 * Steps:
 *   1. snprintf "<api>: <text>" into g_status (cut at the buffer size).
 * Returns: nothing.
 */
static void set_status(const char *api, const char *text)
{
    (void)snprintf(g_status, sizeof(g_status), "%s: %s", api, text);
}

/*
 * drop -- forget the connection after a failure that may have broken it.
 * Steps:
 *   1. Forget the listing and file handles (their server state is gone with
 *      the session; libsmb2 frees them with the context).
 *   2. smb2_destroy_context (closes the socket, frees every allocation).
 * Returns: nothing.
 */
static void drop(void)
{
    uint32_t i;

    g_dir = NULL;
    for (i = 0u; i < BACKEND_MAX_FILES; i++) {
        g_files[i].fh = NULL;
    }
    if (g_smb2 != NULL) {
        smb2_destroy_context(g_smb2);
        g_smb2 = NULL;
    }
}

/*
 * classify -- map a failed libsmb2 call to a backend status.
 * Steps:
 *   1. Record "<api>: <libsmb2 error> (rc, NTSTATUS)" and log it.
 *   2. NTSTATUS / errno "not found" -> NOT_FOUND, "not a directory" or "is
 *      a directory" -> NOT_DIR (session intact).
 *   3. Logon or access refusals -> AUTH; ENOMEM (a smb_alloc reject) -> IO.
 *      The session stays for these.
 *   4. Anything else may have broken the session: drop() and NOT_READY.
 *      EVIDENCE: a libsmb2 command failed without a file-level NTSTATUS.
 * Returns: the mapped backend_status_t.
 */
static backend_status_t classify(const char *api, int rc)
{
    uint32_t nt = (g_smb2 != NULL) ? (uint32_t)smb2_get_nterror(g_smb2) : 0u;
    const char *err = (g_smb2 != NULL) ? smb2_get_error(g_smb2) : "no context";
    char text[BACKEND_STATUS_TEXT_BYTES];

    (void)snprintf(text, sizeof(text), "%s (rc %d, NTSTATUS 0x%08lx)", err, rc,
                   (unsigned long)nt);
    set_status(api, text);
    drive_log_printf("SMB: %s\r\n", g_status);

    if ((nt == SMB2_STATUS_OBJECT_NAME_NOT_FOUND) || (nt == SMB2_STATUS_OBJECT_PATH_NOT_FOUND) ||
        (nt == SMB2_STATUS_NO_SUCH_FILE) || (rc == -ENOENT)) {
        return BACKEND_ERR_NOT_FOUND;
    }
    if ((nt == SMB2_STATUS_NOT_A_DIRECTORY) || (nt == SMB2_STATUS_FILE_IS_A_DIRECTORY) ||
        (rc == -ENOTDIR) || (rc == -EISDIR)) {
        return BACKEND_ERR_NOT_DIR;
    }
    if ((nt == SMB2_STATUS_ACCESS_DENIED) || (nt == SMB2_STATUS_LOGON_FAILURE) ||
        (nt == SMB2_STATUS_WRONG_PASSWORD) || (nt == SMB2_STATUS_ACCOUNT_DISABLED) ||
        (nt == SMB2_STATUS_BAD_NETWORK_NAME) || (rc == -EACCES)) {
        return BACKEND_ERR_AUTH;
    }
    if (rc == -ENOMEM) {
        return BACKEND_ERR_IO;
    }
    drop();
    return BACKEND_ERR_NOT_READY;
}

/*
 * make_path -- build the share-relative path NETSHARE_BASE_PATH/rel in g_path.
 * Steps:
 *   1. Reject NULL and a leading '/' (paths are root-relative).
 *   2. Join base and rel with one '/', omitting it when either is empty;
 *      reject a result that does not fit BACKEND_PATH_BYTES (no truncation).
 * Returns: BACKEND_OK or BACKEND_ERR_ARG.
 */
static backend_status_t make_path(const char *rel)
{
    static const char base[] = NETSHARE_BASE_PATH;
    size_t nb = sizeof(base) - 1u;
    size_t nr;
    size_t sep;

    if ((rel == NULL) || (rel[0] == '/')) {
        return BACKEND_ERR_ARG;
    }
    nr = strlen(rel);
    sep = ((nb > 0u) && (nr > 0u)) ? 1u : 0u;
    if ((nb + sep + nr + 1u) > sizeof(g_path)) {
        return BACKEND_ERR_ARG;
    }
    memcpy(g_path, base, nb);
    if (sep != 0u) {
        g_path[nb] = '/';
    }
    memcpy(&g_path[nb + sep], rel, nr);
    g_path[nb + sep + nr] = '\0';
    return BACKEND_OK;
}

/*
 * configure -- apply netshare_config.h to a fresh context.
 * Steps:
 *   1. NTLMSSP (no Kerberos in this build), user, password, domain (when
 *      not empty), workstation.
 *   2. Dialect, seal, sign, SIGNING_ENABLED security mode, command timeout.
 * Returns: nothing (libsmb2 setters have no failure result).
 */
static void configure(struct smb2_context *smb2)
{
    smb2_set_authentication(smb2, SMB2_SEC_NTLMSSP);
    smb2_set_user(smb2, NETSHARE_USER);
    smb2_set_password(smb2, NETSHARE_PASSWORD);
    if (NETSHARE_DOMAIN[0] != '\0') {
        smb2_set_domain(smb2, NETSHARE_DOMAIN);
    }
    smb2_set_workstation(smb2, BACKEND_SMB_WORKSTATION);
    smb2_set_version(smb2, NETSHARE_SMB_VERSION);
    smb2_set_seal(smb2, NETSHARE_SEAL);
    smb2_set_sign(smb2, NETSHARE_SIGN);
    smb2_set_security_mode(smb2, SMB2_NEGOTIATE_SIGNING_ENABLED);
    smb2_set_timeout(smb2, NETSHARE_TIMEOUT_S);
}

/*
 * backend_smb_init -- reset the backend state (no network traffic).
 * Steps:
 *   1. Clear handles, mark unmounted, status "not mounted".
 * Returns: BACKEND_OK.
 */
backend_status_t backend_smb_init(void)
{
    uint32_t i;

    g_smb2 = NULL;
    g_dir = NULL;
    for (i = 0u; i < BACKEND_MAX_FILES; i++) {
        g_files[i].fh = NULL;
        g_files[i].size = 0u;
        g_files[i].pos = 0u;
    }
    set_status("smb", "not mounted");
    return BACKEND_OK;
}

/*
 * retry_wait -- BACKEND_SMB_RETRY_DELAY_MS between mount attempts, servicing the network and the
 *   drive server (device 9) the whole time.
 * Returns: nothing.
 */
static void retry_wait(void)
{
    const uint32_t t0 = (uint32_t)ik64_uptime_ms64();

    while ((uint32_t)((uint32_t)ik64_uptime_ms64() - t0) < BACKEND_SMB_RETRY_DELAY_MS) {
        ik64_net_service();
        drive_server_idle();
    }
}

/*
 * backend_smb_mount -- connect to NETSHARE_SERVER and tree-connect the share.
 * Steps:
 *   1. Already mounted: BACKEND_OK.
 *   2. Up to BACKEND_SMB_MOUNT_TRIES attempts: new context (NULL = pool
 *      reject: IO), configure, smb2_connect_share.
 *   3. Success: log server, share and the negotiated dialect (never the user name or password).
 *   4. Failure: classify; AUTH ends the loop (retrying cannot fix a
 *      password), otherwise destroy the context, wait
 *      BACKEND_SMB_RETRY_DELAY_MS and retry.
 * Returns: BACKEND_OK, BACKEND_ERR_AUTH, BACKEND_ERR_IO or BACKEND_ERR_NOT_READY.
 */
backend_status_t backend_smb_mount(void)
{
    backend_status_t st = BACKEND_ERR_NOT_READY;
    uint32_t attempt;
    int rc;

    if (g_smb2 != NULL) {
        return BACKEND_OK;
    }
    for (attempt = 0u; attempt < BACKEND_SMB_MOUNT_TRIES; attempt++) {
        g_smb2 = smb2_init_context();
        if (g_smb2 == NULL) {
            set_status("smb2_init_context", "allocation rejected");
            drive_log_printf("SMB: %s\r\n", g_status);
            return BACKEND_ERR_IO;
        }
        configure(g_smb2);
        rc = smb2_connect_share(g_smb2, NETSHARE_SERVER, NETSHARE_SHARE, NETSHARE_USER);
        if (rc == 0) {
            set_status("smb", "OK");
            drive_log_printf("SMB: connected \\\\%s\\%s, dialect 0x%04x\r\n",
                             NETSHARE_SERVER, NETSHARE_SHARE,
                             (unsigned)smb2_get_dialect(g_smb2));
            return BACKEND_OK;
        }
        st = classify("smb2_connect_share", rc);
        drop();
        if (st == BACKEND_ERR_AUTH) {
            break;
        }
        st = BACKEND_ERR_NOT_READY;
        if ((attempt + 1u) < BACKEND_SMB_MOUNT_TRIES) {
            retry_wait();   /* IK64_DEVIATION 11: no RTOS delay */
        }
    }
    return st;
}

/*
 * backend_smb_unmount -- close everything and disconnect.
 * Steps:
 *   1. Not mounted: BACKEND_OK.
 *   2. Close the listing and every open file (results ignored: the session
 *      is going away), smb2_disconnect_share, then drop().
 * Returns: BACKEND_OK.
 */
backend_status_t backend_smb_unmount(void)
{
    uint32_t i;

    if (g_smb2 == NULL) {
        return BACKEND_OK;
    }
    if (g_dir != NULL) {
        smb2_closedir(g_smb2, g_dir);
        g_dir = NULL;
    }
    for (i = 0u; i < BACKEND_MAX_FILES; i++) {
        if (g_files[i].fh != NULL) {
            (void)smb2_close(g_smb2, g_files[i].fh);
            g_files[i].fh = NULL;
        }
    }
    (void)smb2_disconnect_share(g_smb2);
    drop();
    set_status("smb", "not mounted");
    return BACKEND_OK;
}

/*
 * backend_smb_opendir -- open the listing of a root-relative folder.
 * Steps:
 *   1. NOT_READY when unmounted; NO_HANDLE when a listing is open.
 *   2. make_path; smb2_opendir (libsmb2 reads the whole listing here).
 * Returns: BACKEND_OK or the classify / argument status.
 */
backend_status_t backend_smb_opendir(const char *path)
{
    backend_status_t st;

    if (g_smb2 == NULL) {
        return BACKEND_ERR_NOT_READY;
    }
    if (g_dir != NULL) {
        return BACKEND_ERR_NO_HANDLE;
    }
    st = make_path(path);
    if (st != BACKEND_OK) {
        return st;
    }
    g_dir = smb2_opendir(g_smb2, g_path);
    if (g_dir == NULL) {
        return classify("smb2_opendir", 0);
    }
    return BACKEND_OK;
}

/*
 * backend_smb_readdir -- next entry of the open listing.
 * Steps:
 *   1. NOT_READY when unmounted; ARG without a listing or ent.
 *   2. smb2_readdir until an entry that is not "." / ".." and whose name
 *      fits BACKEND_NAME_BYTES; the walk is bounded because the listing is
 *      already in memory and every call consumes one entry.
 *   3. Copy name, size and type (file, directory, other).
 * Returns: BACKEND_OK, BACKEND_END or BACKEND_ERR_*.
 */
backend_status_t backend_smb_readdir(backend_dirent_t *ent)
{
    struct smb2dirent *de;
    size_t n;

    if (g_smb2 == NULL) {
        return BACKEND_ERR_NOT_READY;
    }
    if ((g_dir == NULL) || (ent == NULL)) {
        return BACKEND_ERR_ARG;
    }
    for (;;) {
        de = smb2_readdir(g_smb2, g_dir);
        if (de == NULL) {
            return BACKEND_END;
        }
        if ((strcmp(de->name, ".") == 0) || (strcmp(de->name, "..") == 0)) {
            continue;
        }
        n = strlen(de->name);
        if (n >= sizeof(ent->name)) {
            drive_log_printf("SMB: skipped a %lu-byte name\r\n", (unsigned long)n);
            continue;
        }
        memcpy(ent->name, de->name, n + 1u);
        if (de->st.smb2_type == SMB2_TYPE_DIRECTORY) {
            ent->type = BACKEND_ENT_DIR;
            ent->size = 0u;
        } else if (de->st.smb2_type == SMB2_TYPE_FILE) {
            ent->type = BACKEND_ENT_FILE;
            ent->size = de->st.smb2_size;
        } else {
            ent->type = BACKEND_ENT_OTHER;
            ent->size = 0u;
        }
        return BACKEND_OK;
    }
}

/*
 * backend_smb_closedir -- release the listing.
 * Steps:
 *   1. NOT_READY when unmounted; closing no listing is not an error.
 * Returns: BACKEND_OK or BACKEND_ERR_NOT_READY.
 */
backend_status_t backend_smb_closedir(void)
{
    if (g_smb2 == NULL) {
        return BACKEND_ERR_NOT_READY;
    }
    if (g_dir != NULL) {
        smb2_closedir(g_smb2, g_dir);
        g_dir = NULL;
    }
    return BACKEND_OK;
}

/*
 * backend_smb_open -- open a root-relative file for reading.
 * Steps:
 *   1. NOT_READY when unmounted; ARG on NULL outputs; take a free slot
 *      (NO_HANDLE when all BACKEND_MAX_FILES are in use).
 *   2. make_path; smb2_open(O_RDONLY); smb2_fstat for the length; a
 *      directory is NOT_DIR.
 * Returns: BACKEND_OK (*fh, *size set) or BACKEND_ERR_*.
 */
backend_status_t backend_smb_open(const char *path, backend_file_t *fh, uint64_t *size)
{
    struct smb2_stat_64 st64;
    backend_status_t st;
    uint32_t slot;
    int rc;

    if (g_smb2 == NULL) {
        return BACKEND_ERR_NOT_READY;
    }
    if ((fh == NULL) || (size == NULL)) {
        return BACKEND_ERR_ARG;
    }
    for (slot = 0u; slot < BACKEND_MAX_FILES; slot++) {
        if (g_files[slot].fh == NULL) {
            break;
        }
    }
    if (slot == BACKEND_MAX_FILES) {
        return BACKEND_ERR_NO_HANDLE;
    }
    st = make_path(path);
    if (st != BACKEND_OK) {
        return st;
    }
    g_files[slot].fh = smb2_open(g_smb2, g_path, O_RDONLY);
    if (g_files[slot].fh == NULL) {
        return classify("smb2_open", 0);
    }
    rc = smb2_fstat(g_smb2, g_files[slot].fh, &st64);
    if (rc < 0) {
        st = classify("smb2_fstat", rc);
        if ((g_smb2 != NULL) && (g_files[slot].fh != NULL)) {
            (void)smb2_close(g_smb2, g_files[slot].fh);
        }
        g_files[slot].fh = NULL;
        return st;
    }
    if (st64.smb2_type == SMB2_TYPE_DIRECTORY) {
        (void)smb2_close(g_smb2, g_files[slot].fh);
        g_files[slot].fh = NULL;
        return BACKEND_ERR_NOT_DIR;
    }
    g_files[slot].size = st64.smb2_size;
    g_files[slot].pos = 0u;
    *fh = slot;
    *size = st64.smb2_size;
    return BACKEND_OK;
}

/*
 * backend_smb_read -- read up to max bytes from the current position.
 * Steps:
 *   1. NOT_READY when unmounted; ARG on a bad handle or NULL outputs.
 *   2. At most BACKEND_SMB_READ_MAX_CALLS smb2_read calls, each of at most
 *      min(left, BACKEND_SMB_READ_CHUNK, server max read size, bytes to the
 *      end of the file); a 0-byte result ends the file early.
 *   3. *eof = 1 when the position has reached the length from open.
 * Returns: BACKEND_OK (*got, *eof set) or the classify status.
 */
backend_status_t backend_smb_read(backend_file_t fh, uint8_t *buf, uint32_t max,
                                  uint32_t *got, int *eof)
{
    smb_file_t *f;
    uint32_t done = 0u;
    uint32_t calls;
    uint32_t srv_max;
    int rc;

    if (g_smb2 == NULL) {
        return BACKEND_ERR_NOT_READY;
    }
    if ((fh >= BACKEND_MAX_FILES) || (g_files[fh].fh == NULL) || (buf == NULL) ||
        (got == NULL) || (eof == NULL)) {
        return BACKEND_ERR_ARG;
    }
    f = &g_files[fh];
    srv_max = smb2_get_max_read_size(g_smb2);
    for (calls = 0u; (calls < BACKEND_SMB_READ_MAX_CALLS) && (done < max) && (f->pos < f->size);
         calls++) {
        uint32_t chunk = max - done;
        uint64_t to_end = f->size - f->pos;
        if (chunk > BACKEND_SMB_READ_CHUNK) {
            chunk = BACKEND_SMB_READ_CHUNK;
        }
        if ((srv_max != 0u) && (chunk > srv_max)) {
            chunk = srv_max;
        }
        if ((uint64_t)chunk > to_end) {
            chunk = (uint32_t)to_end;
        }
        rc = smb2_read(g_smb2, f->fh, &buf[done], chunk);
        if (rc < 0) {
            return classify("smb2_read", rc);
        }
        if (rc == 0) {
            f->size = f->pos;   /* the file shrank since open: end here */
            break;
        }
        done += (uint32_t)rc;
        f->pos += (uint64_t)(uint32_t)rc;
    }
    *got = done;
    *eof = (f->pos >= f->size) ? 1 : 0;
    return BACKEND_OK;
}

/*
 * backend_smb_close -- close an open file.
 * Steps:
 *   1. NOT_READY when unmounted; ARG on a bad handle.
 *   2. Free the slot first, then smb2_close; a failure is classified.
 * Returns: BACKEND_OK or the classify status.
 */
backend_status_t backend_smb_close(backend_file_t fh)
{
    struct smb2fh *h;
    int rc;

    if (g_smb2 == NULL) {
        return BACKEND_ERR_NOT_READY;
    }
    if ((fh >= BACKEND_MAX_FILES) || (g_files[fh].fh == NULL)) {
        return BACKEND_ERR_ARG;
    }
    h = g_files[fh].fh;
    g_files[fh].fh = NULL;
    rc = smb2_close(g_smb2, h);
    if (rc < 0) {
        return classify("smb2_close", rc);
    }
    return BACKEND_OK;
}

/*
 * backend_smb_free_bytes -- free space of the volume holding the root.
 * Steps:
 *   1. NOT_READY when unmounted; ARG on NULL.
 *   2. smb2_statvfs on the base path; bytes = f_bavail x f_frsize
 *      (f_bsize when the server leaves f_frsize 0).
 * Returns: BACKEND_OK (*bytes set) or the classify status.
 */
backend_status_t backend_smb_free_bytes(uint64_t *bytes)
{
    struct smb2_statvfs vfs;
    uint32_t unit;
    int rc;

    if (g_smb2 == NULL) {
        return BACKEND_ERR_NOT_READY;
    }
    if (bytes == NULL) {
        return BACKEND_ERR_ARG;
    }
    if (make_path("") != BACKEND_OK) {
        return BACKEND_ERR_ARG;
    }
    rc = smb2_statvfs(g_smb2, g_path, &vfs);
    if (rc < 0) {
        return classify("smb2_statvfs", rc);
    }
    unit = (vfs.f_frsize != 0u) ? vfs.f_frsize : vfs.f_bsize;
    *bytes = vfs.f_bavail * (uint64_t)unit;
    return BACKEND_OK;
}

/*
 * backend_smb_status_text -- copy the last status line.
 * Steps:
 *   1. ARG on NULL or n 0; copy g_status cut to n - 1 characters.
 * Returns: BACKEND_OK or BACKEND_ERR_ARG.
 */
backend_status_t backend_smb_status_text(char *buf, size_t n)
{
    if ((buf == NULL) || (n == 0u)) {
        return BACKEND_ERR_ARG;
    }
    (void)snprintf(buf, n, "%s", g_status);
    return BACKEND_OK;
}

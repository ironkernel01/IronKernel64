/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * smb_host_check.c -- host-side SMB login check using the same libsmb2 and
 * the same settings as fw_1541/src/backend_smb.c.  Credentials come only from
 * netshare_config.h and are never printed.
 *
 * Usage: smb_host_check [sign]    ("sign" forces NETSHARE_SIGN on)
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#ifdef _WIN32
#include <winsock2.h>
#endif
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include "netshare_config.h"

#define WORKSTATION "IK64-1541"

int main(int argc, char **argv)
{
    int force_sign = (argc > 1 && strcmp(argv[1], "sign") == 0);
    int sign = force_sign ? 1 : (int)(NETSHARE_SIGN);
    struct smb2_context *smb2;
    struct smb2dir *dir;
    struct smb2dirent *de;
    int rc;

#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
    printf("server=%s share=%s base=%s sign=%d seal=%d%s\n",
           NETSHARE_SERVER, NETSHARE_SHARE, NETSHARE_BASE_PATH,
           sign, (int)(NETSHARE_SEAL), force_sign ? " (sign forced)" : "");

    smb2 = smb2_init_context();
    if (smb2 == NULL) { printf("FAIL: smb2_init_context\n"); return 2; }
    smb2_set_authentication(smb2, SMB2_SEC_NTLMSSP);
    smb2_set_user(smb2, NETSHARE_USER);
    smb2_set_password(smb2, NETSHARE_PASSWORD);
    if (NETSHARE_DOMAIN[0] != '\0') {
        smb2_set_domain(smb2, NETSHARE_DOMAIN);
    }
    smb2_set_workstation(smb2, WORKSTATION);
    smb2_set_version(smb2, NETSHARE_SMB_VERSION);
    smb2_set_seal(smb2, NETSHARE_SEAL);
    smb2_set_sign(smb2, sign);
    smb2_set_security_mode(smb2, SMB2_NEGOTIATE_SIGNING_ENABLED);
    smb2_set_timeout(smb2, NETSHARE_TIMEOUT_S);

    rc = smb2_connect_share(smb2, NETSHARE_SERVER, NETSHARE_SHARE, NETSHARE_USER);
    printf("dialect=0x%04x\n", (unsigned)smb2_get_dialect(smb2));
    if (rc < 0) {
        printf("FAIL: rc=%d error=\"%s\" nterror=0x%08x\n", rc,
               smb2_get_error(smb2), (unsigned)smb2_get_nterror(smb2));
        smb2_destroy_context(smb2);
        return 1;
    }
    printf("OK: connected\n");
    dir = smb2_opendir(smb2, NETSHARE_BASE_PATH);
    if (dir == NULL) {
        printf("opendir FAIL: error=\"%s\"\n", smb2_get_error(smb2));
    } else {
        while ((de = smb2_readdir(smb2, dir)) != NULL) {
            printf("  %s size=%llu dir=%d\n", de->name,
                   (unsigned long long)de->st.smb2_size,
                   de->st.smb2_type == SMB2_TYPE_DIRECTORY);
        }
        smb2_closedir(smb2, dir);
    }
    smb2_disconnect_share(smb2);
    smb2_destroy_context(smb2);
    return 0;
}

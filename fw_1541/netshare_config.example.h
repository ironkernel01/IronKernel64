/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: netshare_config.example.h
 * Role: the template of fw_1541/netshare_config.h, the compiled-in network
 *   share configuration of core 1 ("1541" drive, SMB backend).
 *
 * Use: copy this file to fw_1541/netshare_config.h and fill in NETSHARE_USER,
 *   NETSHARE_PASSWORD (and NETSHARE_DOMAIN if the NAS needs one).
 *   netshare_config.h is listed in .gitignore and is never committed; the
 *   credentials never go into the repository or any log
 *   (backend_smb.c logs the server, share and user, never the password).
 *   backend_smb.c stops the build with #error when netshare_config.h is
 *   missing or when one of the fields below is not defined.
 *
 * Share: any SMB 2/3 server (a NAS or a PC share); the example below is
 *   \\192.168.1.20\music\C64. lwIP has no NetBIOS name lookup, so the server
 *   is given by IP address.
 */
#ifndef NETSHARE_CONFIG_H
#define NETSHARE_CONFIG_H

/* SMB server: dotted IPv4 address (no NetBIOS/DNS name). */
#define NETSHARE_SERVER         "192.168.1.20"

/* Share name and the folder inside it that the drive shows as its root.
 * Forward slashes; no leading or trailing slash. "" = the share root. */
#define NETSHARE_SHARE          "music"
#define NETSHARE_BASE_PATH      "C64"

/* NTLMSSP credentials (placeholders; fill in netshare_config.h only).
 * NETSHARE_DOMAIN: "" lets the server use its own workgroup/domain; most
 * NAS servers accept "" or "WORKGROUP". */
#define NETSHARE_DOMAIN         ""
#define NETSHARE_USER           "your-nas-user"
#define NETSHARE_PASSWORD       "your-nas-password"

/* Dialect to negotiate, one of libsmb2's enum smb2_negotiate_version:
 *   SMB2_VERSION_ANY  (server picks, 2.02 .. 3.1.1)  <- default
 *   SMB2_VERSION_ANY2 / SMB2_VERSION_ANY3
 *   SMB2_VERSION_0202 / _0210 / _0300 / _0302 / _0311
 * SMB1 is not supported by libsmb2; the NAS must allow SMB2 or later. */
#define NETSHARE_SMB_VERSION    SMB2_VERSION_ANY

/* SMB3 encryption (sealing): 1 = require it (fails against a server that
 * does not negotiate SMB3 encryption), 0 = never use it. Sealing costs an
 * AES-128-CCM pass over every byte in software on core 1. */
#define NETSHARE_SEAL           0

/* Message signing: 1 = require it, 0 = sign only when the server requires
 * it (libsmb2 always advertises SIGNING_ENABLED). */
#define NETSHARE_SIGN           0

/* Command timeout in seconds (libsmb2 smb2_set_timeout; 0 = none). */
#define NETSHARE_TIMEOUT_S      10

/* IP configuration of core 1's netif:
 *   NETSHARE_IP_DHCP   = the RTL DHCP leaf's lease (default);
 *   NETSHARE_IP_STATIC = the three addresses below. */
#define NETSHARE_IP_DHCP        0
#define NETSHARE_IP_STATIC      1
#define NETSHARE_IP_MODE        NETSHARE_IP_DHCP
#define NETSHARE_STATIC_ADDR    "192.168.1.64"
#define NETSHARE_STATIC_NETMASK "255.255.255.0"
#define NETSHARE_STATIC_GATEWAY "192.168.1.1"

#endif /* NETSHARE_CONFIG_H */

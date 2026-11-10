/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: config.h (fw_1541/net/smb2cfg_nosys/)
 * Role: the configuration libsmb2 reads with HAVE_CONFIG_H when it is compiled
 *   in place from third_party/libsmb2/lib for core 1 without an RTOS. Only this
 *   directory holds a config.h on libsmb2's include path.
 *
 * Difference from fw_1541/net/smb2cfg/config.h (the FreeRTOS spike):
 *   - PICO_PLATFORM is NOT defined (it would pull <lwip/sockets.h>, which does
 *     not exist with NO_SYS = 1). The BSD socket names, struct types and
 *     constants libsmb2 uses come from fw_1541/net/ik64_sock.h, which the build
 *     force-includes (-include) into every libsmb2 translation unit, so no
 *     libsmb2 file is edited. IK64_DEVIATION 7 (fw_1541/DEVIATIONS.md).
 *   - HAVE_ARPA_INET_H, HAVE_NETDB_H, HAVE_NETINET_*_H, HAVE_POLL_H,
 *     HAVE_SYS_SOCKET_H, HAVE_SYS_UIO_H are not defined: their content is in
 *     ik64_sock.h (newlib for bare metal ships none of them).
 *   - HAVE_LINGER and HAVE_SOCKADDR_STORAGE: ik64_sock.h declares struct linger
 *     and struct sockaddr_storage.
 *   - HAVE_ERRNO_H, HAVE_FCNTL_H, HAVE_STDINT_H, HAVE_STDIO_H, HAVE_STDLIB_H,
 *     HAVE_STRING_H, HAVE_TIME_H, HAVE_UNISTD_H, HAVE_SYS_TYPES_H,
 *     HAVE_SYS_STAT_H: newlib provides them.
 *   - Kerberos stays off: NTLMSSP only.
 */
#ifndef IK64_SMB2CFG_NOSYS_CONFIG_H
#define IK64_SMB2CFG_NOSYS_CONFIG_H

#define CONFIGURE_OPTION_TCP_LINGER 1

#define HAVE_SOCKADDR_STORAGE 1
#define HAVE_LINGER 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_TIME_H 1
#define HAVE_UNISTD_H 1
#define HAVE_STRING_H 1

#define PACKAGE "libsmb2"
#define PACKAGE_BUGREPORT "ronniesahlberg@gmail.com"
#define PACKAGE_NAME "libsmb2"
#define PACKAGE_STRING "libsmb2 4.0.0"
#define PACKAGE_TARNAME "libsmb2"
#define PACKAGE_URL ""
#define PACKAGE_VERSION "4.0.0"
#define STDC_HEADERS 1
#define VERSION "4.0.0"

#endif /* IK64_SMB2CFG_NOSYS_CONFIG_H */

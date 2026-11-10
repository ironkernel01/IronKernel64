/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: netshare.h
 * Role: the one place that picks core 1's network share configuration (device 8).
 *   - Owner build: fw_1541/netshare_config.h (gitignored, filled in from netshare_config.example.h;
 *     holds the server, share and credentials). The build stops when it is missing.
 *   - PUBLIC build (fw_1541/build.ps1 -Public, defines PUBLIC): only the committed placeholders of
 *     netshare_config.example.h. netshare_config.h is never included, so no server, share, user or
 *     password of the developer reaches a published image; build.ps1 -Public also scans the linked
 *     ELF for the values of netshare_config.h and fails when one is found.
 * Included by: backend_smb.c, main.c (and nothing else).
 */
#ifndef NETSHARE_H
#define NETSHARE_H

#if defined(PUBLIC)
#include "netshare_config.example.h"   /* placeholders only: device 8 is not configured */
#elif defined(__has_include)
#if __has_include("netshare_config.h")
#include "netshare_config.h"
#else
#error "fw_1541/netshare_config.h is missing: copy fw_1541/netshare_config.example.h to fw_1541/netshare_config.h and fill in NETSHARE_USER and NETSHARE_PASSWORD (the file is gitignored and never committed), or build with -Public"
#endif
#else
#include "netshare_config.h"
#endif

#endif /* NETSHARE_H */

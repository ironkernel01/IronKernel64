/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: qspi_format.h
 * Role: the image header that tools/mkqspi.py writes into the configuration flash and the core 1
 *   bootloader (fw_1541/boot/boot.c) reads. One format, two users: keep both in step.
 *
 * Flash map (S25FL256S, 32 MiB, byte offsets):
 *   0x000000  FPGA bitstream (compressed, core 0 firmware and the bootloader merged in the LMBs)
 *   0x1000000 (QSPI_IMG_FLASH_OFS, 16 MiB) this header, 64 bytes, little endian, padded to 4 KiB
 *   0x1001000 core 1 DDR3 image (flat binary of the ELF PT_LOAD segments), then the tune bank
 *             (4 KiB aligned each; offsets in the header are relative to the flash start)
 *
 * Header layout (little endian):
 *    0  magic         8 bytes "IK64QSPI"
 *    8  version       u32, QSPI_IMG_VERSION
 *   12  header_size   u32, 64
 *   16  fw_addr       u32, load address of the core 1 image (DDR3)
 *   20  fw_size       u32, bytes of the core 1 image
 *   24  fw_flash_ofs  u32, flash offset of the core 1 image
 *   28  fw_crc        u32, CRC-32 of the core 1 image
 *   32  entry         u32, entry point (ELF e_entry)
 *   36  bank_addr     u32, destination of the tune bank (C64_PLAT_BANK_BASE)
 *   40  bank_size     u32, bytes of the tune bank (0 = no bank)
 *   44  bank_flash_ofs u32, flash offset of the tune bank
 *   48  bank_crc      u32, CRC-32 of the tune bank
 *   52  reserved      u32, 0
 *   56  build_id      u32, informational (git hash of the packing tree)
 *   60  hdr_crc       u32, CRC-32 over bytes 0..59
 * CRC-32 is the zlib/IEEE one (reflected, polynomial 0xEDB88320, init and final xor 0xFFFFFFFF).
 */
#ifndef QSPI_FORMAT_H
#define QSPI_FORMAT_H

#define QSPI_IMG_FLASH_OFS   (0x01000000u)
#define QSPI_IMG_VERSION     (1u)
#define QSPI_HDR_BYTES       (64u)
#define QSPI_HDR_MAGIC_LO    (0x34364B49u)   /* "IK64" little endian */
#define QSPI_HDR_MAGIC_HI    (0x49505351u)   /* "QSPI" little endian */
#define QSPI_MAX_FW_BYTES    (0x03F00000u)   /* core 1 partition below the bank */
#define QSPI_MAX_BANK_BYTES  (0x00100000u)   /* C64_PLAT_BANK_SIZE */

#endif /* QSPI_FORMAT_H */

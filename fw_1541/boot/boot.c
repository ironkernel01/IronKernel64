/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: boot.c
 * Role: core 1 QSPI bootloader. Lives in core 1's 64 KiB LMB (merged into the bitstream by updatemem),
 *   runs at reset: waits for DDR3 calibration, reads the image header from the configuration flash,
 *   copies the core 1 firmware and the tune bank into DDR3, flushes the caches and jumps to the entry.
 *   A bad or missing header leaves core 1 idle after one log line, so the JTAG development flow
 *   (scripts/jtag_load.ps1 -Core 1: reset the hart, load DDR3) works as before.
 *
 * Owner of: nothing persistent; no .data, no .bss (every variable is a local on the stack).
 * Flash access: core 1's AXI Quad SPI (0x4480_0000, polled, manual chip select, SPI mode 0), flash command
 *   0x13 (READ with 4-byte address) at SCK = 50 MHz, data on one line. The IP is configured for quad
 *   mode but a plain READ4 needs no quad decoding.
 * Log: the text goes into the shared-BRAM log ring (common/drive_proto.h), which core 0 prints with
 *   the [1541] prefix. The ring is reset here; the firmware resets it again when it starts.
 * Bounds: every wait has an iteration limit; a stuck DDR3 or SPI engine ends in a log line and idle.
 * Start-up: after the soft reset the control register is written and read back; one dummy byte is clocked
 *   with no slave selected, since STARTUPE2 drops the first three USRCCLKO cycles after configuration.
 * Build: fw_1541/boot/build.ps1 -> build/fw_1541_boot/boot.elf.
 */
#include <stddef.h>
#include <stdint.h>

#include "c64_platform.h"      /* C64_PLAT_SHM_BASE, C64_PLAT_BANK_* */
#include "drive_proto.h"       /* DRIVE_LOG_* */
#include "../../fw_c64/src/c64_regs.h"   /* C64_SYS_*, C64_WIN1_SYS_OFS */
#include "qspi_format.h"

#define QSPI_BASE        (0x44800000u)
#define QSPI_SRR         (0x40u)
#define QSPI_SPICR       (0x60u)
#define QSPI_SPISR       (0x64u)
#define QSPI_SPIDTR      (0x68u)
#define QSPI_SPIDRR      (0x6Cu)
#define QSPI_SPISSR      (0x70u)
#define SPICR_SPE        (1u << 1)
#define SPICR_MASTER     (1u << 2)
#define SPICR_TXRST      (1u << 5)
#define SPICR_RXRST      (1u << 6)
#define SPICR_MANUAL_SS  (1u << 7)
#define SPISR_RX_EMPTY   (1u << 0)
#define SPISR_TX_FULL    (1u << 3)
#define QSPI_FIFO_DEPTH  (16u)
#define FLASH_CMD_READ4  (0x13u)
#define SPICR_INHIBIT    (1u << 8)
#define SPICR_CHECK_MASK (SPICR_SPE | SPICR_MASTER | SPICR_MANUAL_SS | SPICR_INHIBIT)
#define SRR_SETTLE_READS (16u)          /* >= 16 AXI clocks after the soft reset */
#define STARTUP_DUMMY_BYTES (1u)        /* 8 SCK cycles > the 3 that STARTUPE2 swallows */

#define DDR_WAIT_LOOPS   (30000000u)   /* about 10 s of AXI-Lite reads at 100 MHz */
#define SPI_WAIT_LOOPS   (200000u)
#define CHUNK_BYTES      (4096u)

static inline uint32_t rd(uint32_t addr) { return *(volatile const uint32_t *)addr; }
static inline void wr(uint32_t addr, uint32_t v) { *(volatile uint32_t *)addr = v; }

/* ---- log ring (core 1's console) -------------------------------------------------------------- */
static void log_init(void)
{
    volatile drive_log_t *h = (volatile drive_log_t *)(C64_PLAT_SHM_BASE + DRIVE_LOG_OFS);
    h->magic = 0u;
    h->head = 0u;
    h->tail = 0u;
    h->dropped = 0u;
    __asm volatile("fence" ::: "memory");
    h->magic = DRIVE_LOG_MAGIC;
}

static void log_str(const char *s)
{
    volatile drive_log_t *h = (volatile drive_log_t *)(C64_PLAT_SHM_BASE + DRIVE_LOG_OFS);
    volatile char *t = (volatile char *)(C64_PLAT_SHM_BASE + DRIVE_LOG_OFS + DRIVE_LOG_HDR_BYTES);
    uint32_t head = h->head;
    while (*s != '\0') {
        t[head % DRIVE_LOG_TEXT_BYTES] = *s++;
        head++;
    }
    __asm volatile("fence" ::: "memory");
    h->head = head;
}

static void log_hex(uint32_t v)
{
    char b[11];
    int i;
    b[0] = '0';
    b[1] = 'x';
    for (i = 0; i < 8; i++) {
        b[2 + i] = "0123456789ABCDEF"[(v >> (28 - 4 * i)) & 0xFu];
    }
    b[10] = '\0';
    log_str(b);
}

/* One line: "boot: <what>[ <value>]\n". */
static void log_line(const char *what, int has_val, uint32_t val)
{
    log_str("boot: ");
    log_str(what);
    if (has_val != 0) {
        log_str(" ");
        log_hex(val);
    }
    log_str("\n");
}

/* ---- CRC-32 (zlib), nibble table; the caller handles the init and final xor ------------------- */
static uint32_t crc32_update(uint32_t crc, const uint8_t *p, uint32_t n)
{
    static const uint32_t t[16] = {
        0x00000000u, 0x1DB71064u, 0x3B6E20C8u, 0x26D930ACu, 0x76DC4190u, 0x6B6B51F4u, 0x4DB26158u, 0x5005713Cu,
        0xEDB88320u, 0xF00F9344u, 0xD6D6A3E8u, 0xCB61B38Cu, 0x9B64C2B0u, 0x86D3D2D4u, 0xA00AE278u, 0xBDBDF21Cu };
    uint32_t i;
    for (i = 0u; i < n; i++) {
        crc ^= p[i];
        crc = (crc >> 4) ^ t[crc & 0xFu];
        crc = (crc >> 4) ^ t[crc & 0xFu];
    }
    return crc;
}

/* ---- AXI Quad SPI, polled -------------------------------------------------------------------- */
static int spi_xfer(const uint8_t *tx, uint8_t *rx, uint32_t n);

static int spi_init(void)
{
    const uint32_t cr = SPICR_MASTER | SPICR_SPE | SPICR_MANUAL_SS;
    uint32_t i;
    wr(QSPI_BASE + QSPI_SRR, 0x0Au);                 /* soft reset (PG153: held for 16 AXI clocks) */
    for (i = 0u; i < SRR_SETTLE_READS; i++) {        /* each AXI-Lite read takes several clocks */
        (void)rd(QSPI_BASE + QSPI_SPISR);
    }
    wr(QSPI_BASE + QSPI_SPICR, cr | SPICR_TXRST | SPICR_RXRST);
    if ((rd(QSPI_BASE + QSPI_SPICR) & SPICR_CHECK_MASK) != cr) {   /* the FIFO reset bits self-clear */
        return 0;
    }
    wr(QSPI_BASE + QSPI_SPISSR, 0xFFFFFFFFu);        /* no slave selected */
    for (i = 0u; i < QSPI_FIFO_DEPTH; i++) {         /* drain a stale receive FIFO, bounded */
        if ((rd(QSPI_BASE + QSPI_SPISR) & SPISR_RX_EMPTY) != 0u) {
            break;
        }
        (void)rd(QSPI_BASE + QSPI_SPIDRR);
    }
    if ((rd(QSPI_BASE + QSPI_SPISR) & SPISR_RX_EMPTY) == 0u) {
        return 0;
    }
    /* STARTUPE2 (UG470): the first three USRCCLKO cycles after configuration switch the CCLK source
     * and never reach the pin. Clock one byte with no slave selected so the first command is whole. */
    return spi_xfer(NULL, NULL, STARTUP_DUMMY_BYTES);
}

/* Exchange n bytes: send tx[] (NULL = zeros), store rx[] (NULL = discard). Returns 1 on success. */
static int spi_xfer(const uint8_t *tx, uint8_t *rx, uint32_t n)
{
    uint32_t sent = 0u;
    uint32_t got = 0u;
    uint32_t idle = 0u;
    while (got < n) {
        const uint32_t sr = rd(QSPI_BASE + QSPI_SPISR);
        int moved = 0;
        if ((sent < n) && ((sent - got) < (QSPI_FIFO_DEPTH - 2u)) && ((sr & SPISR_TX_FULL) == 0u)) {
            wr(QSPI_BASE + QSPI_SPIDTR, (tx != NULL) ? (uint32_t)tx[sent] : 0u);
            sent++;
            moved = 1;
        }
        if ((sr & SPISR_RX_EMPTY) == 0u) {
            const uint32_t d = rd(QSPI_BASE + QSPI_SPIDRR);
            if (rx != NULL) {
                rx[got] = (uint8_t)d;
            }
            got++;
            moved = 1;
        }
        if (moved != 0) {
            idle = 0u;
        } else if (++idle > SPI_WAIT_LOOPS) {
            return 0;
        }
    }
    return 1;
}

static void spi_select(int on)
{
    wr(QSPI_BASE + QSPI_SPISSR, (on != 0) ? 0xFFFFFFFEu : 0xFFFFFFFFu);
}

/* Read n bytes at flash offset ofs into dst; the running CRC (if given) is updated over the bytes. */
static int flash_read(uint32_t ofs, uint8_t *dst, uint32_t n, uint32_t *crc)
{
    uint8_t cmd[5];
    uint32_t left = n;
    int ok;
    cmd[0] = FLASH_CMD_READ4;
    cmd[1] = (uint8_t)(ofs >> 24);
    cmd[2] = (uint8_t)(ofs >> 16);
    cmd[3] = (uint8_t)(ofs >> 8);
    cmd[4] = (uint8_t)ofs;
    spi_select(1);
    ok = spi_xfer(cmd, NULL, 5u);
    while ((ok != 0) && (left > 0u)) {
        const uint32_t c = (left > CHUNK_BYTES) ? CHUNK_BYTES : left;
        ok = spi_xfer(NULL, dst, c);
        if ((ok != 0) && (crc != NULL)) {
            *crc = crc32_update(*crc, dst, c);
        }
        dst += c;
        left -= c;
    }
    spi_select(0);
    return ok;
}

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* MicroBlaze V cache maintenance (the BSP's riscv_*_cache.S sequences): invalidate all D-cache lines,
 * flush all I-cache lines (the flush also covers the D-cache); 8 KiB caches, 16-byte lines. */
static void caches_reset(void)
{
    uint32_t a;
    for (a = 0u; a < 8192u; a += 16u) {
        register uint32_t t0 __asm("t0") = a;
        __asm volatile(".long 0x8002A00F" :: "r"(t0) : "memory");   /* cbo.inval (t0), no address check */
    }
    for (a = 0u; a < 8192u; a += 16u) {
        register uint32_t t0 __asm("t0") = a;
        __asm volatile(".long 0x8022A00F" :: "r"(t0) : "memory");   /* cbo.flush (t0), no address check */
    }
    __asm volatile("fence" ::: "memory");
    __asm volatile("fence.i" ::: "memory");
}

static void idle_forever(void)
{
    for (;;) {
        __asm volatile("nop");
    }
}

void boot_main(void)
{
    uint8_t hdr[QSPI_HDR_BYTES];
    uint32_t crc;
    uint32_t i;
    uint32_t entry;
    uint32_t fw_addr;
    uint32_t fw_size;
    uint32_t bank_size;

    log_init();

    /* 1. DDR3 calibration (clk_status bit 1 of core 1's c64_sysregs), bounded. */
    for (i = 0u; i < DDR_WAIT_LOOPS; i++) {
        if (((rd(C64_PLAT_WIN1_BASE + C64_WIN1_SYS_OFS + C64_SYS_CLK_STATUS_OFS) >> C64_SYS_CLK_DDR_CALIB_BIT) & 1u) != 0u) {
            break;
        }
    }
    if (i == DDR_WAIT_LOOPS) {
        log_line("DDR3 not calibrated, idle", 0, 0u);
        idle_forever();
    }

    /* 2. header */
    if (spi_init() == 0) {
        log_line("QSPI controller not ready, idle", 0, 0u);
        idle_forever();
    }
    if (flash_read(QSPI_IMG_FLASH_OFS, hdr, QSPI_HDR_BYTES, NULL) == 0) {
        log_line("QSPI read failed, idle", 0, 0u);
        idle_forever();
    }
    if ((le32(&hdr[0]) != QSPI_HDR_MAGIC_LO) || (le32(&hdr[4]) != QSPI_HDR_MAGIC_HI)) {
        log_line("no image header in flash (JTAG flow), idle", 0, 0u);
        idle_forever();
    }
    crc = crc32_update(0xFFFFFFFFu, hdr, 60u) ^ 0xFFFFFFFFu;
    if ((le32(&hdr[8]) != QSPI_IMG_VERSION) || (le32(&hdr[12]) != QSPI_HDR_BYTES) || (crc != le32(&hdr[60]))) {
        log_line("bad image header (version or CRC), idle", 0, 0u);
        idle_forever();
    }
    fw_addr = le32(&hdr[16]);
    fw_size = le32(&hdr[20]);
    entry = le32(&hdr[32]);
    bank_size = le32(&hdr[40]);
    if ((fw_size == 0u) || (fw_size > QSPI_MAX_FW_BYTES) || (fw_addr < C64_PLAT_DDR_CORE1_BASE) ||
        ((fw_addr - C64_PLAT_DDR_CORE1_BASE) > (C64_PLAT_BANK_BASE - C64_PLAT_DDR_CORE1_BASE - fw_size)) ||
        (entry < fw_addr) || (entry >= (fw_addr + fw_size)) ||
        (bank_size > QSPI_MAX_BANK_BYTES) || ((bank_size != 0u) && (le32(&hdr[36]) != C64_PLAT_BANK_BASE))) {
        log_line("image header out of range, idle", 0, 0u);
        idle_forever();
    }

    /* 3. copy the firmware image, then the bank; the CRC runs over the bytes as they pass through. */
    crc = 0xFFFFFFFFu;
    if (flash_read(le32(&hdr[24]), (uint8_t *)fw_addr, fw_size, &crc) == 0) {
        log_line("QSPI read failed (firmware), idle", 0, 0u);
        idle_forever();
    }
    if ((crc ^ 0xFFFFFFFFu) != le32(&hdr[28])) {
        log_line("firmware CRC mismatch, idle", 0, 0u);
        idle_forever();
    }
    if (bank_size != 0u) {
        crc = 0xFFFFFFFFu;
        if (flash_read(le32(&hdr[44]), (uint8_t *)C64_PLAT_BANK_BASE, bank_size, &crc) == 0) {
            log_line("QSPI read failed (bank), idle", 0, 0u);
            idle_forever();
        }
        if ((crc ^ 0xFFFFFFFFu) != le32(&hdr[48])) {
            log_line("tune bank CRC mismatch, idle", 0, 0u);
            idle_forever();
        }
    }

    /* 4. caches and jump. The firmware resets the log ring itself. */
    log_line("image loaded, starting at", 1, entry);
    caches_reset();
    ((void (*)(void))entry)();
    idle_forever();
}

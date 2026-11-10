/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: cli_cmds.c
 * Role: callbacks of the generated engineering CLI menu (fw_c64/cli/cli_commands.txt).
 *   Output goes through the cli.h helpers (ring, never blocks). Commands marked idle in the
 *   command file are refused while a tune plays (cli_refuse_if_playing).
 */
#include <stddef.h>
#include <stdint.h>

#include "adau1761.h"
#include "audio_out.h"
#include "basic.h"
#include "c64_platform.h"
#include "c64_regs.h"
#include "cli.h"
#include "drive_client.h"
#include "keyboard.h"
#include "menu.h"
#include "player.h"
#include "sidbus_fabric.h"
#include "video.h"

#include "xil_io.h" /* Xil_In32 */

#define SYS_REG(ofs)   (C64_PLAT_WIN0_BASE + C64_WIN_SYS_OFS + (uint32_t)(ofs))
#define SYS_DIRTY_MASK (1u << 0)
#define PAL_INDEX_MAX  (15u)
#define RGB_MAX        (0xFFFFFFu)
#define MS_PER_SEC     (1000u)

/*
 * parse_arg -- parse argument i as a number with an upper bound.
 * Returns: 1 and *out set, or 0 after printing "Bad value for <name>".
 */
static int parse_arg(const MenuCommandContext *ctx, int i, uint32_t lo, uint32_t hi,
                     const char *name, uint32_t *out)
{
    unsigned long v = 0ul;

    if (i < ctx->argc && Menu_ParseU32(ctx->argv[i], &v) && v >= lo && v <= hi) {
        *out = (uint32_t)v;
        return 1;
    }
    menu_write("Bad value for ");
    menu_write(name);
    menu_write("\n");
    return 0;
}

/*
 * yn -- "yes" / "no" text of a flag.
 * Returns: a fixed string.
 */
static const char *yn(uint32_t flag)
{
    return (flag != 0u) ? "yes" : "no";
}

/*
 * cli_version -- VERSION: build ID, dirty flag, clock lock and link status bits.
 * Returns: 0.
 */
int cli_version(const MenuCommandContext *ctx)
{
    const uint32_t clk = Xil_In32(SYS_REG(C64_SYS_CLK_STATUS_OFS));

    (void)ctx;
    menu_write("IronKernel 64 core 0, build ");
    cli_put_hex(Xil_In32(SYS_REG(C64_SYS_BUILD_ID_OFS)), 8u);
    menu_write(((Xil_In32(SYS_REG(C64_SYS_BUILD_FLAGS_OFS)) & SYS_DIRTY_MASK) != 0u) ? " dirty\n" : "\n");
    menu_write("pix clock locked: ");
    menu_write(yn((clk >> C64_SYS_CLK_PIX_LOCKED_BIT) & 1u));
    menu_write(", audio clock locked: ");
    menu_write(yn((clk >> C64_SYS_CLK_AUD_LOCKED_BIT) & 1u));
    menu_write(", DDR3 calibrated: ");
    menu_write(yn((clk >> C64_SYS_CLK_DDR_CALIB_BIT) & 1u));
    menu_write("\nHDMI hot plug: ");
    menu_write(yn((clk >> C64_SYS_CLK_HDMI_HPD_BIT) & 1u));
    menu_write(", Ethernet link: ");
    menu_write(yn((clk >> C64_SYS_CLK_ETH_LINK_BIT) & 1u));
    menu_write("\n");
    return 0;
}

/*
 * cli_ddr_info -- DDR INFO: result of the boot-time DDR3 probe.
 * Returns: 0.
 */
int cli_ddr_info(const MenuCommandContext *ctx)
{
    const ddr_probe_result_t *d = cli_ddr();

    (void)ctx;
    cli_put_kv("calib_ms", d->calib_ms);
    cli_put_kv("size_KiB", d->size_bytes / 1024u);
    cli_put_kv("free_KiB", d->free_bytes / 1024u);
    cli_put_kv("pattern_errors", d->pattern_errors);
    menu_write("\n");
    if (d->pattern_errors != 0u) {
        menu_write("first bad address ");
        cli_put_hex(d->first_bad_addr, 8u);
        menu_write("\n");
    }
    return 0;
}

/*
 * cli_sid_status -- SID STATUS: current tune, time, voice levels, player counters.
 * Returns: 0.
 */
int cli_sid_status(const MenuCommandContext *ctx)
{
    (void)ctx;
    if (!basic_playing()) {
        menu_write("No tune playing\n");
    } else {
        basic_tune_info_t info;
        uint8_t lvl[BASIC_VOICES];
        uint32_t i;
        const uint32_t secs = g_player_ops.elapsed_ms() / MS_PER_SEC;
        char one[2] = { '\0', '\0' };

        g_player_ops.info(&info);
        g_player_ops.voice_levels(lvl);
        menu_write("tune ");
        for (i = 0u; i < BASIC_TUNE_TEXT_BYTES && info.name[i] != '\0'; i++) {
            one[0] = (info.name[i] >= ' ' && info.name[i] < 0x7F) ? info.name[i] : '?';
            menu_write(one);
        }
        menu_write("\n");
        cli_put_kv("song", info.start_song);
        cli_put_kv("of", info.songs);
        cli_put_kv("elapsed_s", secs);
        menu_write("\nvoice levels");
        for (i = 0u; i < BASIC_VOICES; i++) {
            menu_write(" ");
            cli_put_u32(lvl[i]);
        }
        menu_write("\n");
    }
    cli_put_kv("resyncs", player_resyncs());
    cli_put_kv("errors", player_errors());
    cli_put_kv("sid_dropped", sidbus_fabric_dropped());
    menu_write("\n");
    return 0;
}

/*
 * cli_audio_status -- AUDIO STATUS: FIFO level, threshold, underruns, flags.
 * Returns: 0.
 */
int cli_audio_status(const MenuCommandContext *ctx)
{
    const uint32_t st = audio_out_status();

    (void)ctx;
    cli_put_kv("level", audio_out_level());
    cli_put_kv("space", audio_out_space());
    cli_put_kv("threshold", AUDIO_OUT_THRESHOLD);
    cli_put_kv("underruns", audio_out_underruns());
    menu_write("\nstatus ");
    cli_put_hex(st, 2u);
    menu_write(" irq=");
    menu_write(yn((st >> C64_AUD_STATUS_IRQ_BIT) & 1u));
    menu_write(" underrun=");
    menu_write(yn((st >> C64_AUD_STATUS_UNDERRUN_BIT) & 1u));
    menu_write(" full=");
    menu_write(yn((st >> C64_AUD_STATUS_FULL_BIT) & 1u));
    menu_write("\n");
    return 0;
}

/*
 * cli_codec_read -- CODEC READ [REG]: one ADAU1761 register (one bounded I2C transfer).
 * Returns: 0, or -1 on a bad argument or an I2C failure.
 */
int cli_codec_read(const MenuCommandContext *ctx)
{
    uint32_t reg;
    uint8_t val = 0u;
    int rc;

    if (!parse_arg(ctx, 0, ADAU1761_REG_FIRST, ADAU1761_REG_LAST, "REG", &reg)) {
        return -1;
    }
    rc = adau1761_read((uint16_t)reg, &val);
    if (rc != 0) {
        menu_write("I2C read failed, code ");
        cli_put_u32((uint32_t)rc);
        menu_write("\n");
        return -1;
    }
    cli_put_hex(reg, 4u);
    menu_write(" = ");
    cli_put_hex(val, 2u);
    menu_write("\n");
    return 0;
}

/*
 * cli_codec_write -- CODEC WRITE [REG] [VALUE] (idle): write one ADAU1761 register.
 * Returns: 0, or -1 when refused, on a bad argument or an I2C failure.
 */
int cli_codec_write(const MenuCommandContext *ctx)
{
    uint32_t reg;
    uint32_t val;
    int rc;

    if (cli_refuse_if_playing()) {
        return -1;
    }
    if (!parse_arg(ctx, 0, ADAU1761_REG_FIRST, ADAU1761_REG_LAST, "REG", &reg) ||
        !parse_arg(ctx, 1, 0u, 0xFFu, "VALUE", &val)) {
        return -1;
    }
    rc = adau1761_write((uint16_t)reg, (uint8_t)val);
    if (rc != 0) {
        menu_write("I2C write failed, code ");
        cli_put_u32((uint32_t)rc);
        menu_write("\n");
        return -1;
    }
    menu_write("written\n");
    return 0;
}

/*
 * put_drive_line -- print the DOS status line of the last drive reply.
 * Returns: nothing.
 */
static void put_drive_line(void)
{
    char text[48];

    drive_client_last_text(text, sizeof(text));
    menu_write("DOS status: ");
    menu_write(text);
    menu_write("\n");
}

/*
 * cli_drive_status -- DRIVE STATUS (idle): ping devices 8 and 9, show the DOS status of 8.
 * The selected device of drive_client is restored. Each ping is bounded by
 * DRIVE_CLIENT_PING_TIMEOUT_MS, the status request by DRIVE_CLIENT_OP_TIMEOUT_MS.
 * Returns: 0, or -1 when refused.
 */
int cli_drive_status(const MenuCommandContext *ctx)
{
    const uint8_t keep = drive_client_device();

    (void)ctx;
    if (cli_refuse_if_playing()) {
        return -1;
    }
    menu_write("device 8: ");
    menu_write((drive_client_ping_device(DRIVE_DEVICE_SMB) == DRIVE_CLIENT_OK) ? "present" : "not answering");
    menu_write(", device 9: ");
    menu_write((drive_client_ping_device(DRIVE_DEVICE_BANK) == DRIVE_CLIENT_OK) ? "present" : "not answering");
    menu_write("\n");
    drive_client_set_device(DRIVE_DEVICE_SMB);
    (void)drive_client_status();
    put_drive_line();
    drive_client_set_device(keep);
    return 0;
}

/*
 * cli_drive_cmd -- DRIVE CMD [TEXT] (idle): one DOS command on channel 15 of device 8.
 * Returns: 0, or -1 when refused or the drive reports a failure.
 */
int cli_drive_cmd(const MenuCommandContext *ctx)
{
    const uint8_t keep = drive_client_device();
    drive_client_result_t r;

    if (cli_refuse_if_playing()) {
        return -1;
    }
    drive_client_set_device(DRIVE_DEVICE_SMB);
    r = drive_client_cmd(ctx->argv[0]);
    if (r == DRIVE_CLIENT_TIMEOUT) {
        menu_write("device not present\n");
    } else {
        put_drive_line();
    }
    drive_client_set_device(keep);
    return (r == DRIVE_CLIENT_OK) ? 0 : -1;
}

/*
 * cli_video_status -- VIDEO STATUS: frame and vsync counters, page and flip state.
 * Returns: 0.
 */
int cli_video_status(const MenuCommandContext *ctx)
{
    (void)ctx;
    cli_put_kv("frame", video_frame_counter());
    cli_put_kv("vsync", video_vsync_count());
    cli_put_kv("front_page", video_front_page());
    cli_put_kv("back_page", video_back_page());
    cli_put_kv("flip_pending", (uint32_t)video_flip_pending());
    menu_write("\n");
    return 0;
}

/*
 * cli_video_palette -- VIDEO PALETTE [INDEX] [RGB]: set one palette entry.
 * Returns: 0, or -1 on a bad argument.
 */
int cli_video_palette(const MenuCommandContext *ctx)
{
    uint32_t idx;
    uint32_t rgb;

    if (!parse_arg(ctx, 0, 0u, PAL_INDEX_MAX, "INDEX", &idx) || !parse_arg(ctx, 1, 0u, RGB_MAX, "RGB", &rgb)) {
        return -1;
    }
    video_set_palette(idx, rgb);
    cli_put_u32(idx);
    menu_write(" = ");
    cli_put_hex(rgb, 6u);
    menu_write("\n");
    return 0;
}

/*
 * cli_keyboard_stats -- KEYBOARD STATS: drop and error counters of the key decoders.
 * Returns: 0.
 */
int cli_keyboard_stats(const MenuCommandContext *ctx)
{
    keyboard_stats_t s;

    (void)ctx;
    keyboard_get_stats(&s);
    cli_put_kv("keys_dropped", s.keys_dropped);
    cli_put_kv("raw_dropped", s.raw_dropped);
    cli_put_kv("ps2_errors", s.ps2_errors);
    cli_put_kv("uart_errors", s.uart_errors);
    menu_write("\n");
    return 0;
}

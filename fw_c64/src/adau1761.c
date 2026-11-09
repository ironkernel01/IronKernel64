/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: adau1761.c
 * Role: ADAU1761 codec bring-up for playback (contract in adau1761.h).
 *
 * Ownership: this file is the only one that uses the IIC path (axi_iic_0). It reads the
 *   core 0 c64_sysregs CLK_STATUS register read-only for the audio MMCM lock.
 *
 * IIC transfers: the instance is set up with XIic_LookupConfig / XIic_CfgInitialize and the
 *   core is reset and enabled for dynamic mode with XIic_DynInit (all fail-stop). The
 *   transfers themselves drive the AXI IIC dynamic-mode TX FIFO through the driver's
 *   register macros (xiic_l.h), because the driver's polled XIic_Send/XIic_Recv and
 *   XIic_DynSend/XIic_DynRecv wait in unbounded loops (while (1) in DynSendData and
 *   DynRecvData); here every wait is bounded by ADAU1761_XFER_TIMEOUT_US.
 *   Write:  [START|addr<<1|W] [reg hi] [reg lo] [STOP|data]
 *   Read:   [START|addr<<1|W] [reg hi] [reg lo] [START|addr<<1|R] [STOP|count=1], then DRR.
 *
 * Register sequence (ADAU1761 data sheet Rev. C register map, R0 = 0x4000 ...; values cross-
 *   checked against Digilent's Nexys Video DMA audio demo, sdk/appsrc/audio/audio.c,
 *   https://github.com/Digilent/Nexys-Video-DMA commit b2ff760f, and the Linux driver
 *   sound/soc/codecs/adau1761.c / adau17x1.h for the bit names):
 *     R0  0x4000 = 0x01  clock control: COREN=1, INFREQ=00 (256 x fs), CLKSRC=0 (MCLK pin,
 *                       no PLL). Digilent uses the PLL (0x0E/0x0F with R1); we feed exactly
 *                       256 x 48 kHz = 12.288 MHz, so the PLL stays off.
 *     R15 0x4015 = 0x00  serial port 0: slave (MS=0), stereo, LRCLK 50 % duty, normal
 *                       polarities. Digilent writes 0x01 (codec master); here the FPGA
 *                       drives BCLK/LRCLK.
 *     R16 0x4016 = 0x00  serial port 1: 64 BCLK per frame, MSB first, LRCLK-to-data delay
 *                       1 BCLK (I2S).
 *     R17 0x4017 = 0x00  converter 0: CONVSR = fs (48 kHz).
 *     R64 0x40F8 = 0x00  serial port sampling rate = fs (48 kHz).
 *     R36 0x402A = 0x03  DAC control 0: both DACs on.
 *     R35 0x4029 = 0x03  playback power management: left and right playback on.
 *     R58 0x40F2 = 0x01  serial input route: serial L0/R0 to the DACs.
 *     R65 0x40F9 = 0x7F  clock enable 0 (as Digilent).
 *     R66 0x40FA = 0x03  clock enable 1 (as Digilent).
 *     R22 0x401C = 0x21  playback mixer left: MX3EN, left DAC unmuted (MX3LM).
 *     R23 0x401D = 0x00  playback mixer left 1: record-path bypass muted.
 *     R24 0x401E = 0x41  playback mixer right: MX4EN, right DAC unmuted (MX4RM).
 *     R25 0x401F = 0x00  playback mixer right 1: bypass muted.
 *     R26 0x4020 = 0x03  L/R mixer left (line out L): MX5EN, left mixer at 0 dB.
 *     R27 0x4021 = 0x09  L/R mixer right (line out R): MX6EN, right mixer at 0 dB.
 *     R28 0x4022 = 0x01  mono mixer on: headphone virtual ground (Linux "Headphone VGND").
 *     R29 0x4023 = 0xE7  headphone L: 0 dB (LHPVOL=0x39), unmuted, HPEN=1.
 *     R30 0x4024 = 0xE7  headphone R: 0 dB, unmuted, HPMODE=1 (headphone output).
 *     R31 0x4025 = 0xE6  line out L: 0 dB, unmuted, line mode.
 *     R32 0x4026 = 0xE6  line out R: 0 dB, unmuted, line mode.
 *     R33 0x4027 = 0x03  mono output: unmuted, headphone (VGND) mode, as Digilent. (VERIFY
 *                       against the Nexys Video schematic that MONOOUT is J3's return.)
 *     R34 0x4028 = 0x00  pop/click suppression as Digilent.
 *     R67 0x4036 = 0x00 then 0x03  dejitter reset after the power changes (Linux
 *                       adau1761_dejitter_fixup, slave mode); not read back.
 */
#include "adau1761.h"

#include "c64_platform.h"
#include "c64_regs.h"

#include "sleep.h"          /* usleep (bounded waits) */
#include "xiic.h"           /* XIic, XIic_LookupConfig, XIic_CfgInitialize */
#include "xiic_l.h"         /* XIic_DynInit, register offsets and masks */
#include "xil_exception.h"  /* Xil_ExceptionDisable (fail-stop park) */
#include "xil_io.h"         /* Xil_In32 */
#include "xil_printf.h"     /* xil_printf (fail-stop report) */
#include "xparameters.h"    /* XPAR_AXI_IIC_0_BASEADDR */
#include "xstatus.h"        /* XST_SUCCESS */

#define ADAU_IIC_BASE        (XPAR_AXI_IIC_0_BASEADDR)
#define ADAU_SYS_STATUS      (C64_PLAT_WIN0_BASE + C64_WIN_SYS_OFS + C64_SYS_CLK_STATUS_OFS)
#define ADAU_POLL_US         (10u)
#define ADAU_XFER_POLLS      (ADAU1761_XFER_TIMEOUT_US / ADAU_POLL_US)
#define ADAU_MCLK_POLL_US    (100u)
#define ADAU_MCLK_POLLS      (ADAU1761_MCLK_TIMEOUT_MS * (1000u / ADAU_MCLK_POLL_US))
#define ADAU_CORE_SETTLE_US  (1000u)
#define ADAU_ADDR_W          (ADAU1761_I2C_ADDR << 1)
#define ADAU_ADDR_R          ((ADAU1761_I2C_ADDR << 1) | 1u)
#define ADAU_ISR_ERRORS      (XIIC_INTR_ARB_LOST_MASK | XIIC_INTR_TX_ERROR_MASK)
#define ADAU_ISR_ALL         (ADAU_ISR_ERRORS | XIIC_INTR_TX_EMPTY_MASK | XIIC_INTR_BNB_MASK)

#define ADAU_R0_CLOCK_CTRL   (0x4000u)
#define ADAU_R15_SERIAL0     (0x4015u)
#define ADAU_R16_SERIAL1     (0x4016u)
#define ADAU_R17_CONVERTER0  (0x4017u)
#define ADAU_R22_PMIX_L0     (0x401Cu)
#define ADAU_R23_PMIX_L1     (0x401Du)
#define ADAU_R24_PMIX_R0     (0x401Eu)
#define ADAU_R25_PMIX_R1     (0x401Fu)
#define ADAU_R26_LRMIX_L     (0x4020u)
#define ADAU_R27_LRMIX_R     (0x4021u)
#define ADAU_R28_LRMIX_MONO  (0x4022u)
#define ADAU_R29_HP_L        (0x4023u)
#define ADAU_R30_HP_R        (0x4024u)
#define ADAU_R31_LOUT_L      (0x4025u)
#define ADAU_R32_LOUT_R      (0x4026u)
#define ADAU_R33_MONO_OUT    (0x4027u)
#define ADAU_R34_POP_CLICK   (0x4028u)
#define ADAU_R35_PLAY_PWR    (0x4029u)
#define ADAU_R36_DAC_CTRL0   (0x402Au)
#define ADAU_R58_SIN_ROUTE   (0x40F2u)
#define ADAU_R64_SP_RATE     (0x40F8u)
#define ADAU_R65_CLK_EN0     (0x40F9u)
#define ADAU_R66_CLK_EN1     (0x40FAu)
#define ADAU_R67_DEJITTER    (0x4036u)
#define ADAU_DEJITTER_ON     (0x03u)

/* Transfer failure codes (printed by the fail-stop path). */
#define ADAU_ERR_BUSY        (1)
#define ADAU_ERR_NACK        (2)
#define ADAU_ERR_ARB         (3)
#define ADAU_ERR_TIMEOUT     (4)

typedef struct
{
    uint16_t reg;
    uint8_t  value;
} adau_write_t;

/* Playback set-up, in order (meaning of each value: file header). */
static const adau_write_t g_setup[] = {
    { ADAU_R0_CLOCK_CTRL,  0x01u },
    { ADAU_R15_SERIAL0,    0x00u },
    { ADAU_R16_SERIAL1,    0x00u },
    { ADAU_R17_CONVERTER0, 0x00u },
    { ADAU_R64_SP_RATE,    0x00u },
    { ADAU_R36_DAC_CTRL0,  0x03u },
    { ADAU_R35_PLAY_PWR,   0x03u },
    { ADAU_R58_SIN_ROUTE,  0x01u },
    { ADAU_R65_CLK_EN0,    0x7Fu },
    { ADAU_R66_CLK_EN1,    0x03u },
    { ADAU_R22_PMIX_L0,    0x21u },
    { ADAU_R23_PMIX_L1,    0x00u },
    { ADAU_R24_PMIX_R0,    0x41u },
    { ADAU_R25_PMIX_R1,    0x00u },
    { ADAU_R26_LRMIX_L,    0x03u },
    { ADAU_R27_LRMIX_R,    0x09u },
    { ADAU_R28_LRMIX_MONO, 0x01u },
    { ADAU_R29_HP_L,       0xE7u },
    { ADAU_R30_HP_R,       0xE7u },
    { ADAU_R31_LOUT_L,     0xE6u },
    { ADAU_R32_LOUT_R,     0xE6u },
    { ADAU_R33_MONO_OUT,   0x03u },
    { ADAU_R34_POP_CLICK,  0x00u }
};

static XIic g_iic;

/*
 * adau_fail -- fail-stop: report the failing step and park.
 * Steps:
 *   1. Print what failed, the register, the written and read values and the code.
 *   2. Disable interrupts and park the CPU.
 * Returns: never.
 */
static void adau_fail(const char *what, uint16_t reg, uint8_t wrote, uint8_t read, int code)
{
    xil_printf("FATAL adau1761: %s reg 0x%04x wrote 0x%02x read 0x%02x code %d\r\n",
               what, (unsigned)reg, (unsigned)wrote, (unsigned)read, code);
    Xil_ExceptionDisable();
    for (;;) {
    }
}

/*
 * iic_rd -- read an AXI IIC register.
 * Returns: the register value.
 */
static uint32_t iic_rd(uint32_t ofs)
{
    return XIic_ReadReg(ADAU_IIC_BASE, ofs);
}

/*
 * iic_wr -- write an AXI IIC register.
 * Returns: nothing.
 */
static void iic_wr(uint32_t ofs, uint32_t value)
{
    XIic_WriteReg(ADAU_IIC_BASE, ofs, value);
}

/*
 * iic_wait_sr -- wait until (SR & mask) == want, bounded by ADAU1761_XFER_TIMEOUT_US.
 * Returns: 0 reached, ADAU_ERR_ARB on arbitration loss, ADAU_ERR_TIMEOUT.
 */
static int iic_wait_sr(uint32_t mask, uint32_t want)
{
    for (uint32_t i = 0u; i < ADAU_XFER_POLLS; i++) {
        if ((iic_rd(XIIC_SR_REG_OFFSET) & mask) == want) {
            return 0;
        }
        if ((XIic_ReadIisr(ADAU_IIC_BASE) & XIIC_INTR_ARB_LOST_MASK) != 0u) {
            return ADAU_ERR_ARB;
        }
        usleep(ADAU_POLL_US);
    }
    return ADAU_ERR_TIMEOUT;
}

/*
 * iic_start -- common start of a transfer.
 * Steps:
 *   1. Wait for the bus to be free (bounded).
 *   2. Reset the TX FIFO, empty the RX FIFO (at most its depth), clear the latched
 *      interrupt status bits used below.
 * Returns: 0 ready, or ADAU_ERR_BUSY.
 */
static int iic_start(void)
{
    if (iic_wait_sr(XIIC_SR_BUS_BUSY_MASK, 0u) != 0) {
        return ADAU_ERR_BUSY;
    }
    iic_wr(XIIC_CR_REG_OFFSET, XIIC_CR_ENABLE_DEVICE_MASK | XIIC_CR_TX_FIFO_RESET_MASK);
    iic_wr(XIIC_CR_REG_OFFSET, XIIC_CR_ENABLE_DEVICE_MASK);
    for (uint32_t i = 0u; i < IIC_RX_FIFO_DEPTH; i++) {
        if ((iic_rd(XIIC_SR_REG_OFFSET) & XIIC_SR_RX_FIFO_EMPTY_MASK) != 0u) {
            break;
        }
        (void)iic_rd(XIIC_DRR_REG_OFFSET);
    }
    XIic_ClearIisr(ADAU_IIC_BASE, ADAU_ISR_ALL);
    return 0;
}

/*
 * iic_finish -- wait for the STOP to complete.
 * Steps:
 *   1. Wait until the bus is busy (the queued START went out), then clear the latched
 *      bus-not-busy bit.
 *   2. Poll the interrupt status: arbitration loss or (writes only) a NACK fails;
 *      bus-not-busy ends the transfer. All waits bounded.
 * Returns: 0 done, or an ADAU_ERR_* code.
 */
static int iic_finish(int check_nack)
{
    int r = iic_wait_sr(XIIC_SR_BUS_BUSY_MASK, XIIC_SR_BUS_BUSY_MASK);

    if (r != 0) {
        return r;
    }
    XIic_ClearIisr(ADAU_IIC_BASE, XIIC_INTR_BNB_MASK);
    for (uint32_t i = 0u; i < ADAU_XFER_POLLS; i++) {
        uint32_t isr = XIic_ReadIisr(ADAU_IIC_BASE);
        if ((isr & XIIC_INTR_ARB_LOST_MASK) != 0u) {
            return ADAU_ERR_ARB;
        }
        if (check_nack && (isr & XIIC_INTR_TX_ERROR_MASK) != 0u) {
            iic_wr(XIIC_CR_REG_OFFSET, XIIC_CR_ENABLE_DEVICE_MASK | XIIC_CR_TX_FIFO_RESET_MASK);
            iic_wr(XIIC_CR_REG_OFFSET, XIIC_CR_ENABLE_DEVICE_MASK);
            return ADAU_ERR_NACK;
        }
        if ((isr & XIIC_INTR_BNB_MASK) != 0u) {
            return 0;
        }
        usleep(ADAU_POLL_US);
    }
    return ADAU_ERR_TIMEOUT;
}

/*
 * adau1761_write -- write one codec register.
 * Steps:
 *   1. Start; queue START+address(W), register high, register low, STOP+data.
 *   2. Wait for the end of the transfer (NACK checked).
 * Returns: 0 on success, or an ADAU_ERR_* code.
 */
int adau1761_write(uint16_t reg, uint8_t value)
{
    int r = iic_start();

    if (r != 0) {
        return r;
    }
    iic_wr(XIIC_DTR_REG_OFFSET, XIIC_TX_DYN_START_MASK | ADAU_ADDR_W);
    iic_wr(XIIC_DTR_REG_OFFSET, (uint32_t)(reg >> 8));
    iic_wr(XIIC_DTR_REG_OFFSET, (uint32_t)(reg & 0xFFu));
    iic_wr(XIIC_DTR_REG_OFFSET, XIIC_TX_DYN_STOP_MASK | value);
    return iic_finish(1);
}

/*
 * adau1761_read -- read one codec register.
 * Steps:
 *   1. Start; queue START+address(W), register high, register low, repeated START+
 *      address(R), STOP + byte count 1.
 *   2. Wait for the byte in the RX FIFO (bounded), read it, wait for the STOP. The
 *      master's NACK of the last byte sets TX_ERROR, so NACK is not checked; a slave NACK
 *      earlier shows up as a missing byte (timeout).
 * Returns: 0 and *value set, or an ADAU_ERR_* code.
 */
int adau1761_read(uint16_t reg, uint8_t *value)
{
    int r = iic_start();

    if (r != 0) {
        return r;
    }
    iic_wr(XIIC_DTR_REG_OFFSET, XIIC_TX_DYN_START_MASK | ADAU_ADDR_W);
    iic_wr(XIIC_DTR_REG_OFFSET, (uint32_t)(reg >> 8));
    iic_wr(XIIC_DTR_REG_OFFSET, (uint32_t)(reg & 0xFFu));
    iic_wr(XIIC_DTR_REG_OFFSET, XIIC_TX_DYN_START_MASK | ADAU_ADDR_R);
    iic_wr(XIIC_DTR_REG_OFFSET, XIIC_TX_DYN_STOP_MASK | 1u);
    r = iic_wait_sr(XIIC_SR_RX_FIFO_EMPTY_MASK, 0u);
    if (r != 0) {
        return r;
    }
    *value = (uint8_t)iic_rd(XIIC_DRR_REG_OFFSET);
    return iic_finish(0);
}

/*
 * wait_mclk -- wait for the audio MMCM (MCLK source) to lock.
 * Returns: 1 locked, 0 timed out.
 */
static int wait_mclk(void)
{
    for (uint32_t i = 0u; i <= ADAU_MCLK_POLLS; i++) {
        if ((Xil_In32(ADAU_SYS_STATUS) & (1u << C64_SYS_CLK_AUD_LOCKED_BIT)) != 0u) {
            return 1;
        }
        usleep(ADAU_MCLK_POLL_US);
    }
    return 0;
}

/*
 * adau1761_init -- bring the codec up for playback (fail-stop on any error).
 * Steps:
 *   1. Wait for MCLK (audio MMCM lock), bounded.
 *   2. XIic_LookupConfig, XIic_CfgInitialize, XIic_DynInit for axi_iic_0.
 *   3. Write R0 (core clock on), let the core settle, then write the rest of g_setup,
 *      reading every register back.
 *   4. Reset the dejitter circuit (R67 0x00 then 0x03).
 * Returns: nothing.
 */
void adau1761_init(void)
{
    XIic_Config *cfg;
    int st;

    if (!wait_mclk()) {
        adau_fail("audio MMCM lock (MCLK) timeout", 0u, 0u, 0u, ADAU_ERR_TIMEOUT);
    }
    cfg = XIic_LookupConfig(ADAU_IIC_BASE);
    if (cfg == NULL) {
        adau_fail("XIic_LookupConfig", 0u, 0u, 0u, 0);
    }
    st = XIic_CfgInitialize(&g_iic, cfg, cfg->BaseAddress);
    if (st != XST_SUCCESS) {
        adau_fail("XIic_CfgInitialize", 0u, 0u, 0u, st);
    }
    st = XIic_DynInit(cfg->BaseAddress);
    if (st != XST_SUCCESS) {
        adau_fail("XIic_DynInit", 0u, 0u, 0u, st);
    }

    for (uint32_t i = 0u; i < sizeof(g_setup) / sizeof(g_setup[0]); i++) {
        uint8_t back = 0u;
        int r = adau1761_write(g_setup[i].reg, g_setup[i].value);
        if (r != 0) {
            adau_fail("IIC write", g_setup[i].reg, g_setup[i].value, 0u, r);
        }
        if (g_setup[i].reg == ADAU_R0_CLOCK_CTRL) {
            usleep(ADAU_CORE_SETTLE_US);
        }
        r = adau1761_read(g_setup[i].reg, &back);
        if (r != 0) {
            adau_fail("IIC read-back", g_setup[i].reg, g_setup[i].value, 0u, r);
        }
        if (back != g_setup[i].value) {
            adau_fail("read-back mismatch", g_setup[i].reg, g_setup[i].value, back, 0);
        }
    }
    st = adau1761_write(ADAU_R67_DEJITTER, 0x00u);
    if (st == 0) {
        st = adau1761_write(ADAU_R67_DEJITTER, ADAU_DEJITTER_ON);
    }
    if (st != 0) {
        adau_fail("IIC write", ADAU_R67_DEJITTER, ADAU_DEJITTER_ON, 0u, st);
    }
}

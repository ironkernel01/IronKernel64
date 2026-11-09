/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: adau1761.h
 * Role: the ADAU1761 audio codec (Nexys Video IC4) over I2C: playback set-up for the SID
 *   stream (48 kHz, 16-bit I2S, codec as I2S slave, MCLK = 256 * fs = 12.288 MHz from the
 *   FPGA, no codec PLL) to line out J5 and headphones J3.
 *
 * Ownership: adau1761.c is the only file that uses the IIC path (axi_iic_0, XIic driver).
 *
 * Contract:
 *   - adau1761_init() waits (bounded) for the audio MMCM lock (C64_SYS_CLK_AUD_LOCKED_BIT:
 *     the codec's I2C port needs MCLK), initialises the AXI IIC, writes the playback
 *     register sequence and reads every register back. Any IIC failure or read-back
 *     mismatch is fail-stop (the console shows the register, written and read values).
 *   - I2C: 7-bit address ADAU1761_I2C_ADDR, 16-bit register address (high byte first),
 *     one data byte per register here. Every transfer is bounded by ADAU1761_XFER_TIMEOUT_US.
 *   - adau1761_read/adau1761_write are for the engineering CLI; they report failures
 *     instead of stopping.
 * Headers hold contracts and constants; per-function commentary lives in the .c files.
 */
#ifndef ADAU1761_H
#define ADAU1761_H

#include <stdint.h> /* uint8_t, uint16_t, uint32_t */

#define ADAU1761_I2C_ADDR           (0x3Bu)    /* 0b0111011, Nexys Video RM section 16 */
#define ADAU1761_REG_FIRST          (0x4000u)
#define ADAU1761_REG_LAST           (0x40FAu)
#define ADAU1761_XFER_TIMEOUT_US    (5000u)    /* one register transfer at 100 kHz: < 1 ms */
#define ADAU1761_MCLK_TIMEOUT_MS    (100u)     /* audio MMCM lock */

void adau1761_init(void);
int  adau1761_write(uint16_t reg, uint8_t value);
int  adau1761_read(uint16_t reg, uint8_t *value);

#endif /* ADAU1761_H */

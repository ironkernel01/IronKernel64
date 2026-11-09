/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: sidbus_fabric.h
 * Role: the player-side extras of sidbus_fabric.c (the sidbus.h implementation on the
 *   sid_player block): the hardware phi2 cycle counter, the time base that sidbus_frame_begin
 *   latches, the voice 3 envelope read-back and the drop counter.
 *
 * Contract:
 *   - Time is the sid_player CYCLE register (phi2 cycles since the last reset, 32-bit, wraps;
 *     compare with signed differences). sidbus_reset restarts it at 0 and sets the frame base
 *     to 0.
 *   - sidbus_fabric_set_base(t) sets the time the next sidbus_frame_begin() latches; a write at
 *     cycle offset c is stamped t + c. A stamp already in the past plays at once.
 * Headers hold contracts and constants; per-function commentary lives in the .c file.
 */
#ifndef SIDBUS_FABRIC_H
#define SIDBUS_FABRIC_H

#include <stdint.h> /* uint8_t, uint32_t */

#define SIDBUS_FABRIC_FULL_SPIN_MAX  (200000u)  /* STATUS polls waiting for FIFO room per write */
#define SIDBUS_FABRIC_RESET_HOLD_US  (200u)     /* CTRL.RESET held: about 200 phi2 cycles */

uint32_t sidbus_fabric_cycle(void);
void     sidbus_fabric_set_base(uint32_t cycle);
uint8_t  sidbus_fabric_env3(void);
uint32_t sidbus_fabric_dropped(void);

#endif /* SIDBUS_FABRIC_H */

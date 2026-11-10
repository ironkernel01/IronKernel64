; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 IronKernel
;
; File: player.asm
; Role: the ik64 SID player, a small data-driven 6502 music engine (3 voices, 6581, no filter).
;   Assembled by tools/mksid.py (tools/ik64sid/asm6502.py) together with the song data section the
;   tool generates after this code; the result is a PSID v2 at load address $1000.
;
; Entry points (PSID): $1000 init (JMP init), $1003 play (JMP play). One play call per PAL frame
;   (vertical-blank speed). Init ignores A (one song per file).
;
; Song data contract (labels defined by the generated section, all 16-bit absolute):
;   song_rate_lo/hi  one byte each: ticks per frame as a 0.16 fixed-point fraction (< 1.0).
;                    A tick is the score's shortest time unit; tempo = rate * 50 ticks per second.
;   ord_lo/ord_hi    3 bytes each: address of the voice's order list.
;   pat_lo/pat_hi    one byte per pattern: address of the pattern stream.
;   freq_lo/freq_hi  96 bytes each: SID frequency for note index 0 (C0) .. 95 (B7), PAL clock.
;   inst             16-byte instrument records, index << 4 (see below).
;
; Order list: pairs { pattern index, transpose (signed semitones) } ... then $FF. At the $FF the list
;   restarts at its first pair, so every voice loops; the tool checks the three voices have the same
;   length in ticks so they loop together.
; Pattern stream (bytes):
;   $00 dur          rest: gate off, the release tail rings
;   $01..$60 dur     note: note index + 1; gate off and waveform set this frame, gate on the next frame
;                    (the SID needs the gate low for one frame to retrigger the envelope)
;   $81..$E0 dur     slur: new pitch without retrigger (same note index coding + $80)
;   $7F dur          tie: keep sounding for dur more ticks
;   $F1 n            select instrument n (0..15)
;   $FF              end of pattern
;   dur is 1..255 ticks.
; Instrument record (16 bytes):
;    0 wave        SID control bits without gate ($10 triangle $20 saw $40 pulse $80 noise)
;    1 ad          attack/decay
;    2 sr          sustain/release
;    3 pw          initial pulse width, 12-bit value >> 4 (pulse width = pw * 16)
;    4 pwspeed     signed pulse width sweep per frame (pw units * 1/64), 0 = static; the width bounces
;                  between $200 and $BFF
;    5 vibshift    vibrato depth: peak deviation = 8 * frequency >> vibshift, 0 = no vibrato
;    6 vibdelay    frames after the gate before the vibrato starts
;    7 vibspeed    vibrato phase increment per frame (256 = one period)
;    8 gatelen     frames the gate stays on, 0 = until the next event
;    9 flags       bit 0: hard restart (AD = SR = 0 during the frame before the gate)
;   10..15         reserved, zero
;
; Timing and cost: all work is in play; no interrupts, no decimal mode. Worst case about 1000 cycles
;   per call, far below the 20000-cycle cap of the host.
; Memory: code and data at $1000 up; variables (VARS, page aligned, defined by the tool) follow the
;   image. Zero page $F0..$FE is used as scratch and holds no state between calls.
; Revision: 11-10-2026
;   * 11-10-2026: initial version.

; ---- constants ----
SID         = $D400          ; voice registers at +0 (voice 1), +7, +14: freq lo/hi, pw lo/hi, ctrl, ad, sr
SID_VOL     = $D418
GATE        = $01
EV_REST     = $00
EV_TIE      = $7F
EV_SLUR     = $80
EV_INST     = $F1
EV_END      = $FF
NOTE_COUNT  = 96
STATE_IDLE  = 0
STATE_PREP  = 1              ; note started, gate still off
STATE_ON    = 2              ; gate on
STATE_REL   = 3              ; gate off after gatelen
VOLUME      = $0F
PW_MIN      = $20            ; pulse width sweep limits, high byte units (value >> 4)
PW_MAX      = $C0
VAR_BYTES   = 69             ; size of the variable block, cleared by init

; ---- zero page scratch ----
ZP_T0       = $F0
ZP_T1       = $F1
ZP_T2       = $F2
ZP_T3       = $F3
ZP_T4       = $F4
ZP_T5       = $F5
ZP_VY       = $FA            ; SID register offset of the current voice (0, 7, 14)
ZP_PTR      = $FB            ; 16-bit stream pointer

; ---- variables: 3 bytes each (one per voice), then the globals ----
v_opos      = VARS+0         ; byte offset into the order list
v_pplo      = VARS+3         ; pattern read pointer
v_pphi      = VARS+6
v_dur       = VARS+9         ; ticks left of the current event
v_inst      = VARS+12        ; instrument record offset (index << 4)
v_state     = VARS+15
v_age       = VARS+18        ; frames since gate on (saturates at 255)
v_flo       = VARS+21        ; base frequency
v_fhi       = VARS+24
v_pwlo      = VARS+27        ; pulse width, 8.8 fixed point of (width >> 4)
v_pwhi      = VARS+30
v_pws       = VARS+33        ; current sweep speed (signed)
v_vph       = VARS+36        ; vibrato phase
v_trn       = VARS+39        ; transposition of the current pattern
v_wave      = VARS+42        ; copy of the instrument fields of the sounding note
v_ad        = VARS+45
v_sr        = VARS+48
v_vsh       = VARS+51
v_vdel      = VARS+54
v_vspd      = VARS+57
; globals, then the last two copied instrument fields
g_acc_lo    = VARS+60
g_acc_hi    = VARS+61
g_tick      = VARS+62
v_glen      = VARS+63
v_hr        = VARS+66

        .org $1000
        jmp init
        jmp play

; ---------------------------------------------------------------------------------------------
; init: clear the variables and the SID, set the volume, point every voice at an empty pattern so
;   the first tick walks into its order list.
; ---------------------------------------------------------------------------------------------
init:
        lda #0
        ldx #VAR_BYTES-1
init_clr:
        sta VARS,x
        dex
        bpl init_clr
        ldx #24
init_sid:
        sta SID,x
        dex
        bpl init_sid
        lda #VOLUME
        sta SID_VOL
        ldx #2
init_voice:
        lda #1
        sta v_dur,x
        lda #$FE                 ; the first advance (+2) selects the first order entry
        sta v_opos,x
        lda #<empty_pat
        sta v_pplo,x
        lda #>empty_pat
        sta v_pphi,x
        dex
        bpl init_voice
        lda #$FF                 ; any rate carries on the first call: the first tick is immediate
        sta g_acc_lo
        sta g_acc_hi
        rts

empty_pat:
        .byte EV_END

voff:
        .byte 0, 7, 14           ; SID register offset of voice 0, 1, 2

; ---------------------------------------------------------------------------------------------
; play: advance the tick phase, then update the three voices.
; ---------------------------------------------------------------------------------------------
play:
        clc
        lda g_acc_lo
        adc song_rate_lo
        sta g_acc_lo
        lda g_acc_hi
        adc song_rate_hi
        sta g_acc_hi
        lda #0
        rol                      ; A = carry = tick
        sta g_tick
        ldx #2
play_voice:
        jsr voice
        dex
        bpl play_voice
        rts

; ---------------------------------------------------------------------------------------------
; voice: one frame of voice X. First the sound effects of the current note, then, on a tick, the
;   event stream. A note started this frame (state PREP) gets its gate in the next frame.
; ---------------------------------------------------------------------------------------------
voice:
        ldy voff,x
        sty ZP_VY
        lda v_state,x
        beq voice_tick
        cmp #STATE_PREP
        bne voice_on
        lda v_ad,x               ; frame after the prepare: real envelope, gate on
        sta SID+5,y
        lda v_sr,x
        sta SID+6,y
        lda v_wave,x
        ora #GATE
        sta SID+4,y
        lda #STATE_ON
        sta v_state,x
        lda #0
        sta v_age,x
        jmp voice_tick
voice_on:
        cmp #STATE_ON
        bne voice_tick           ; released: nothing to do
        lda v_age,x
        cmp #$FF
        beq voice_aged
        inc v_age,x
voice_aged:
        lda v_glen,x
        beq voice_fx
        cmp v_age,x
        bne voice_fx
        lda v_wave,x             ; gatelen reached: gate off
        sta SID+4,y
        lda #STATE_REL
        sta v_state,x
        jmp voice_tick
voice_fx:
        jsr pw_sweep
        jsr vibrato
voice_tick:
        lda g_tick
        beq voice_done
        dec v_dur,x
        bne voice_done
        jsr fetch
voice_done:
        rts

; ---------------------------------------------------------------------------------------------
; pw_sweep: move the pulse width of voice X by its sweep speed, bounce at the limits, write it.
; ---------------------------------------------------------------------------------------------
pw_sweep:
        lda v_pws,x
        bne pw_move
        rts
pw_move:
        sta ZP_T0                ; delta = sext(speed) * 4 as 16 bits in ZP_T1:ZP_T0
        ldy #0
        lda ZP_T0
        bpl pw_pos
        ldy #$FF
pw_pos:
        sty ZP_T1
        asl ZP_T0
        rol ZP_T1
        asl ZP_T0
        rol ZP_T1
        clc
        lda v_pwlo,x
        adc ZP_T0
        sta v_pwlo,x
        lda v_pwhi,x
        adc ZP_T1
        sta v_pwhi,x
        cmp #PW_MIN
        bcc pw_bounce
        cmp #PW_MAX
        bcc pw_write
pw_bounce:                       ; out of range: undo the step, reverse the direction
        sec
        lda v_pwlo,x
        sbc ZP_T0
        sta v_pwlo,x
        lda v_pwhi,x
        sbc ZP_T1
        sta v_pwhi,x
        sec
        lda #0
        sbc v_pws,x
        sta v_pws,x
pw_write:                        ; PWL = (hi << 4) | (lo >> 4), PWH = hi >> 4
        lda v_pwlo,x
        lsr
        lsr
        lsr
        lsr
        sta ZP_T0
        lda v_pwhi,x
        asl
        asl
        asl
        asl
        ora ZP_T0
        ldy ZP_VY
        sta SID+2,y
        lda v_pwhi,x
        lsr
        lsr
        lsr
        lsr
        sta SID+3,y
        rts

; ---------------------------------------------------------------------------------------------
; vibrato: after vibdelay frames, add a triangle LFO to the base frequency of voice X and write it.
;   LFO step m = -8..+7, deviation = m * (frequency >> vibshift), so it scales with the pitch.
; ---------------------------------------------------------------------------------------------
vibrato:
        lda v_vsh,x
        beq vib_ret
        lda v_age,x
        cmp v_vdel,x
        bcc vib_ret              ; delay not over: the base frequency stays
        clc
        lda v_vph,x
        adc v_vspd,x
        sta v_vph,x
        lsr
        lsr
        lsr                      ; 0..31
        cmp #16
        bcc vib_tri
        eor #$1F                 ; fold 16..31 to 15..0
vib_tri:
        sec
        sbc #8
        sta ZP_T0                ; m
        lda v_flo,x
        sta ZP_T1
        lda v_fhi,x
        sta ZP_T2
        lda v_vsh,x
        tay
vib_shift:                       ; unit = frequency >> vibshift in ZP_T2:ZP_T1
        lsr ZP_T2
        ror ZP_T1
        dey
        bne vib_shift
        lda v_flo,x              ; result in ZP_T5:ZP_T4, starts at the base frequency
        sta ZP_T4
        lda v_fhi,x
        sta ZP_T5
        lda ZP_T0
        beq vib_out
        bmi vib_neg
        tay
vib_add:
        clc
        lda ZP_T4
        adc ZP_T1
        sta ZP_T4
        lda ZP_T5
        adc ZP_T2
        sta ZP_T5
        dey
        bne vib_add
        jmp vib_out
vib_neg:
        eor #$FF
        clc
        adc #1                   ; |m|
        tay
vib_sub:
        sec
        lda ZP_T4
        sbc ZP_T1
        sta ZP_T4
        lda ZP_T5
        sbc ZP_T2
        sta ZP_T5
        dey
        bne vib_sub
vib_out:
        ldy ZP_VY
        lda ZP_T4
        sta SID,y
        lda ZP_T5
        sta SID+1,y
vib_ret:
        rts

; ---------------------------------------------------------------------------------------------
; next_byte: A = next byte of the pattern stream at ZP_PTR, pointer advanced. Clobbers Y.
; ---------------------------------------------------------------------------------------------
next_byte:
        ldy #0
        lda (ZP_PTR),y
        inc ZP_PTR
        bne next_done
        inc ZP_PTR+1
next_done:
        rts

; ---------------------------------------------------------------------------------------------
; fetch: voice X reached the end of its event; read events until one carries a duration.
;   Instrument commands are applied, the end of a pattern moves to the next order entry.
; ---------------------------------------------------------------------------------------------
fetch:
        lda v_pplo,x
        sta ZP_PTR
        lda v_pphi,x
        sta ZP_PTR+1
fetch_next:
        jsr next_byte
        cmp #EV_END
        beq fetch_order
        cmp #EV_INST
        beq fetch_inst
        sta ZP_T0                ; event byte
        jsr next_byte
        sta v_dur,x              ; duration
        lda ZP_PTR               ; save the stream position
        sta v_pplo,x
        lda ZP_PTR+1
        sta v_pphi,x
        lda ZP_T0
        beq fetch_rest
        cmp #EV_TIE
        beq fetch_ret
        and #$7F                 ; note index + 1
        sec
        sbc #1
        clc
        adc v_trn,x
        tay
        lda freq_lo,y
        sta v_flo,x
        lda freq_hi,y
        sta v_fhi,x
        lda ZP_T0
        bmi fetch_slur
        jmp note_on
fetch_ret:
        rts
fetch_rest:
        ldy ZP_VY
        lda v_wave,x
        sta SID+4,y              ; gate off
        lda #STATE_IDLE
        sta v_state,x
        rts
fetch_slur:
        ldy ZP_VY
        lda v_flo,x
        sta SID,y
        lda v_fhi,x
        sta SID+1,y
        rts
fetch_inst:
        jsr next_byte
        asl
        asl
        asl
        asl
        sta v_inst,x
        jmp fetch_next
fetch_order:                     ; end of pattern: next order entry, wrapping at $FF
        lda ord_lo,x
        sta ZP_PTR
        lda ord_hi,x
        sta ZP_PTR+1
        lda v_opos,x
        clc
        adc #2
        tay
        lda (ZP_PTR),y
        cmp #$FF
        bne fetch_entry
        ldy #0
        lda (ZP_PTR),y
fetch_entry:
        sta ZP_T1                ; pattern index
        tya
        sta v_opos,x
        iny
        lda (ZP_PTR),y
        sta v_trn,x
        ldy ZP_T1
        lda pat_lo,y
        sta ZP_PTR
        lda pat_hi,y
        sta ZP_PTR+1
        jmp fetch_next

; ---------------------------------------------------------------------------------------------
; note_on: start the note whose frequency is in v_flo/v_fhi on voice X. Copies the instrument,
;   writes waveform (gate off), frequency and pulse width, and arms the gate for the next frame.
; ---------------------------------------------------------------------------------------------
note_on:
        lda v_inst,x             ; ZP_PTR = inst + v_inst (the stream position is already saved)
        clc
        adc #<inst
        sta ZP_PTR
        lda #>inst
        adc #0
        sta ZP_PTR+1
        ldy #0
        lda (ZP_PTR),y
        sta v_wave,x
        ldy #1
        lda (ZP_PTR),y
        sta v_ad,x
        ldy #2
        lda (ZP_PTR),y
        sta v_sr,x
        ldy #3
        lda (ZP_PTR),y
        sta v_pwhi,x
        lda #0
        sta v_pwlo,x
        ldy #4
        lda (ZP_PTR),y
        sta v_pws,x
        ldy #5
        lda (ZP_PTR),y
        sta v_vsh,x
        ldy #6
        lda (ZP_PTR),y
        sta v_vdel,x
        ldy #7
        lda (ZP_PTR),y
        sta v_vspd,x
        ldy #8
        lda (ZP_PTR),y
        sta v_glen,x
        ldy #9
        lda (ZP_PTR),y
        sta v_hr,x
        ldy ZP_VY
        lda v_hr,x
        beq note_wave
        lda #0                   ; hard restart: fastest envelope while the gate is off
        sta SID+5,y
        sta SID+6,y
note_wave:
        lda v_wave,x
        sta SID+4,y              ; waveform, gate off
        lda v_flo,x
        sta SID,y
        lda v_fhi,x
        sta SID+1,y
        jsr pw_write
        lda #0
        sta v_vph,x
        lda #STATE_PREP
        sta v_state,x
        rts

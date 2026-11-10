// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_ddr_sim.sv
// Purpose: simulation stand-in for the DDR3 controller (the MIG ik64_ddr_mig
//   inside ik64_ddr): the same port list, an AXI4 memory model behind it, no
//   DDR3 pins. Selected by ik64_ddr when IK64_DDR_SIM is defined; never
//   synthesized.
// Behaviors:
//   * ui_clk is sys_clk (the bench clock). ui_resetn releases RELEASE_CLOCKS
//     ui clocks after sys_rstn is released and falls with sys_rstn.
//   * init_calib_complete rises CALIB_CLOCKS ui clocks after ui_resetn is
//     released (the real controller needs about 100 us) and falls with sys_rstn.
//   * The memory runs while init_calib_complete is high and s_axi_aresetn is
//     released; before that every ready and valid output is low, as the MIG's
//     AXI slave holds them until calibration completes.
//   * Storage: sparse 128-bit words (associative array), 29-bit byte addresses,
//     unwritten words read 0.
//   * Bursts: INCR, WRAP (2, 4, 8 or 16 beats, critical word first) and FIXED
//     beat addressing, narrow beats (the lane strobes select the bytes; reads
//     return the whole 128-bit word). A burst crossing 4 KiB or a WRAP with an
//     illegal length is reported by $error.
//   * Timing: AW queue of 8; W accepted only for a queued AW, one beat per
//     clock; B one clock after the last W beat (in AW order); read data starts
//     READ_LATENCY clocks after the AR was accepted, one beat per clock while
//     rready is high, in AR order. All AXI outputs are registered.
//   * DDR3 outputs are driven to idle levels; the inouts are not driven.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: sys_clk (= ui_clk); ref_clk unused.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module ik64_ddr_sim #(
  parameter int ADDR_W         = 29,
  parameter int DATA_W         = 128,
  parameter int ID_W           = 2,
  parameter int RELEASE_CLOCKS = 8,
  parameter int CALIB_CLOCKS   = 2000,
  parameter int READ_LATENCY   = 20
)(
  input  logic                sys_clk,
  input  logic                ref_clk,
  input  logic                sys_rstn,

  output logic                ui_clk,
  output logic                ui_resetn,
  input  logic                s_axi_aresetn,
  output logic                init_calib_complete,

  input  logic [ID_W-1:0]     s_axi_awid,
  input  logic [ADDR_W-1:0]   s_axi_awaddr,
  input  logic [7:0]          s_axi_awlen,
  input  logic [2:0]          s_axi_awsize,
  input  logic [1:0]          s_axi_awburst,
  input  logic                s_axi_awlock,
  input  logic [3:0]          s_axi_awcache,
  input  logic [2:0]          s_axi_awprot,
  input  logic [3:0]          s_axi_awqos,
  input  logic                s_axi_awvalid,
  output logic                s_axi_awready,
  input  logic [DATA_W-1:0]   s_axi_wdata,
  input  logic [DATA_W/8-1:0] s_axi_wstrb,
  input  logic                s_axi_wlast,
  input  logic                s_axi_wvalid,
  output logic                s_axi_wready,
  output logic [ID_W-1:0]     s_axi_bid,
  output logic [1:0]          s_axi_bresp,
  output logic                s_axi_bvalid,
  input  logic                s_axi_bready,
  input  logic [ID_W-1:0]     s_axi_arid,
  input  logic [ADDR_W-1:0]   s_axi_araddr,
  input  logic [7:0]          s_axi_arlen,
  input  logic [2:0]          s_axi_arsize,
  input  logic [1:0]          s_axi_arburst,
  input  logic                s_axi_arlock,
  input  logic [3:0]          s_axi_arcache,
  input  logic [2:0]          s_axi_arprot,
  input  logic [3:0]          s_axi_arqos,
  input  logic                s_axi_arvalid,
  output logic                s_axi_arready,
  output logic [ID_W-1:0]     s_axi_rid,
  output logic [DATA_W-1:0]   s_axi_rdata,
  output logic [1:0]          s_axi_rresp,
  output logic                s_axi_rlast,
  output logic                s_axi_rvalid,
  input  logic                s_axi_rready,

  inout  wire  [15:0]         ddr3_dq,
  inout  wire  [1:0]          ddr3_dqs_n,
  inout  wire  [1:0]          ddr3_dqs_p,
  output logic [14:0]         ddr3_addr,
  output logic [2:0]          ddr3_ba,
  output logic                ddr3_ras_n,
  output logic                ddr3_cas_n,
  output logic                ddr3_we_n,
  output logic                ddr3_reset_n,
  output logic [0:0]          ddr3_ck_p,
  output logic [0:0]          ddr3_ck_n,
  output logic [0:0]          ddr3_cke,
  output logic [1:0]          ddr3_dm,
  output logic [0:0]          ddr3_odt
);

  localparam int BYTES_W = DATA_W / 8;
  localparam int AQ_MAX  = 8;

  assign ui_clk = sys_clk;

  // ---------------------------------------------------------------------------
  // Reset release and calibration delay.
  // ---------------------------------------------------------------------------
  int rel_cnt;
  int cal_cnt;

  always @(posedge sys_clk) begin
    if (!sys_rstn) begin
      rel_cnt             <= 0;
      cal_cnt             <= 0;
      ui_resetn           <= 1'b0;
      init_calib_complete <= 1'b0;
    end else begin
      if (rel_cnt == RELEASE_CLOCKS) ui_resetn <= 1'b1;
      else                           rel_cnt <= rel_cnt + 1;
      if (ui_resetn) begin
        if (cal_cnt == CALIB_CLOCKS) init_calib_complete <= 1'b1;
        else                         cal_cnt <= cal_cnt + 1;
      end
    end
  end

  logic mem_resetn;
  assign mem_resetn = s_axi_aresetn & init_calib_complete;

  // ---------------------------------------------------------------------------
  // Memory and burst arithmetic.
  // ---------------------------------------------------------------------------
  logic [DATA_W-1:0] mem [longint unsigned];

  // Byte address of beat n of a burst.
  function automatic longint unsigned beat_addr(input longint unsigned a, input int sz, input int burst,
                                                input int len, input int n);
    longint unsigned nbytes;
    longint unsigned aligned;
    longint unsigned container;
    longint unsigned base;
    longint unsigned off;
    nbytes  = 64'd1 << sz;
    aligned = a & ~(nbytes - 64'd1);
    if (burst == 2) begin
      container = nbytes * (len + 1);
      base      = a & ~(container - 64'd1);
      off       = (aligned - base + n * nbytes) % container;
      return base + off;
    end else if (burst == 0 || n == 0) begin
      return a;
    end else begin
      return aligned + n * nbytes;
    end
  endfunction

  function automatic logic [DATA_W-1:0] word_at(input longint unsigned byte_addr);
    longint unsigned w;
    w = byte_addr / BYTES_W;
    if (mem.exists(w)) return mem[w];
    return '0;
  endfunction

  // Burst legality (simulation report only).
  task automatic check_burst(input string kind, input longint unsigned a, input int sz, input int burst, input int len);
    longint unsigned nbytes;
    longint unsigned aligned;
    nbytes  = 64'd1 << sz;
    aligned = a & ~(nbytes - 64'd1);
    if (burst == 3) $error("ik64_ddr_sim: %s burst type RESERVED at 0x%0h", kind, a);
    if (burst == 1 && ((aligned % 4096) + (len + 1) * nbytes) > 4096) $error("ik64_ddr_sim: %s INCR burst crosses 4 KiB at 0x%0h len %0d size %0d", kind, a, len, sz);
    if (burst == 2 && !(len == 1 || len == 3 || len == 7 || len == 15)) $error("ik64_ddr_sim: %s WRAP length %0d illegal", kind, len + 1);
    if (burst == 2 && (a % nbytes) != 0) $error("ik64_ddr_sim: %s WRAP start 0x%0h not size aligned", kind, a);
    if ((64'd1 << sz) > BYTES_W) $error("ik64_ddr_sim: %s size %0d wider than the bus", kind, sz);
  endtask

  // ---------------------------------------------------------------------------
  // Write path.
  // ---------------------------------------------------------------------------
  longint unsigned aw_a [$];
  int              aw_len [$];
  int              aw_sz [$];
  int              aw_bu [$];
  logic [ID_W-1:0] aw_id [$];
  logic [ID_W-1:0] b_q [$];
  int              w_beat;
  logic            bv_cur;

  // ---------------------------------------------------------------------------
  // Read path.
  // ---------------------------------------------------------------------------
  longint unsigned ar_a [$];
  int              ar_len [$];
  int              ar_sz [$];
  int              ar_bu [$];
  logic [ID_W-1:0] ar_id [$];
  longint unsigned ar_t [$];
  longint unsigned cyc;
  int              r_beat;
  logic            r_active;
  logic            rv_cur;

  always @(posedge sys_clk) begin
    cyc <= cyc + 1;
    if (!mem_resetn) begin
      aw_a.delete(); aw_len.delete(); aw_sz.delete(); aw_bu.delete(); aw_id.delete(); b_q.delete();
      ar_a.delete(); ar_len.delete(); ar_sz.delete(); ar_bu.delete(); ar_id.delete(); ar_t.delete();
      w_beat   = 0;
      r_beat   = 0;
      r_active = 1'b0;
      bv_cur   = 1'b0;
      rv_cur   = 1'b0;
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      s_axi_bid     <= '0;
      s_axi_bresp   <= 2'b00;
      s_axi_arready <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rid     <= '0;
      s_axi_rdata   <= '0;
      s_axi_rresp   <= 2'b00;
      s_axi_rlast   <= 1'b0;
    end else begin
      // ---- write address ----
      if (s_axi_awvalid && s_axi_awready) begin
        check_burst("write", longint'(s_axi_awaddr), int'(s_axi_awsize), int'(s_axi_awburst), int'(s_axi_awlen));
        aw_a.push_back(longint'(s_axi_awaddr));
        aw_len.push_back(int'(s_axi_awlen));
        aw_sz.push_back(int'(s_axi_awsize));
        aw_bu.push_back(int'(s_axi_awburst));
        aw_id.push_back(s_axi_awid);
      end
      // ---- write data: a beat for the head AW ----
      if (s_axi_wvalid && s_axi_wready && aw_a.size() > 0) begin
        longint unsigned ba;
        logic [DATA_W-1:0] word;
        ba   = beat_addr(aw_a[0], aw_sz[0], aw_bu[0], aw_len[0], w_beat);
        word = word_at(ba);
        for (int i = 0; i < BYTES_W; i++) if (s_axi_wstrb[i]) word[8*i +: 8] = s_axi_wdata[8*i +: 8];
        mem[ba / BYTES_W] = word;
        if (s_axi_wlast != (w_beat == aw_len[0])) $error("ik64_ddr_sim: WLAST at beat %0d of %0d", w_beat, aw_len[0] + 1);
        if (w_beat == aw_len[0]) begin
          b_q.push_back(aw_id[0]);
          void'(aw_a.pop_front()); void'(aw_len.pop_front()); void'(aw_sz.pop_front()); void'(aw_bu.pop_front()); void'(aw_id.pop_front());
          w_beat = 0;
        end else begin
          w_beat = w_beat + 1;
        end
      end
      // ---- write response ----
      if (bv_cur && s_axi_bready) bv_cur = 1'b0;
      if (!bv_cur && b_q.size() > 0) begin
        bv_cur = 1'b1;
        s_axi_bid   <= b_q[0];
        s_axi_bresp <= 2'b00;
        void'(b_q.pop_front());
      end
      s_axi_bvalid  <= bv_cur;
      s_axi_awready <= (aw_a.size() < AQ_MAX);
      s_axi_wready  <= (aw_a.size() > 0);

      // ---- read address ----
      if (s_axi_arvalid && s_axi_arready) begin
        check_burst("read", longint'(s_axi_araddr), int'(s_axi_arsize), int'(s_axi_arburst), int'(s_axi_arlen));
        ar_a.push_back(longint'(s_axi_araddr));
        ar_len.push_back(int'(s_axi_arlen));
        ar_sz.push_back(int'(s_axi_arsize));
        ar_bu.push_back(int'(s_axi_arburst));
        ar_id.push_back(s_axi_arid);
        ar_t.push_back(cyc);
      end
      // ---- read data ----
      if (rv_cur && s_axi_rready) rv_cur = 1'b0;
      if (!r_active && ar_a.size() > 0 && cyc >= ar_t[0] + READ_LATENCY) begin
        r_active = 1'b1;
        r_beat   = 0;
      end
      if (!rv_cur && r_active) begin
        longint unsigned ba;
        ba = beat_addr(ar_a[0], ar_sz[0], ar_bu[0], ar_len[0], r_beat);
        rv_cur = 1'b1;
        s_axi_rdata <= word_at(ba);
        s_axi_rid   <= ar_id[0];
        s_axi_rresp <= 2'b00;
        s_axi_rlast <= (r_beat == ar_len[0]);
        if (r_beat == ar_len[0]) begin
          void'(ar_a.pop_front()); void'(ar_len.pop_front()); void'(ar_sz.pop_front()); void'(ar_bu.pop_front()); void'(ar_id.pop_front()); void'(ar_t.pop_front());
          r_active = 1'b0;
        end else begin
          r_beat = r_beat + 1;
        end
      end
      s_axi_rvalid  <= rv_cur;
      s_axi_arready <= (ar_a.size() < AQ_MAX);
    end
  end

  initial cyc = 0;

  assign ddr3_addr    = '0;
  assign ddr3_ba      = '0;
  assign ddr3_ras_n   = 1'b1;
  assign ddr3_cas_n   = 1'b1;
  assign ddr3_we_n    = 1'b1;
  assign ddr3_reset_n = sys_rstn;
  assign ddr3_ck_p    = '0;
  assign ddr3_ck_n    = '1;
  assign ddr3_cke     = '0;
  assign ddr3_dm      = '0;
  assign ddr3_odt     = '0;

endmodule

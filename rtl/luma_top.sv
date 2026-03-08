`timescale 1ns / 1ps
// luma_top.sv - Top-level: Controller → vpass → stage_buf → hpass
//
// luma_controller is the single source of truth for all scanning counters.
// luma_vpass  : edge_idx / row_group driven by controller (no internal counters).
// luma_hpass  : active / edge_cnt / col_cnt / masks driven by controller (no state machine).
// luma_stage_buf write port : uses pipelined edge_idx_out / row_group_out from vpass
//                             so write addresses are always aligned with filtered data.
// luma_stage_buf read port  : driven directly by controller outputs.

module luma_top #(
    parameter int BIT_DEPTH = 8
) (
    input logic clk,
    input logic rst_n,
    input logic load_valid,

    // Block input (4×4, one block per cycle to vpass)
    input logic [BIT_DEPTH-1:0] block_in[0:3][0:3],

    // Decision parameter inputs
    input logic        [7:0] qp_p,
    input logic        [7:0] qp_q,
    input logic signed [7:0] beta_offset,
    input logic signed [7:0] tc_offset,
    input logic        [2:0] maxFilterLengthP_in,
    input logic        [2:0] maxFilterLengthQ_in,
    input logic        [1:0] bS,
    input logic              mode_vvc,
    input logic              start,                // Start processing one 128×128 CTU

    // H-pass output
    output logic [BIT_DEPTH-1:0] hpass_out  [0:3][0:15],
    output logic [         15:0] hpass_mask,
    output logic                 hpass_valid
);

  // =========================================================================
  // Beta / tC Calculation
  // =========================================================================
  logic [7:0] calculated_beta;
  logic [9:0] calculated_tC;

  calc_beta_tc u_calc_beta_tc (
      .mode_vvc   (mode_vvc),
      .bS         (bS),
      .qp_p       (qp_p),
      .qp_q       (qp_q),
      .beta_offset(beta_offset),
      .tc_offset  (tc_offset),
      .beta       (calculated_beta),
      .tC         (calculated_tC)
  );

  // =========================================================================
  // Centralized Controller
  // =========================================================================
  // V-Pass outputs
  logic [4:0] ctrl_vp_block_cnt;
  logic [4:0] ctrl_vp_edge_idx;  // real-time edge index → vpass input
  logic [5:0] ctrl_vp_row_group;  // real-time row group  → vpass input
  logic       ctrl_vp_done;

  // Buffer control outputs
  logic [5:0] ctrl_buf_wr_ptr;  // informational (pipelined path used for wr_row_idx)
  logic [5:0] ctrl_buf_rd_ptr;  // informational (rd_row_idx derived from hp_edge_cnt)
  logic       ctrl_buf_rd_en;  // → stage_buf.rd_en

  // H-Pass outputs
  logic       ctrl_hp_active;
  logic [4:0] ctrl_hp_edge_cnt;  // → hpass input, also used to derive rd_row_idx
  logic [4:0] ctrl_hp_col_cnt;  // → hpass input + stage_buf.rd_col_idx
  logic       ctrl_hp_mask1;  // → hpass input + stage_buf.mask1
  logic       ctrl_hp_mask31;  // → hpass input + stage_buf.mask31
  logic       ctrl_hp_done;

  luma_controller u_controller (
      .clk         (clk),
      .rst_n       (rst_n),
      .start       (start),
      .load_valid  (load_valid),
      .vp_block_cnt(ctrl_vp_block_cnt),
      .vp_edge_idx (ctrl_vp_edge_idx),
      .vp_row_group(ctrl_vp_row_group),
      .vp_done     (ctrl_vp_done),
      .buf_wr_ptr  (ctrl_buf_wr_ptr),
      .buf_rd_ptr  (ctrl_buf_rd_ptr),
      .buf_rd_en   (ctrl_buf_rd_en),
      .hp_active   (ctrl_hp_active),
      .hp_edge_cnt (ctrl_hp_edge_cnt),
      .hp_col_cnt  (ctrl_hp_col_cnt),
      .hp_mask1    (ctrl_hp_mask1),
      .hp_mask31   (ctrl_hp_mask31),
      .hp_done     (ctrl_hp_done)
  );

  // =========================================================================
  // V-Pass
  // =========================================================================
  logic [BIT_DEPTH-1:0] vp_stage_out                                                   [0:3][0:15];
  logic [         15:0] vp_mask;
  logic [          4:0] vp_edge_idx_out;  // pipelined (2 cyc) → wr_edge / wr_col_idx
  logic [          5:0] vp_row_group_out;  // pipelined (2 cyc) → wr_row_idx
  logic                 vp_edge_valid;

  luma_vpass #(
      .BIT_DEPTH(BIT_DEPTH)
  ) u_vpass (
      .clk                (clk),
      .rst_n              (rst_n),
      .block_in           (block_in),
      .load_valid         (load_valid),
      // Controller-driven scanning
      .edge_idx_in        (ctrl_vp_edge_idx),
      .row_group_in       (ctrl_vp_row_group),
      // Decision parameters
      .qp_p               (qp_p),
      .qp_q               (qp_q),
      .beta_offset        (beta_offset),
      .tc_offset          (tc_offset),
      .maxFilterLengthP_in(maxFilterLengthP_in),
      .maxFilterLengthQ_in(maxFilterLengthQ_in),
      .bS                 (bS),
      .mode_vvc           (mode_vvc),
      .beta_in            (calculated_beta),
      .tC_in              (calculated_tC),
      // Outputs
      .stage_out          (vp_stage_out),
      .mask_out           (vp_mask),
      .edge_idx_out       (vp_edge_idx_out),
      .row_group_out      (vp_row_group_out),
      .edge_valid         (vp_edge_valid)
  );

  // =========================================================================
  // Stage Buffer
  // =========================================================================
  logic [BIT_DEPTH-1:0] sb_out    [0:3][0:15];
  logic                 sb_valid;

  // H-pass read row: circular 6-slot mapping identical to original hpass logic
  // edge 1→row5, 2→row0, 3→row1 …  (drives rd_row_idx which is {idx,2'b00} base)
  logic [          2:0] sb_rd_row;
  assign sb_rd_row = 3'((6'(ctrl_hp_edge_cnt) + 4) % 6);

  luma_stage_buf #(
      .BIT_DEPTH(BIT_DEPTH)
  ) u_stage_buf (
      .clk       (clk),
      .rst_n     (rst_n),
      // Write port — pipelined outputs from vpass keep addresses aligned with data
      .wr_valid  (vp_edge_valid),
      .wr_data   (vp_stage_out),
      .wr_mask   (vp_mask),
      .wr_edge   (vp_edge_idx_out),
      .wr_row_idx(3'(vp_row_group_out % 6)),  // was top-level row_group; now pipelined from vpass
      .wr_col_idx(vp_edge_idx_out),
      // Read port — driven directly by controller
      .rd_en     (ctrl_buf_rd_en),
      .rd_row_idx(sb_rd_row),
      .rd_col_idx(ctrl_hp_col_cnt),
      .mask1     (ctrl_hp_mask1),
      .mask31    (ctrl_hp_mask31),
      // Outputs
      .rd_data   (sb_out),
      .buf_valid (sb_valid)
  );

  // =========================================================================
  // H-Pass
  // =========================================================================
  logic [BIT_DEPTH-1:0] hp_filt_out   [0:3][0:15];
  logic [         15:0] hp_mask_out;
  logic                 hp_filt_valid;

  luma_hpass #(
      .BIT_DEPTH(BIT_DEPTH)
  ) u_hpass (
      .clk                (clk),
      .rst_n              (rst_n),
      .load_valid         (load_valid),
      // Decision parameters
      .qp_p               (qp_p),
      .qp_q               (qp_q),
      .beta_offset        (beta_offset),
      .tc_offset          (tc_offset),
      .maxFilterLengthP_in(maxFilterLengthP_in),
      .maxFilterLengthQ_in(maxFilterLengthQ_in),
      .bS                 (bS),
      .mode_vvc           (mode_vvc),
      .beta_in            (calculated_beta),
      .tC_in              (calculated_tC),
      // Data from stage buffer
      .block_in           (sb_out),
      // Controller-driven scanning
      .hp_active_in       (ctrl_hp_active),
      .edge_cnt_in        (ctrl_hp_edge_cnt),
      .col_cnt_in         (ctrl_hp_col_cnt),
      .mask1_in           (ctrl_hp_mask1),
      .mask31_in          (ctrl_hp_mask31),
      // Outputs
      .block_out          (hp_filt_out),
      .mask_out           (hp_mask_out),
      .block_out_valid    (hp_filt_valid),
      .out_row_idx        (),
      .out_col_idx        (),
      .out_mask1          (),
      .out_mask31         ()
  );

  // =========================================================================
  // Top-level Outputs
  // =========================================================================
  assign hpass_out   = hp_filt_out;
  assign hpass_mask  = hp_mask_out;
  assign hpass_valid = hp_filt_valid;

endmodule

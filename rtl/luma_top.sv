`timescale 1ns / 1ps
// luma_top.sv - Top-level: vpass → stage_buf → hpass (pass-through flow)

module luma_top #(
    parameter int BIT_DEPTH = 8
) (
    input logic clk,
    input logic rst_n,
    input logic load_valid,

    // Block input (4x4, one block per cycle to vpass)
    input logic [BIT_DEPTH-1:0] block_in[0:3][0:3],

    // Unused decision inputs (tied off)
    input logic        [7:0] qp_p,
    input logic        [7:0] qp_q,
    input logic signed [7:0] beta_offset,
    input logic signed [7:0] tc_offset,
    input logic        [2:0] maxFilterLengthP_in,
    input logic        [2:0] maxFilterLengthQ_in,
    input logic        [1:0] bS,
    input logic              mode_vvc,
    input logic              start,

    // H-pass output: 4x16 window from stage_buf (pass-through)
    output logic [BIT_DEPTH-1:0] hpass_out  [0:3][0:15],
    output logic                 hpass_valid
);

  // =========================================================================
  // V-Pass signals (declare before use)
  // =========================================================================
  logic [BIT_DEPTH-1:0] vp_stage_out       [0:3][0:15];  // raw → stage buffer
  logic [BIT_DEPTH-1:0] vp_stage_out_masked[0:3][0:15];  // boundary-zeroed → filter
  logic [          4:0] vp_edge_idx;
  logic                 vp_edge_valid;

  // =========================================================================
  // Row group counter (top-level): increments after 32 edges per row pass
  // =========================================================================
  logic [          2:0] row_group;  // 0-4

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      row_group <= 3'd0;
    end else if (vp_edge_valid && (vp_edge_idx == 5'd31)) begin
      row_group <= (row_group == 3'd5) ? 3'd0 : row_group + 1'b1;
    end
  end

  // =========================================================================
  // V-Pass instance
  // =========================================================================

  luma_vpass #(
      .BIT_DEPTH(BIT_DEPTH)
  ) u_vpass (
      .clk                (clk),
      .rst_n              (rst_n),
      .start              (start),
      .block_in           (block_in),
      .load_valid         (load_valid),
      .qp_p               (qp_p),
      .qp_q               (qp_q),
      .beta_offset        (beta_offset),
      .tc_offset          (tc_offset),
      .maxFilterLengthP_in(maxFilterLengthP_in),
      .maxFilterLengthQ_in(maxFilterLengthQ_in),
      .bS                 (bS),
      .mode_vvc           (mode_vvc),
      .stage_out          (vp_stage_out),
      .stage_out_masked   (vp_stage_out_masked),
      .edge_idx_out       (vp_edge_idx),
      .edge_valid         (vp_edge_valid)
  );

  // =========================================================================
  // Stage Buffer
  // =========================================================================
  logic [BIT_DEPTH-1:0] sb_out     [0:3][0:15];
  logic                 sb_valid;

  // H-pass address signals
  logic [          2:0] hp_row_idx;
  logic [          4:0] hp_col_idx;
  logic                 hp_read_en;
  logic hp_mask1, hp_mask31;

  luma_stage_buf #(
      .BIT_DEPTH(BIT_DEPTH)
  ) u_stage_buf (
      .clk(clk),
      .rst_n(rst_n),
      // Write port (from vpass)
      .wr_valid(vp_edge_valid),
      .wr_data(vp_stage_out),
      .wr_edge(vp_edge_idx),
      .wr_row_idx(row_group),
      .wr_col_idx(vp_edge_idx),
      // Read port (from hpass)
      .rd_en(hp_read_en),
      .rd_row_idx(hp_row_idx),
      .rd_col_idx(hp_col_idx),
      .mask1(hp_mask1),
      .mask31(hp_mask31),
      // Outputs
      .rd_data(sb_out),
      .buf_valid(sb_valid)
  );

  // =========================================================================
  // H-Pass
  // =========================================================================
  luma_hpass #(
      .BIT_DEPTH(BIT_DEPTH)
  ) u_hpass (
      .clk       (clk),
      .rst_n     (rst_n),
      .load_valid(load_valid),
      .block_in  (sb_out),
      .row_idx   (hp_row_idx),
      .col_idx   (hp_col_idx),
      .read_en   (hp_read_en),
      .mask1     (hp_mask1),
      .mask31    (hp_mask31)
  );

  // =========================================================================
  // Outputs
  // =========================================================================
  assign hpass_out   = sb_out;
  assign hpass_valid = hp_read_en;

endmodule

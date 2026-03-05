`timescale 1ns / 1ps
// luma_vpass.sv - Luma V-Pass Deblocking Engine
// Pipeline: Load (S0) → Decision/Beta (S1) → Filter (S2) → Store (S3)
// Stage buffer: 4x16, shifts left by 4 each load cycle
// Edge index: 1..31 per row group (x=4..124 in 128-wide CTU)

module luma_vpass #(
    parameter int BIT_DEPTH = 8
) (
    input logic clk,
    input logic rst_n,
    input logic start,

    // S0: Load
    input logic [BIT_DEPTH-1:0] block_in  [0:3][0:3],
    input logic                 load_valid,

    // Decision inputs (per edge, driven by upstream CU parser)
    input logic        [7:0] qp_p,
    input logic        [7:0] qp_q,
    input logic signed [7:0] beta_offset,
    input logic signed [7:0] tc_offset,
    input logic        [2:0] maxFilterLengthP_in,
    input logic        [2:0] maxFilterLengthQ_in,
    input logic        [1:0] bS,
    input logic              mode_vvc,

    // Primary output: current 4x16 stage window + valid flag
    output logic [BIT_DEPTH-1:0] stage_out       [0:3][0:15],  // raw, for stage buffer
    output logic [BIT_DEPTH-1:0] stage_out_masked[0:3][0:15],  // boundary-zeroed, for filter input
    output logic [          4:0] edge_idx_out,                 // current edge index
    output logic                 edge_valid                    // high when edge_idx >= 1

);


  // =========================================================================
  // S0 — Stage Buffer (4 rows x 16 cols)
  // =========================================================================
  logic [BIT_DEPTH-1:0] stage_buf[0:3][0:15];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      foreach (stage_buf[r, c]) stage_buf[r][c] <= '0;
    end else if (load_valid) begin
      for (int r = 0; r < 4; r++) begin
        // shift left by 4
        for (int c = 0; c < 12; c++) stage_buf[r][c] <= stage_buf[r][c+4];
        // load new 4x4 into rightmost 4 cols
        for (int c = 0; c < 4; c++) stage_buf[r][12+c] <= block_in[r][c];
      end
    end
  end

  // counters
  logic [4:0] block_cnt;  // 0-31 (mod 32)
  logic [4:0] edge_idx;  // 0-31 (mod 32), stall at 31 for loading

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      block_cnt <= 5'd0;
      edge_idx  <= 5'd0;
    end else if (load_valid) begin
      block_cnt <= (block_cnt == 5'd31) ? 5'd0 : block_cnt + 1'b1;
      if (edge_idx == 5'd31) edge_idx <= 5'd0;  // wrap
      else if (edge_idx < 5'd2 && block_cnt <= 5'd1) edge_idx <= edge_idx;  // stall only at start
      else edge_idx <= edge_idx + 1'b1;
    end
  end

  // =========================================================================
  // Masking: zero stale block for corner edges
  // =========================================================================
  logic [BIT_DEPTH-1:0] masked_buf[0:3][0:15];

  always_comb begin
    masked_buf = stage_buf;
    if (edge_idx == 5'd1) begin
      for (int r = 0; r < 4; r++)
      for (int c = 0; c < 4; c++) masked_buf[r][c] = '0;  // zero leftmost block
    end else if (edge_idx == 5'd31) begin
      for (int r = 0; r < 4; r++)
      for (int c = 12; c < 16; c++) masked_buf[r][c] = '0;  // zero rightmost block
    end
  end

  // Primary outputs
  assign stage_out        = stage_buf;  // raw pixel data → stage buffer
  assign stage_out_masked = masked_buf;  // boundary-zeroed → filter arithmetic input
  assign edge_idx_out     = edge_idx;
  assign edge_valid       = (edge_idx >= 5'd1);

endmodule

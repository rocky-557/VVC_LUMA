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
    input logic        [7:0] beta_in,
    input logic        [9:0] tC_in,

    // Primary output: current 4x16 stage window + valid flag
    output logic [BIT_DEPTH-1:0] stage_out   [0:3][0:15],  // filtered output for stage buffer
    output logic [         15:0] mask_out,                 // write mask for stage buffer
    output logic [          4:0] edge_idx_out,             // current edge index
    output logic                 edge_valid                // high when edge_idx >= 1

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
  // Masking: zero stale block for corner edges (for Decision logic ONLY)
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

  // =========================================================================
  // S1 — Decision Pipelining (1 cycle latency)
  // =========================================================================

  // Arrange inputs for edge decision (P and Q pixels for 4 rows)
  logic [BIT_DEPTH-1:0] ext_p[0:3][0:7];
  logic [BIT_DEPTH-1:0] ext_q[0:3][0:7];

  always_comb begin
    for (int r = 0; r < 4; r++) begin
      for (int c = 0; c < 8; c++) begin
        ext_p[r][c] = masked_buf[r][7-c];  // p0 is at col 7, p7 is at col 0
        ext_q[r][c] = masked_buf[r][8+c];  // q0 is at col 8, q7 is at col 15
      end
    end
  end

  logic       filter_on_s1;
  logic [1:0] filter_type_s1;
  logic dEp_s1, dEq_s1;
  logic [2:0] maxFilterLengthP_s1;
  logic [2:0] maxFilterLengthQ_s1;
  logic [9:0] tC_s1;

  edge_decision #(
      .BIT_DEPTH(BIT_DEPTH)
  ) u_edge_decision (
      .p(ext_p),
      .q(ext_q),
      .beta(beta_in),
      .tC(tC_in),
      .mode_vvc(mode_vvc),
      .maxFilterLengthP_in(maxFilterLengthP_in),
      .maxFilterLengthQ_in(maxFilterLengthQ_in),
      .filter_on(filter_on_s1),
      .dE(filter_type_s1),
      .dEp(dEp_s1),
      .dEq(dEq_s1),
      .maxFilterLengthP_out(maxFilterLengthP_s1),
      .maxFilterLengthQ_out(maxFilterLengthQ_s1)
  );

  // Pipeline Registers S1
  logic [BIT_DEPTH-1:0] p_s1            [0:3][0:7];
  logic [BIT_DEPTH-1:0] q_s1            [0:3][0:7];
  logic [          4:0] edge_idx_s1;
  logic                 valid_s1;

  logic                 filter_on_reg;
  logic [          1:0] filter_type_reg;
  logic dEp_reg, dEq_reg;
  logic [2:0] maxFilterLengthP_reg, maxFilterLengthQ_reg;
  logic [15:0] mask_s1_wire;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s1 <= 1'b0;
      edge_idx_s1 <= 5'd0;
      foreach (p_s1[r, c]) p_s1[r][c] <= '0;
      foreach (q_s1[r, c]) q_s1[r][c] <= '0;
      tC_s1 <= '0;
      filter_on_reg <= 1'b0;
      filter_type_reg <= 2'b0;
      dEp_reg <= 1'b0;
      dEq_reg <= 1'b0;
      maxFilterLengthP_reg <= 3'd1;
      maxFilterLengthQ_reg <= 3'd1;
    end else if (load_valid) begin
      valid_s1 <= (edge_idx >= 5'd1);
      edge_idx_s1 <= edge_idx;
      // Pipeline Decision Outputs
      filter_on_reg <= filter_on_s1;
      filter_type_reg <= filter_type_s1;
      dEp_reg <= dEp_s1;
      dEq_reg <= dEq_s1;
      maxFilterLengthP_reg <= maxFilterLengthP_s1;
      maxFilterLengthQ_reg <= maxFilterLengthQ_s1;
      // Data Path: Use unmasked stage_buf to prevent zeroing out data at boundaries
      for (int r = 0; r < 4; r++) begin
        for (int c = 0; c < 8; c++) begin
          p_s1[r][c] <= stage_buf[r][7-c];
          q_s1[r][c] <= stage_buf[r][8+c];
        end
      end
      tC_s1 <= tC_in;
    end
  end

  // =========================================================================
  // S2 — Filtering Core (Per Row)
  // =========================================================================

  logic [BIT_DEPTH-1:0] p_filt     [0:3] [0:7];
  logic [BIT_DEPTH-1:0] q_filt     [0:3] [0:7];
  logic [         15:0] mask_s1_row[0:3];

  genvar r;
  generate
    for (r = 0; r < 4; r++) begin : gen_filter_core
      luma_filter_core #(
          .BIT_DEPTH(BIT_DEPTH)
      ) u_filter_core (
          .p_in(p_s1[r]),
          .q_in(q_s1[r]),
          .tC(tC_s1),
          .filter_enable(filter_on_reg),
          .filter_type(filter_type_reg),
          .mode_vvc(mode_vvc),
          .dEp(dEp_reg),
          .dEq(dEq_reg),
          .maxFilterLengthP(maxFilterLengthP_reg),
          .maxFilterLengthQ(maxFilterLengthQ_reg),
          .p_out(p_filt[r]),
          .q_out(q_filt[r]),
          .write_mask(mask_s1_row[r])
      );
    end
  endgenerate

  assign mask_s1_wire = mask_s1_row[0];  // All rows share same mask

  // Pipeline Registers S2
  logic [BIT_DEPTH-1:0] p_s2        [0:3][0:7];
  logic [BIT_DEPTH-1:0] q_s2        [0:3][0:7];
  logic [          4:0] edge_idx_s2;
  logic                 valid_s2;
  logic [         15:0] mask_s2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s2 <= 1'b0;
      edge_idx_s2 <= 5'd0;
      foreach (p_s2[r, c]) p_s2[r][c] <= '0;
      foreach (q_s2[r, c]) q_s2[r][c] <= '0;
      mask_s2 <= 16'h0;
    end else if (load_valid) begin
      valid_s2 <= valid_s1;
      edge_idx_s2 <= edge_idx_s1;
      p_s2 <= p_filt;
      q_s2 <= q_filt;
      mask_s2 <= mask_s1_wire;
    end
  end

  // =========================================================================
  // S3 — Output Formatting (Store)
  // =========================================================================

  logic [BIT_DEPTH-1:0] stage_out_reg[0:3][0:15];

  always_comb begin
    for (int r = 0; r < 4; r++) begin
      for (int c = 0; c < 8; c++) begin
        stage_out_reg[r][7-c] = p_s2[r][c];
        stage_out_reg[r][8+c] = q_s2[r][c];
      end
    end
  end

  // Primary outputs
  assign stage_out    = stage_out_reg;
  assign mask_out     = mask_s2;
  assign edge_idx_out = edge_idx_s2;
  assign edge_valid   = valid_s2;

endmodule

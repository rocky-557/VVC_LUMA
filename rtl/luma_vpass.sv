`timescale 1ns / 1ps
// luma_vpass.sv - Luma V-Pass Deblocking Engine
// Controller-driven: edge_idx and row_group provided externally by luma_controller.
// Both are pipelined (2 cycles) and output as edge_idx_out / row_group_out so
// that luma_stage_buf write addresses are always aligned with the filtered data.

module luma_vpass #(
    parameter int BIT_DEPTH = 8
) (
    input logic clk,
    input logic rst_n,

    // S0: Load
    input logic [BIT_DEPTH-1:0] block_in  [0:3][0:3],
    input logic                 load_valid,

    // Controller-driven scanning (replaces internal block_cnt / edge_idx counters)
    input logic [4:0] edge_idx_in,  // from luma_controller: vp_edge_idx
    input logic [5:0] row_group_in, // from luma_controller: vp_row_group

    // Decision inputs (per edge, driven by upstream CU parser)
    input logic [7:0] qp_p,
    input logic [7:0] qp_q,
    input logic signed [7:0] beta_offset,
    input logic signed [7:0] tc_offset,
    input logic [2:0] maxFilterLengthP_in,
    input logic [2:0] maxFilterLengthQ_in,
    input logic [1:0] bS,
    input logic mode_vvc,
    input logic filter_gate,  // From controller: 0 = force filter off (HEVC skip)
    input logic [7:0] beta_in,
    input logic [9:0] tC_in,

    // Outputs: filtered window + pipeline-aligned addresses for stage_buf
    output logic [BIT_DEPTH-1:0] stage_out[0:3][0:15],
    output logic [15:0] mask_out,
    output logic [4:0] edge_idx_out,  // edge_idx_in delayed 2 cycles → wr_edge / wr_col_idx
    output logic [5:0] row_group_out,  // row_group_in delayed 2 cycles → wr_row_idx
    output logic edge_valid  // high when pipelined edge_idx >= 1
);

  // =========================================================================
  // S0 — Stage Buffer (4 rows × 16 cols): shifts left by 4 each load
  // =========================================================================
  logic [BIT_DEPTH-1:0] stage_buf[0:3][0:15];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      foreach (stage_buf[r, c]) stage_buf[r][c] <= '0;
    end else if (load_valid) begin
      for (int r = 0; r < 4; r++) begin
        // Shift left by 4
        for (int c = 0; c < 12; c++) stage_buf[r][c] <= stage_buf[r][c+4];
        // Load new 4×4 into rightmost 4 cols
        for (int c = 0; c < 4; c++) stage_buf[r][12+c] <= block_in[r][c];
      end
    end
  end

  // =========================================================================
  // Corner Masking (for Decision logic ONLY – uses edge_idx_in directly)
  // =========================================================================
  logic [BIT_DEPTH-1:0] masked_buf[0:3][0:15];

  always_comb begin
    masked_buf = stage_buf;
    if (edge_idx_in == 5'd1) begin
      for (int r = 0; r < 4; r++)
      for (int c = 0; c < 4; c++) masked_buf[r][c] = '0;  // zero leftmost block
    end else if (edge_idx_in == 5'd31) begin
      for (int r = 0; r < 4; r++)
      for (int c = 12; c < 16; c++) masked_buf[r][c] = '0;  // zero rightmost block
    end
  end

  // =========================================================================
  // S1 — Edge Decision (combinational)
  // =========================================================================
  logic [BIT_DEPTH-1:0] ext_p[0:3][0:7];
  logic [BIT_DEPTH-1:0] ext_q[0:3][0:7];

  always_comb begin
    for (int r = 0; r < 4; r++) begin
      for (int c = 0; c < 8; c++) begin
        ext_p[r][c] = masked_buf[r][7-c];  // p0 = col 7, p7 = col 0
        ext_q[r][c] = masked_buf[r][8+c];  // q0 = col 8, q7 = col 15
      end
    end
  end

  logic       filter_on_s1;
  logic [1:0] filter_type_s1;
  logic dEp_s1, dEq_s1;
  logic [2:0] maxFilterLengthP_s1, maxFilterLengthQ_s1;

  edge_decision #(
      .BIT_DEPTH(BIT_DEPTH)
  ) u_edge_decision (
      .p                   (ext_p),
      .q                   (ext_q),
      .beta                (beta_in),
      .tC                  (tC_in),
      .mode_vvc            (mode_vvc),
      .maxFilterLengthP_in (maxFilterLengthP_in),
      .maxFilterLengthQ_in (maxFilterLengthQ_in),
      .filter_on           (filter_on_s1),
      .dE                  (filter_type_s1),
      .dEp                 (dEp_s1),
      .dEq                 (dEq_s1),
      .maxFilterLengthP_out(maxFilterLengthP_s1),
      .maxFilterLengthQ_out(maxFilterLengthQ_s1)
  );

  // S1 Pipeline Registers
  logic [BIT_DEPTH-1:0] p_s1            [0:3][0:7];
  logic [BIT_DEPTH-1:0] q_s1            [0:3][0:7];
  logic [          4:0] edge_idx_s1;
  logic [          5:0] row_group_s1;
  logic                 valid_s1;
  logic [          9:0] tC_s1;
  logic                 filter_on_reg;
  logic [          1:0] filter_type_reg;
  logic dEp_reg, dEq_reg;
  logic [2:0] maxFilterLengthP_reg, maxFilterLengthQ_reg;
  logic [15:0] mask_s1_wire;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s1             <= 1'b0;
      edge_idx_s1          <= 5'd0;
      row_group_s1         <= 6'd0;
      tC_s1                <= '0;
      filter_on_reg        <= 1'b0;
      filter_type_reg      <= 2'b0;
      dEp_reg              <= 1'b0;
      dEq_reg              <= 1'b0;
      maxFilterLengthP_reg <= 3'd1;
      maxFilterLengthQ_reg <= 3'd1;
      foreach (p_s1[r, c]) p_s1[r][c] <= '0;
      foreach (q_s1[r, c]) q_s1[r][c] <= '0;
    end else if (load_valid) begin
      // edge_idx_in drives valid: edge 0 is pipeline prefill, edges 1-31 are real
      valid_s1             <= (edge_idx_in >= 5'd1);
      edge_idx_s1          <= edge_idx_in;
      row_group_s1         <= row_group_in;
      tC_s1                <= tC_in;
      filter_on_reg        <= filter_on_s1 & filter_gate;
      filter_type_reg      <= filter_type_s1;
      dEp_reg              <= dEp_s1;
      dEq_reg              <= dEq_s1;
      maxFilterLengthP_reg <= maxFilterLengthP_s1;
      maxFilterLengthQ_reg <= maxFilterLengthQ_s1;
      // Use unmasked stage_buf for data path (masking is decision-only)
      for (int r = 0; r < 4; r++) begin
        for (int c = 0; c < 8; c++) begin
          p_s1[r][c] <= stage_buf[r][7-c];
          q_s1[r][c] <= stage_buf[r][8+c];
        end
      end
    end
  end

  // =========================================================================
  // S2 — Filtering Core (4 parallel rows)
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
          .p_in            (p_s1[r]),
          .q_in            (q_s1[r]),
          .tC              (tC_s1),
          .filter_enable   (filter_on_reg),
          .filter_type     (filter_type_reg),
          .mode_vvc        (mode_vvc),
          .dEp             (dEp_reg),
          .dEq             (dEq_reg),
          .maxFilterLengthP(maxFilterLengthP_reg),
          .maxFilterLengthQ(maxFilterLengthQ_reg),
          .p_out           (p_filt[r]),
          .q_out           (q_filt[r]),
          .write_mask      (mask_s1_row[r])
      );
    end
  endgenerate

  assign mask_s1_wire = mask_s1_row[0];  // All rows share the same mask pattern

  // S2 Pipeline Registers
  logic [BIT_DEPTH-1:0] p_s2         [0:3][0:7];
  logic [BIT_DEPTH-1:0] q_s2         [0:3][0:7];
  logic [          4:0] edge_idx_s2;
  logic [          5:0] row_group_s2;
  logic                 valid_s2;
  logic [         15:0] mask_s2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s2     <= 1'b0;
      edge_idx_s2  <= 5'd0;
      row_group_s2 <= 6'd0;
      mask_s2      <= 16'h0;
      foreach (p_s2[r, c]) p_s2[r][c] <= '0;
      foreach (q_s2[r, c]) q_s2[r][c] <= '0;
    end else if (load_valid) begin
      valid_s2     <= valid_s1;
      edge_idx_s2  <= edge_idx_s1;
      row_group_s2 <= row_group_s1;
      mask_s2      <= mask_s1_wire;
      p_s2         <= p_filt;
      q_s2         <= q_filt;
    end
  end

  // =========================================================================
  // S3 — Output Formatting (combinational repack P/Q → flat 16-wide window)
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
  assign stage_out     = stage_out_reg;
  assign mask_out      = mask_s2;
  assign edge_idx_out  = edge_idx_s2;  // 2-cycle pipelined → aligns with wr_data
  assign row_group_out = row_group_s2;  // 2-cycle pipelined → aligns with wr_data
  assign edge_valid    = valid_s2;

endmodule

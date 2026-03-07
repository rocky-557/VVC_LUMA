`timescale 1ns / 1ps
// luma_hpass.sv - Luma H-Pass Deblocking Engine
// Flow per CTU row:
//   STALL (96 cyc) → ACTIVE edges 1-31 (31×32 cyc) → STALL → repeat
// Each active edge: col_cnt sweeps 0→31 (32 reads across full CTU width)
// Row address: row_idx = edge_cnt % 5 (circular 20-row buffer)

module luma_hpass #(
    parameter int BIT_DEPTH = 8
) (
    input logic load_valid,

    input logic        [7:0] qp_p,
    input logic        [7:0] qp_q,
    input logic signed [7:0] beta_offset,
    input logic signed [7:0] tc_offset,
    input logic        [2:0] maxFilterLengthP_in,
    input logic        [2:0] maxFilterLengthQ_in,
    input logic        [1:0] bS,
    input logic              clk,
    input logic              rst_n,
    input logic              mode_vvc,
    input logic        [7:0] beta_in,
    input logic        [9:0] tC_in,

    // Combinational input from luma_stage_buf (4x16 transposed read)
    input logic [BIT_DEPTH-1:0] block_in[0:3][0:15],

    // Address outputs → drive luma_stage_buf read port
    output logic [2:0] row_idx,
    output logic [4:0] col_idx,
    output logic       read_en,  // 1 = read data valid

    // Filtered outputs
    output logic [BIT_DEPTH-1:0] block_out      [0:3][0:15],
    output logic [         15:0] mask_out,                    // write mask
    output logic                 block_out_valid,
    output logic [          2:0] out_row_idx,
    output logic [          4:0] out_col_idx,
    output logic                 out_mask1,
    output logic                 out_mask31,

    // Corner masking → for decision logic internal usage
    output logic mask1,  // edge 1: mask top block
    output logic mask31  // edge 31: mask bottom block
);

  // =========================================================================
  // State machine
  // =========================================================================
  typedef enum logic [1:0] {
    STALL,
    ACTIVE
  } state_t;
  state_t state;

  logic [6:0] stall_cnt;  // 0-95
  logic [4:0] edge_cnt;  // 1-31
  logic [4:0] col_cnt;  // 0-31

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= STALL;
      stall_cnt <= 7'd0;
      edge_cnt  <= 5'd1;
      col_cnt   <= 5'd0;
    end else if (load_valid) begin
      case (state)

        STALL: begin
          if (stall_cnt == 7'd127) begin
            stall_cnt <= 7'd0;
            state     <= ACTIVE;
          end else begin
            stall_cnt <= stall_cnt + 1'b1;
          end
        end

        ACTIVE: begin
          if (col_cnt == 5'd31) begin
            col_cnt <= 5'd0;
            if (edge_cnt == 5'd31) begin
              edge_cnt <= 5'd1;
              state    <= STALL;
            end else begin
              edge_cnt <= edge_cnt + 1'b1;
            end
          end else begin
            col_cnt <= col_cnt + 1'b1;
          end
        end

        default: state <= STALL;
      endcase
    end
  end

  // Corner masking: zero top/bottom blocks for decision
  logic [BIT_DEPTH-1:0] masked_buf[0:3][0:15];

  always_comb begin
    masked_buf = block_in;
    if (mask1) begin
      for (int c = 0; c < 4; c++)
      for (int r = 0; r < 4; r++) masked_buf[c][r] = '0;  // zero top block (rows 0-3)
    end else if (mask31) begin
      for (int c = 0; c < 4; c++)
      for (int r = 12; r < 16; r++) masked_buf[c][r] = '0;  // zero bottom block (rows 12-15)
    end
  end

  // =========================================================================
  // S1 — Decision Pipelining (1 cycle latency)
  // =========================================================================

  // Arrange inputs for edge decision (P and Q pixels for 4 cols)
  logic [BIT_DEPTH-1:0] h_p[0:3][0:7];
  logic [BIT_DEPTH-1:0] h_q[0:3][0:7];

  always_comb begin
    for (int c = 0; c < 4; c++) begin
      for (int i = 0; i < 8; i++) begin
        h_p[c][i] = masked_buf[c][7-i];  // p0=row7, p7=row0
        h_q[c][i] = masked_buf[c][8+i];  // q0=row8, q7=row15
      end
    end
  end

  logic       filter_on_s1;
  logic [1:0] filter_type_s1;
  logic dEp_s1, dEq_s1;
  logic [2:0] mFLP_s1, mFLQ_s1;

  edge_decision #(
      .BIT_DEPTH(BIT_DEPTH)
  ) u_decision (
      .p                   (h_p),
      .q                   (h_q),
      .maxFilterLengthP_in (maxFilterLengthP_in),
      .maxFilterLengthQ_in (maxFilterLengthQ_in),
      .beta                (beta_in),
      .tC                  (tC_in),
      .mode_vvc            (mode_vvc),
      .filter_on           (filter_on_s1),
      .dE                  (filter_type_s1),
      .dEp                 (dEp_s1),
      .dEq                 (dEq_s1),
      .maxFilterLengthP_out(mFLP_s1),
      .maxFilterLengthQ_out(mFLQ_s1)
  );

  // Pipeline Registers S1
  logic [BIT_DEPTH-1:0] p_s1     [0:3][0:7];
  logic [BIT_DEPTH-1:0] q_s1     [0:3][0:7];
  logic                 valid_s1;
  logic [          9:0] tC_s1;
  logic [          2:0] row_s1;
  logic [          4:0] col_s1;
  logic mask1_s1, mask31_s1;

  logic       filter_on_reg;
  logic [1:0] filter_type_reg;
  logic dEp_reg, dEq_reg;
  logic [2:0] maxFilterLengthP_reg, maxFilterLengthQ_reg;
  logic [15:0] mask_s1_wire;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s1 <= 1'b0;
      row_s1 <= '0;
      col_s1 <= '0;
      mask1_s1 <= 1'b0;
      mask31_s1 <= 1'b0;
      foreach (p_s1[c, r]) p_s1[c][r] <= '0;
      foreach (q_s1[c, r]) q_s1[c][r] <= '0;
      tC_s1 <= '0;
      filter_on_reg <= 1'b0;
      filter_type_reg <= 2'b0;
      dEp_reg <= 1'b0;
      dEq_reg <= 1'b0;
      maxFilterLengthP_reg <= 3'd1;
      maxFilterLengthQ_reg <= 3'd1;
    end else if (load_valid) begin
      valid_s1 <= read_en;
      row_s1 <= row_idx;
      col_s1 <= col_idx;
      mask1_s1 <= mask1;
      mask31_s1 <= mask31;
      // Pipeline Decision Outputs
      filter_on_reg <= filter_on_s1;
      filter_type_reg <= filter_type_s1;
      dEp_reg <= dEp_s1;
      dEq_reg <= dEq_s1;
      maxFilterLengthP_reg <= mFLP_s1;
      maxFilterLengthQ_reg <= mFLQ_s1;
      for (int c = 0; c < 4; c++) begin
        for (int r = 0; r < 8; r++) begin
          p_s1[c][r] <= masked_buf[c][7-r];
          q_s1[c][r] <= masked_buf[c][8+r];
        end
      end
      tC_s1 <= tC_in;
    end
  end

  // =========================================================================
  // S2 — Filtering Core
  // =========================================================================
  logic [BIT_DEPTH-1:0] p_filt[0:3][0:7];
  logic [BIT_DEPTH-1:0] q_filt[0:3][0:7];

  genvar c_idx;
  generate
    for (c_idx = 0; c_idx < 4; c_idx++) begin : gen_filter
      luma_filter_core #(
          .BIT_DEPTH(BIT_DEPTH)
      ) u_hp_filt (
          .p_in(p_s1[c_idx]),
          .q_in(q_s1[c_idx]),
          .tC(tC_s1),
          .filter_enable(filter_on_reg),
          .filter_type(filter_type_reg),
          .mode_vvc(mode_vvc),
          .dEp(dEp_reg),
          .dEq(dEq_reg),
          .maxFilterLengthP(maxFilterLengthP_reg),
          .maxFilterLengthQ(maxFilterLengthQ_reg),
          .p_out(p_filt[c_idx]),
          .q_out(q_filt[c_idx]),
          .write_mask(mask_s1_row[c_idx])
      );
    end
  endgenerate

  logic [15:0] mask_s1_row[0:3];
  assign mask_s1_wire = mask_s1_row[0];

  // Pipeline Registers S2
  logic [BIT_DEPTH-1:0] p_s2     [0:3][0:7];
  logic [BIT_DEPTH-1:0] q_s2     [0:3][0:7];
  logic                 valid_s2;
  logic [          2:0] row_s2;
  logic [          4:0] col_s2;
  logic mask1_s2, mask31_s2;
  logic [15:0] mask_s2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s2 <= 1'b0;
      row_s2 <= '0;
      col_s2 <= '0;
      mask1_s2 <= 1'b0;
      mask31_s2 <= 1'b0;
      p_s2 <= '{default: '{default: 0}};
      q_s2 <= '{default: '{default: 0}};
      mask_s2 <= 16'h0;
    end else if (load_valid) begin
      valid_s2 <= valid_s1;
      row_s2 <= row_s1;
      col_s2 <= col_s1;
      mask1_s2 <= mask1_s1;
      mask31_s2 <= mask31_s1;
      p_s2 <= p_filt;
      q_s2 <= q_filt;
      mask_s2 <= mask_s1_wire;
    end
  end

  // Pipeline Registers S3
  logic [BIT_DEPTH-1:0] block_out_reg[0:3][0:15];
  logic                 valid_s3;
  logic [          2:0] row_s3;
  logic [          4:0] col_s3;
  logic mask1_s3, mask31_s3;
  logic [15:0] mask_s3;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s3 <= 1'b0;
      row_s3 <= '0;
      col_s3 <= '0;
      mask1_s3 <= 1'b0;
      mask31_s3 <= 1'b0;
      mask_s3 <= 16'h0;
      foreach (block_out_reg[c, r]) block_out_reg[c][r] <= '0;
    end else if (load_valid) begin
      valid_s3 <= valid_s2;
      row_s3 <= row_s2;
      col_s3 <= col_s2;
      mask1_s3 <= mask1_s2;
      mask31_s3 <= mask31_s2;
      mask_s3 <= mask_s2;
      for (int c = 0; c < 4; c++) begin
        for (int r = 0; r < 8; r++) begin
          block_out_reg[c][7-r] <= p_s2[c][r];
          block_out_reg[c][8+r] <= q_s2[c][r];
        end
      end
    end
  end

  // Output assignments
  assign read_en         = (state == ACTIVE) && load_valid;
  assign col_idx         = col_cnt;
  assign row_idx         = (edge_cnt + 4) % 6;  // edge_cnt 1 maps to row_idx 5 (rows 20-23)
  assign mask1           = (state == ACTIVE) && (edge_cnt == 5'd1);
  assign mask31          = (state == ACTIVE) && (edge_cnt == 5'd31);

  assign block_out       = block_out_reg;
  assign mask_out        = mask_s3;
  assign block_out_valid = valid_s3;
  assign out_row_idx     = row_s3;
  assign out_col_idx     = col_s3;
  assign out_mask1       = mask1_s3;
  assign out_mask31      = mask31_s3;

endmodule

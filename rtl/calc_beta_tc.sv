`timescale 1ns / 1ps
module calc_beta_tc (
    input  logic              mode_vvc,     // 0=HEVC, 1=VVC
    input  logic        [1:0] bS,           // Boundary Strength (0, 1, 2)
    input  logic        [7:0] qp_p,
    qp_q,  // Quantization Parameters
    input  logic signed [7:0] beta_offset,
    tc_offset,  // Slice offsets
    output logic        [7:0] beta,         // Threshold Beta
    output logic        [9:0] tC            // Threshold tC (VVC up to 395)
);

  logic [7:0] qp_avg;
  logic signed [9:0] q_beta_idx_signed;
  logic signed [9:0] q_tc_idx_signed;
  logic [6:0] q_beta_idx;
  logic [6:0] q_tc_idx;

  // Beta Table (Shared for HEVC/VVC 0-63)
  logic [7:0] beta_table[0:63] = '{
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      6,
      7,
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      15,
      16,
      17,
      18,
      20,
      22,
      24,
      26,
      28,
      30,
      32,
      34,
      36,
      38,
      40,
      42,
      44,
      46,
      48,
      50,
      52,
      54,
      56,
      58,
      60,
      62,
      64,
      66,
      68,
      70,
      72,
      74,
      76,
      78,
      80,
      82,
      84,
      86,
      88
  };

  // HEVC tC Table (0-63)
  logic [7:0] tc_table_hevc[0:63] = '{
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      1,
      1,
      1,
      1,
      1,
      1,
      1,
      1,
      2,
      2,
      2,
      2,
      3,
      3,
      3,
      3,
      4,
      4,
      4,
      5,
      5,
      6,
      6,
      7,
      8,
      9,
      10,
      11,
      13,
      14,
      16,
      18,
      20,
      22,
      24,
      26,
      28,
      30,
      32,
      34,
      36,
      38,
      40,
      42,
      44
  };

  // VVC tC Table (H.266 Table 43, 0-65)
  logic [9:0] tc_table_vvc[0:65] = '{
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      3,
      4,
      4,
      4,
      4,
      5,
      5,
      5,
      5,
      7,
      7,
      8,
      9,
      10,
      10,
      11,
      13,
      14,
      15,
      17,
      19,
      21,
      24,
      25,
      29,
      33,
      36,
      41,
      45,
      51,
      57,
      64,
      71,
      80,
      89,
      100,
      112,
      125,
      141,
      157,
      177,
      198,
      222,
      250,
      280,
      314,
      352,
      395
  };

  // 1. Calculate Average QP
  assign qp_avg = (qp_p + qp_q + 1) >> 1;

  // 2. Apply Offsets (H.266 8.8.3.6.3 Eq 1269, 1271)
  assign q_beta_idx_signed = $signed({2'b0, qp_avg}) + (beta_offset <<< 1);

  // VVC tC index derivation (H.266 8.8.3.6.2 Eq 1271)
  // Q = Clip3( 0, 65, qP + 2 * ( bS - 1 ) + offset << 1 )
  logic signed [9:0] qp_tc_base;
  assign qp_tc_base = mode_vvc ? ($signed(
      {2'b0, qp_avg}
  ) + $signed(
      {8'b0, 2'd2} * ($signed({1'b0, bS}) - 1)
  )) : $signed(
      {2'b0, qp_avg}
  );
  assign q_tc_idx_signed = qp_tc_base + (tc_offset <<< 1);

  // 3. Clip indices
  always_comb begin
    // Beta index 0-63
    if (q_beta_idx_signed < 0) q_beta_idx = 7'd0;
    else if (q_beta_idx_signed > 63) q_beta_idx = 7'd63;
    else q_beta_idx = q_beta_idx_signed[6:0];

    // tC index 0-63 (HEVC) or 0-65 (VVC)
    if (q_tc_idx_signed < 0) q_tc_idx = 7'd0;
    else if (mode_vvc && q_tc_idx_signed > 65) q_tc_idx = 7'd65;
    else if (!mode_vvc && q_tc_idx_signed > 63) q_tc_idx = 7'd63;
    else q_tc_idx = q_tc_idx_signed[6:0];
  end

  // 4. Lookup Logic
  always_comb begin
    if (bS == 0) begin
      beta = 8'd0;
      tC   = 10'd0;
    end else begin
      beta = beta_table[q_beta_idx[5:0]];
      if (mode_vvc) begin
        // VVC tC values in Table 43 are for 10-bit. Scale to 8-bit (divide by 4)
        tC = (tc_table_vvc[q_tc_idx] + 2) >> 2;
      end else begin
        tC = {2'b0, tc_table_hevc[q_tc_idx[5:0]]};
      end
    end
  end

endmodule


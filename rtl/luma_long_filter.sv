`timescale 1ns / 1ps

// luma_long_filter.sv - VVC Luma Long Filter (7-tap/5-tap/3-tap)
// Corrected bit-depth and arithmetic scaling

module luma_long_filter #(
    parameter int BIT_DEPTH = 8,
    parameter int INTERNAL_WIDTH = 16,
    parameter int MULT_WIDTH = 24  // Increased for safety
) (
    input  logic [BIT_DEPTH-1:0] p_in            [0:7],
    input  logic [BIT_DEPTH-1:0] q_in            [0:7],
    input  logic [          2:0] maxFilterLengthP,
    input  logic [          2:0] maxFilterLengthQ,
    input  logic [          9:0] tC,
    output logic [BIT_DEPTH-1:0] p_out           [0:6],
    output logic [BIT_DEPTH-1:0] q_out           [0:6]
);

  logic signed [INTERNAL_WIDTH-1:0] s_p  [0:7];
  logic signed [INTERNAL_WIDTH-1:0] s_q  [0:7];
  logic signed [INTERNAL_WIDTH-1:0] s_tC;

  assign s_tC = $signed({1'b0, tC});

  genvar k;
  generate
    for (k = 0; k < 8; k++) begin : gen_input_signed
      assign s_p[k] = $signed({1'b0, p_in[k]});
      assign s_q[k] = $signed({1'b0, q_in[k]});
    end
  endgenerate

  // Reference samples (refP, refQ)
  logic signed [INTERNAL_WIDTH-1:0] refP, refQ;
  assign refP = (s_p[maxFilterLengthP] + s_p[maxFilterLengthP-1] + 1) >>> 1;
  assign refQ = (s_q[maxFilterLengthQ] + s_q[maxFilterLengthQ-1] + 1) >>> 1;

  // refMiddle calculation (Eq 1383-1388)
  logic signed [INTERNAL_WIDTH-1:0] refMiddle;
  always_comb begin
    if (maxFilterLengthP == 3'd5 && maxFilterLengthQ == 3'd5)
      refMiddle = (s_p[4] + s_p[3] + ((s_p[2] + s_p[1] + s_p[0] + s_q[0] + s_q[1] + s_q[2]) << 1) + s_q[3] + s_q[4] + 8) >>> 4;
    else if (maxFilterLengthP == 3'd7 && maxFilterLengthQ == 3'd7)
      refMiddle = (s_p[6] + s_p[5] + s_p[4] + s_p[3] + s_p[2] + s_p[1] + ((s_p[0] + s_q[0]) << 1) + s_q[1] + s_q[2] + s_q[3] + s_q[4] + s_q[5] + s_q[6] + 8) >>> 4;
    else if ((maxFilterLengthQ == 5 && maxFilterLengthP == 7) || (maxFilterLengthQ == 7 && maxFilterLengthP == 5))
      refMiddle = (s_p[5] + s_p[4] + s_p[3] + s_p[2] + ((s_p[1] + s_p[0] + s_q[0] + s_q[1]) << 1) + s_q[2] + s_q[3] + s_q[4] + s_q[5] + 8) >>> 4;
    else if ((maxFilterLengthQ == 5 && maxFilterLengthP == 3) || (maxFilterLengthQ == 3 && maxFilterLengthP == 5))
      refMiddle = (s_p[3] + s_p[2] + s_p[1] + s_p[0] + s_q[0] + s_q[1] + s_q[2] + s_q[3] + 4) >>> 3;
    else if (maxFilterLengthQ == 7 && maxFilterLengthP == 3)
      refMiddle = (((s_p[2] + s_p[1] + s_p[0] + s_q[0]) << 1) + s_p[0] + s_p[1] + s_q[1] + s_q[2] + s_q[3] + s_q[4] + s_q[5] + s_q[6] + 8) >>> 4;
    else
      refMiddle = (s_p[6] + s_p[5] + s_p[4] + s_p[3] + s_p[2] + s_p[1] + ((s_q[2] + s_q[1] + s_q[0] + s_p[0]) << 1) + s_q[0] + s_q[1] + 8) >>> 4;
  end

  // Filter Coefficients
  logic [6:0] f_coeff[0:6];
  logic [2:0] tCPD[0:6];
  logic [6:0] g_coeff[0:6];
  logic [2:0] tCQD[0:6];

  always_comb begin
    f_coeff = '{0, 0, 0, 0, 0, 0, 0};
    tCPD = '{0, 0, 0, 0, 0, 0, 0};
    g_coeff = '{0, 0, 0, 0, 0, 0, 0};
    tCQD = '{0, 0, 0, 0, 0, 0, 0};
    if (maxFilterLengthP == 7) begin
      f_coeff = '{59, 50, 41, 32, 23, 14, 5};
      tCPD = '{6, 5, 4, 3, 2, 1, 1};
    end else if (maxFilterLengthP == 5) begin
      f_coeff[0:4] = '{58, 45, 32, 19, 6};
      tCPD[0:4] = '{6, 5, 4, 3, 2};
    end else if (maxFilterLengthP == 3) begin
      f_coeff[0:2] = '{53, 32, 11};
      tCPD[0:2] = '{6, 4, 2};
    end

    if (maxFilterLengthQ == 7) begin
      g_coeff = '{59, 50, 41, 32, 23, 14, 5};
      tCQD = '{6, 5, 4, 3, 2, 1, 1};
    end else if (maxFilterLengthQ == 5) begin
      g_coeff[0:4] = '{58, 45, 32, 19, 6};
      tCQD[0:4] = '{6, 5, 4, 3, 2};
    end else if (maxFilterLengthQ == 3) begin
      g_coeff[0:2] = '{53, 32, 11};
      tCQD[0:2] = '{6, 4, 2};
    end
  end

  genvar i;
  generate
    for (i = 0; i < 7; i++) begin : gen_filter
      logic signed [MULT_WIDTH-1:0] wP, wQ;
      logic signed [INTERNAL_WIDTH-1:0] p_filt, q_filt;
      logic signed [INTERNAL_WIDTH-1:0] clipP, clipQ;
      logic signed [INTERNAL_WIDTH-1:0] cp, cq;

      // P-side
      assign wP = (refMiddle * $signed(
          {1'b0, f_coeff[i]}
      )) + (refP * (64 - $signed(
          {1'b0, f_coeff[i]}
      ))) + 32;
      assign p_filt = wP >>> 6;
      assign clipP = (s_tC * $signed({1'b0, tCPD[i]})) >>> 1;
      clip3 #(
          .WIDTH(INTERNAL_WIDTH)
      ) u_cp (
          .min_val(s_p[i] - clipP),
          .max_val(s_p[i] + clipP),
          .val(p_filt),
          .clamped_val(cp)
      );

      // Q-side
      assign wQ = (refMiddle * $signed(
          {1'b0, g_coeff[i]}
      )) + (refQ * (64 - $signed(
          {1'b0, g_coeff[i]}
      ))) + 32;
      assign q_filt = wQ >>> 6;
      assign clipQ = (s_tC * $signed({1'b0, tCQD[i]})) >>> 1;
      clip3 #(
          .WIDTH(INTERNAL_WIDTH)
      ) u_cq (
          .min_val(s_q[i] - clipQ),
          .max_val(s_q[i] + clipQ),
          .val(q_filt),
          .clamped_val(cq)
      );

      // Final Clip1 (0-255) to prevent bit-slice wrap-around
      logic [BIT_DEPTH-1:0] cp_final, cq_final;
      always_comb begin
        if (cp < 0) cp_final = 8'd0;
        else if (cp > 255) cp_final = 8'd255;
        else cp_final = cp[BIT_DEPTH-1:0];

        if (cq < 0) cq_final = 8'd0;
        else if (cq > 255) cq_final = 8'd255;
        else cq_final = cq[BIT_DEPTH-1:0];
      end

      assign p_out[i] = (i < maxFilterLengthP) ? cp_final : p_in[i];
      assign q_out[i] = (i < maxFilterLengthQ) ? cq_final : q_in[i];
    end
  endgenerate
endmodule

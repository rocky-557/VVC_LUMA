`timescale 1ns / 1ps
// luma_strong_filter.sv - Common Luma Strong Filter for VVC and HEVC
// Arithmetic verified against H.266 8.8.3.6.7 and H.265 8.7.2.5.3
module luma_strong_filter #(
    parameter int BIT_DEPTH = 8,
    parameter int INTERNAL_WIDTH = 16
) (
    input  logic [BIT_DEPTH-1:0] p_in [0:3],  // Samples p0 to p3
    input  logic [BIT_DEPTH-1:0] q_in [0:3],  // Samples q0 to q3
    input  logic [          9:0] tC,          // Threshold (VVC up to 395)
    input  logic                 mode,        // 0=HEVC, 1=VVC
    output logic [BIT_DEPTH-1:0] p_out[0:2],  // Filtered p0, p1, p2
    output logic [BIT_DEPTH-1:0] q_out[0:2]   // Filtered q0, q1, q2
);

  logic signed [INTERNAL_WIDTH-1:0] s_p[0:3];
  logic signed [INTERNAL_WIDTH-1:0] s_q[0:3];

  // Convert inputs to signed
  genvar k;
  generate
    for (k = 0; k < 4; k++) begin : gen_input_signed
      assign s_p[k] = $signed({1'b0, p_in[k]});
      assign s_q[k] = $signed({1'b0, q_in[k]});
    end
  endgenerate

  // Intermediate smoothing sums (shared arithmetic)
  logic signed [INTERNAL_WIDTH-1:0] p0_tmp, p1_tmp, p2_tmp;
  logic signed [INTERNAL_WIDTH-1:0] q0_tmp, q1_tmp, q2_tmp;

  // P-side smoothing: ( p2 + 2*p1 + 2*p0 + 2*q0 + q1 + 4 ) >> 3
  assign p0_tmp = (s_p[2] + (s_p[1] << 1) + (s_p[0] << 1) + (s_q[0] << 1) + s_q[1] + 4) >>> 3;

  // ( p2 + p1 + p0 + q0 + 2 ) >> 2 [VVC]
  // ( p1 + p0 + q0 + q1 + 2 ) >> 2 [HEVC]
  assign p1_tmp = mode ? (s_p[2] + s_p[1] + s_p[0] + s_q[0] + 2) >>> 2 :
                         (s_p[1] + s_p[0] + s_q[0] + s_q[1] + 2) >>> 2;

  // ( 2*p3 + 3*p2 + p1 + p0 + q0 + 4 ) >> 3
  assign p2_tmp = ((s_p[3] << 1) + s_p[2] + (s_p[2] << 1) + s_p[1] + s_p[0] + s_q[0] + 4) >>> 3;

  // Q-side smoothing (symmetric)
  assign q0_tmp = (s_q[2] + (s_q[1] << 1) + (s_q[0] << 1) + (s_p[0] << 1) + s_p[1] + 4) >>> 3;
  // Symmetric to p1
  assign q1_tmp = mode ? (s_q[2] + s_q[1] + s_q[0] + s_p[0] + 2) >>> 2 :
                         (s_q[1] + s_q[0] + s_p[0] + s_p[1] + 2) >>> 2;
  assign q2_tmp = ((s_q[3] << 1) + s_q[2] + (s_q[2] << 1) + s_q[1] + s_q[0] + s_p[0] + 4) >>> 3;

  // Parameterized clipping using clip3_lsf
  clip3_lsf #(
      .BIT_DEPTH(BIT_DEPTH),
      .INTERNAL_WIDTH(INTERNAL_WIDTH)
  ) u_clip_p0 (
      .val(p0_tmp),
      .p_orig(p_in[0]),
      .tC(tC),
      .index(2'd0),
      .mode(mode),
      .clamped_val(p_out[0])
  );

  clip3_lsf #(
      .BIT_DEPTH(BIT_DEPTH),
      .INTERNAL_WIDTH(INTERNAL_WIDTH)
  ) u_clip_p1 (
      .val(p1_tmp),
      .p_orig(p_in[1]),
      .tC(tC),
      .index(2'd1),
      .mode(mode),
      .clamped_val(p_out[1])
  );

  clip3_lsf #(
      .BIT_DEPTH(BIT_DEPTH),
      .INTERNAL_WIDTH(INTERNAL_WIDTH)
  ) u_clip_p2 (
      .val(p2_tmp),
      .p_orig(p_in[2]),
      .tC(tC),
      .index(2'd2),
      .mode(mode),
      .clamped_val(p_out[2])
  );

  clip3_lsf #(
      .BIT_DEPTH(BIT_DEPTH),
      .INTERNAL_WIDTH(INTERNAL_WIDTH)
  ) u_clip_q0 (
      .val(q0_tmp),
      .p_orig(q_in[0]),
      .tC(tC),
      .index(2'd0),
      .mode(mode),
      .clamped_val(q_out[0])
  );

  clip3_lsf #(
      .BIT_DEPTH(BIT_DEPTH),
      .INTERNAL_WIDTH(INTERNAL_WIDTH)
  ) u_clip_q1 (
      .val(q1_tmp),
      .p_orig(q_in[1]),
      .tC(tC),
      .index(2'd1),
      .mode(mode),
      .clamped_val(q_out[1])
  );

  clip3_lsf #(
      .BIT_DEPTH(BIT_DEPTH),
      .INTERNAL_WIDTH(INTERNAL_WIDTH)
  ) u_clip_q2 (
      .val(q2_tmp),
      .p_orig(q_in[2]),
      .tC(tC),
      .index(2'd2),
      .mode(mode),
      .clamped_val(q_out[2])
  );

endmodule

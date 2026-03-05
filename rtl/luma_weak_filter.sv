`timescale 1ns/1ps
// luma_weak_filter.sv - Common Luma Weak Filter for VVC and HEVC
// Arithmetic verified against H.266 8.8.3.6.7 and H.265 8.7.2.5.3
module luma_weak_filter #(
    parameter int BIT_DEPTH = 8,
    parameter int INTERNAL_WIDTH = 16
) (
    input  logic [BIT_DEPTH-1:0] p_in [0:2],  // Samples p0, p1, p2
    input  logic [BIT_DEPTH-1:0] q_in [0:2],  // Samples q0, q1, q2
    input  logic [          9:0] tC,          // Threshold (VVC up to 395)
    input  logic                 dEp,
    dEq,  // Decisions
    output logic [BIT_DEPTH-1:0] p_out[0:1],  // Filtered p0, p1
    output logic [BIT_DEPTH-1:0] q_out[0:1]   // Filtered q0, q1
);

  logic signed [INTERNAL_WIDTH-1:0] s_p[0:2];
  logic signed [INTERNAL_WIDTH-1:0] s_q[0:2];
  logic signed [INTERNAL_WIDTH-1:0] s_tC;

  logic signed [INTERNAL_WIDTH-1:0] delta;
  logic signed [INTERNAL_WIDTH-1:0] delta_clipped;
  logic signed [INTERNAL_WIDTH-1:0] delta_p, delta_q;

  // Convert inputs to signed
  genvar k;
  generate
    for (k = 0; k < 3; k++) begin : gen_input_signed
      assign s_p[k] = $signed({1'b0, p_in[k]});
      assign s_q[k] = $signed({1'b0, q_in[k]});
    end
  endgenerate
  assign s_tC  = $signed({1'b0, tC});

  // 1. Calculate main delta: ( 9 * ( q0 - p0 ) - 3 * ( q1 - p1 ) + 8 ) >> 4
  assign delta = ((9 * (s_q[0] - s_p[0])) - (3 * (s_q[1] - s_p[1])) + 8) >>> 4;

  // 2. Clip main delta: delta = Clip3( -tC, tC, delta )
  clip3 #(
      .WIDTH(INTERNAL_WIDTH)
  ) u_clip_delta (
      .min_val(-s_tC),
      .max_val(s_tC),
      .val(delta),
      .clamped_val(delta_clipped)
  );

  // 3. P0/Q0 filtering:
  // p0_out = Clip1( p0 + delta )
  // q0_out = Clip1( q0 - delta )
  assign p_out[0] = clip1(s_p[0] + delta_clipped);
  assign q_out[0] = clip1(s_q[0] - delta_clipped);

  // 4. P1 filtering: deltaP = Clip3( -( tC >> 1 ), tC >> 1, ( ( ( p2 + p0 + 1 ) >> 1 ) - p1 + delta ) >> 1 )
  assign delta_p  = (((s_p[2] + s_p[0] + 1) >>> 1) - s_p[1] + delta_clipped) >>> 1;

  logic signed [INTERNAL_WIDTH-1:0] delta_p_clipped;
  clip3 #(
      .WIDTH(INTERNAL_WIDTH)
  ) u_clip_p1 (
      .min_val(-(s_tC >>> 1)),
      .max_val(s_tC >>> 1),
      .val(delta_p),
      .clamped_val(delta_p_clipped)
  );

  // p1_out = Clip1( p1 + deltaP ) if dEp == 1
  assign p_out[1] = dEp ? clip1(s_p[1] + delta_p_clipped) : p_in[1];

  // 5. Q1 filtering: deltaQ = Clip3( -( tC >> 1 ), tC >> 1, ( ( ( q2 + q0 + 1 ) >> 1 ) - q1 - delta ) >> 1 )
  assign delta_q  = (((s_q[2] + s_q[0] + 1) >>> 1) - s_q[1] - delta_clipped) >>> 1;

  logic signed [INTERNAL_WIDTH-1:0] delta_q_clipped;
  clip3 #(
      .WIDTH(INTERNAL_WIDTH)
  ) u_clip_q1 (
      .min_val(-(s_tC >>> 1)),
      .max_val(s_tC >>> 1),
      .val(delta_q),
      .clamped_val(delta_q_clipped)
  );

  // q1_out = Clip1( q1 + deltaQ ) if dEq == 1
  assign q_out[1] = dEq ? clip1(s_q[1] + delta_q_clipped) : q_in[1];

  // Final 8-bit unsigned clip function (Clip1)
  function automatic [BIT_DEPTH-1:0] clip1(input signed [INTERNAL_WIDTH-1:0] val);
    if (val < 0) return 8'd0;
    else if (val > 255) return 8'd255;
    else return val[BIT_DEPTH-1:0];
  endfunction

endmodule

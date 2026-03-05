`timescale 1ns/1ps
// luma_filter_core.sv - Unified Luma Filter Engine
// Wraps Weak, Strong, and Long filters.
// Input: 8 pixels P, 8 pixels Q (Worst case VVC)
// Output: 8 pixels P, 8 pixels Q (Filtered + Pass-through)

module luma_filter_core #(
    parameter int BIT_DEPTH = 8
) (
    // Data Inputs (Line of 16 pixels)
    input logic [BIT_DEPTH-1:0] p_in[0:7],
    input logic [BIT_DEPTH-1:0] q_in[0:7],

    // Control Inputs
    input logic [9:0] tC,             // Threshold (VVC up to 395)
    input logic       filter_enable,  // 1 = Filter ON
    input logic [1:0] filter_type,    // 0=Weak, 1=Strong, 2=Long
    input logic       mode_vvc,       // 0=HEVC, 1=VVC (for Strong clip)

    // Weak Filter specific checks
    input logic dEp,
    dEq,  // Enable p1/q1 filtering for Weak

    // Long Filter specific lengths
    input logic [2:0] maxFilterLengthP,  // 1, 3, 5, 7
    input logic [2:0] maxFilterLengthQ,  // 1, 3, 5, 7

    // Outputs
    output logic [BIT_DEPTH-1:0] p_out[0:7],
    output logic [BIT_DEPTH-1:0] q_out[0:7]
);

  // =========================================================================
  // Internal Wires for Sub-module Outputs
  // =========================================================================

  // Weak Filter Outputs (Modifies 0..1, Pass 2..7)
  logic [BIT_DEPTH-1:0] p_out_weak[0:1], q_out_weak[0:1];

  // Strong Filter Outputs (Modifies 0..2, Pass 3..7)
  logic [BIT_DEPTH-1:0] p_out_strong[0:2], q_out_strong[0:2];

  // Long Filter Outputs (Modifies up to 0..6, Pass 7)
  logic [BIT_DEPTH-1:0] p_out_long[0:6], q_out_long[0:6];

  // =========================================================================
  // Sub-Module Instantiations
  // =========================================================================

  // 1. Weak Filter
  // Note: p_in[0:2]/q_in[0:2] slice
  luma_weak_filter #(
      .BIT_DEPTH(BIT_DEPTH)
  ) u_weak (
      .p_in (p_in[0:2]),
      .q_in (q_in[0:2]),
      .tC   (tC),
      .dEp  (dEp),
      .dEq  (dEq),
      .p_out(p_out_weak),
      .q_out(q_out_weak)
  );

  // 2. Strong Filter (Common Short)
  // Note: p_in[0:3]/q_in[0:3] slice
  luma_strong_filter #(
      .BIT_DEPTH(BIT_DEPTH)
  ) u_strong (
      .p_in (p_in[0:3]),
      .q_in (q_in[0:3]),
      .tC   (tC),
      .mode (mode_vvc),
      .p_out(p_out_strong),
      .q_out(q_out_strong)
  );

  // 3. Long Filter (VVC Only)
  // Note: Uses full [0:7]
  luma_long_filter #(
      .BIT_DEPTH(BIT_DEPTH)
  ) u_long (
      .p_in (p_in),
      .q_in (q_in),
      .maxFilterLengthP(maxFilterLengthP),
      .maxFilterLengthQ(maxFilterLengthQ),
      .tC   (tC),
      .p_out(p_out_long),
      .q_out(q_out_long)
  );

  // =========================================================================
  // Output Muxing (Selection & Pass-through Logic)
  // =========================================================================

  always_comb begin
    // Default: Pass-through everything
    p_out = p_in;
    q_out = q_in;

    if (filter_enable) begin
      case (filter_type)
        2'd0: begin  // WEAK
          // Weak modifies p0, p1, q0, q1. Others passed through.
          // Assumes connection p_out_weak[0] -> p0, etc.
          p_out[0] = p_out_weak[0];
          p_out[1] = p_out_weak[1];
          q_out[0] = q_out_weak[0];
          q_out[1] = q_out_weak[1];
        end

        2'd1: begin  // STRONG
          // Strong modifies p0..p2, q0..q2.
          p_out[0] = p_out_strong[0];
          p_out[1] = p_out_strong[1];
          p_out[2] = p_out_strong[2];

          q_out[0] = q_out_strong[0];
          q_out[1] = q_out_strong[1];
          q_out[2] = q_out_strong[2];
        end

        2'd2: begin  // LONG
          // Long modifies p0..p6, q0..q6. 
          // p7, q7 are reference only, so pass-through.
          for (int i = 0; i < 7; i++) begin
            p_out[i] = p_out_long[i];
            q_out[i] = q_out_long[i];
          end
        end

        default: begin
          // Should not happen if enable is 1, but safe fallback
          p_out = p_in;
          q_out = q_in;
        end
      endcase
    end
  end

endmodule

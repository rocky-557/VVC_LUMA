`timescale 1ns / 1ps
// edge_decision.sv - Luma Edge Filter Decision Logic (Strict VVC/HEVC)

module edge_decision #(
    parameter int BIT_DEPTH = 8
) (
    input logic [BIT_DEPTH-1:0] p                  [0:3][0:7],
    input logic [BIT_DEPTH-1:0] q                  [0:3][0:7],
    input logic [          7:0] beta,
    input logic [          9:0] tC,
    input logic                 mode_vvc,
    input logic [          2:0] maxFilterLengthP_in,
    input logic [          2:0] maxFilterLengthQ_in,

    output logic       filter_on,
    output logic [1:0] dE,
    output logic       dEp,
    dEq,
    output logic [2:0] maxFilterLengthP_out,
    output logic [2:0] maxFilterLengthQ_out
);

  // -------------------------------------------------------------------------
  // Short-path gradients (dp0, dq0, dp3, dq3) and d
  // -------------------------------------------------------------------------
  logic [BIT_DEPTH+1:0] dp0, dq0, dp3, dq3;
  logic [BIT_DEPTH+3:0] d;

  assign dp0 = abs_diff_3tap(p[0][2], p[0][1], p[0][0]);
  assign dq0 = abs_diff_3tap(q[0][2], q[0][1], q[0][0]);
  assign dp3 = abs_diff_3tap(p[3][2], p[3][1], p[3][0]);
  assign dq3 = abs_diff_3tap(q[3][2], q[3][1], q[3][0]);
  assign d   = dp0 + dq0 + dp3 + dq3;

  // -------------------------------------------------------------------------
  // Large-block flags
  // -------------------------------------------------------------------------
  logic sidePisLargeBlk, sideQisLargeBlk;
  assign sidePisLargeBlk = (maxFilterLengthP_in > 3);
  assign sideQisLargeBlk = (maxFilterLengthQ_in > 3);

  // -------------------------------------------------------------------------
  // Step 8: Averaged gradients (dp0L etc.) for large-block path
  // -------------------------------------------------------------------------
  logic [BIT_DEPTH+1:0] dp0L, dp3L, dq0L, dq3L;
  assign dp0L = sidePisLargeBlk ? ((dp0 + abs_diff_3tap(p[0][5], p[0][4], p[0][3]) + 1) >> 1) : dp0;
  assign dp3L = sidePisLargeBlk ? ((dp3 + abs_diff_3tap(p[3][5], p[3][4], p[3][3]) + 1) >> 1) : dp3;
  assign dq0L = sideQisLargeBlk ? ((dq0 + abs_diff_3tap(q[0][5], q[0][4], q[0][3]) + 1) >> 1) : dq0;
  assign dq3L = sideQisLargeBlk ? ((dq3 + abs_diff_3tap(q[3][5], q[3][4], q[3][3]) + 1) >> 1) : dq3;

  // dL: averaged-gradient sum used as gate in large-block path (§8.8.3.6.2 step 8f)
  logic [BIT_DEPTH+3:0] dL;
  assign dL = dp0L + dq0L + dp3L + dq3L;

  // -------------------------------------------------------------------------
  // sp/sq/spq samples
  // -------------------------------------------------------------------------
  logic [BIT_DEPTH:0] sp0, sq0, spq0, sp3, sq3, spq3;
  assign sp0  = abs_diff(p[0][3], p[0][0]);
  assign sq0  = abs_diff(q[0][3], q[0][0]);
  assign spq0 = abs_diff(p[0][0], q[0][0]);
  assign sp3  = abs_diff(p[3][3], p[3][0]);
  assign sq3  = abs_diff(q[3][3], q[3][0]);
  assign spq3 = abs_diff(p[3][0], q[3][0]);

  // Extended sp/sq for 7-tap (§8.8.3.6.2 step 8c/8d)
  logic [BIT_DEPTH+1:0] sp0L, sp3L, sq0L, sq3L;
  assign sp0L = (maxFilterLengthP_in == 7) ? (sp0 + abs_diff_4tap(
      p[0][7], p[0][6], p[0][5], p[0][4]
  )) : sp0;
  assign sp3L = (maxFilterLengthP_in == 7) ? (sp3 + abs_diff_4tap(
      p[3][7], p[3][6], p[3][5], p[3][4]
  )) : sp3;
  assign sq0L = (maxFilterLengthQ_in == 7) ? (sq0 + abs_diff_4tap(
      q[0][4], q[0][5], q[0][6], q[0][7]
  )) : sq0;
  assign sq3L = (maxFilterLengthQ_in == 7) ? (sq3 + abs_diff_4tap(
      q[3][4], q[3][5], q[3][6], q[3][7]
  )) : sq3;

  // -------------------------------------------------------------------------
  // dSam thresholds (§8.8.3.6.6)
  // sThr1 = (3*β)>>5 for large-block, β>>3 otherwise
  // sThr2 = β>>2 always
  // -------------------------------------------------------------------------
  logic [7:0] sThr1, sThr2;
  assign sThr1 = (sidePisLargeBlk || sideQisLargeBlk) ? ((beta + (beta << 1)) >> 5) : (beta >> 3);
  assign sThr2 = (beta >> 2);

  // dSam line 0
  logic [BIT_DEPTH+1:0] sp0_fin, sq0_fin;
  assign sp0_fin = sidePisLargeBlk ? ((sp0L + sp0 + 1) >> 1) : sp0L;
  assign sq0_fin = sideQisLargeBlk ? ((sq0L + sq0 + 1) >> 1) : sq0L;
  logic dSam0, dSam3;
  assign dSam0 = (((dp0L + dq0L) << 1) < sThr2) &&
                 ((sp0_fin + sq0_fin)   < sThr1) &&
                 (spq0                  < ((5 * tC + 1) >> 1));

  // dSam line 3
  logic [BIT_DEPTH+1:0] sp3_fin, sq3_fin;
  assign sp3_fin = sidePisLargeBlk ? ((sp3L + sp3 + 1) >> 1) : sp3L;
  assign sq3_fin = sideQisLargeBlk ? ((sq3L + sq3 + 1) >> 1) : sq3L;
  assign dSam3 = (((dp3L + dq3L) << 1) < sThr2) &&
                 ((sp3_fin + sq3_fin)   < sThr1) &&
                 (spq3                  < ((5 * tC + 1) >> 1));

  // -------------------------------------------------------------------------
  // Main decision (§8.8.3.6.2 steps 8f + 9)
  // -------------------------------------------------------------------------
  always_comb begin
    maxFilterLengthP_out = 3'd1;
    maxFilterLengthQ_out = 3'd1;
    dE = 2'd0;
    dEp = 1'b0;
    dEq = 1'b0;
    filter_on = 1'b0;

    if (mode_vvc) begin

      // ---- Large-block path (§8.8.3.6.2 step 8) ----
      // If either side is large block, ONLY dL gate applies.
      // If dL >= beta → NO filtering at all (no fallthrough to short path).
      if (sidePisLargeBlk || sideQisLargeBlk) begin
        if (dL < beta) begin
          if (dSam0 && dSam3) begin
            filter_on            = 1'b1;
            dE                   = 2'd2;  // LONG
            maxFilterLengthP_out = sidePisLargeBlk ? maxFilterLengthP_in : 3'd3;
            maxFilterLengthQ_out = sideQisLargeBlk ? maxFilterLengthQ_in : 3'd3;
            dEp                  = 1'b1;
            dEq                  = 1'b1;
          end else begin
            // dL < beta but dSam failed → WEAK (spec step 9, sidePQ reset to 0)
            filter_on = 1'b1;
            dE = 2'd0;  // WEAK (0-indexed)
            dEp = (maxFilterLengthP_in > 1 && maxFilterLengthQ_in > 1) &&
                  ((dp0 + dp3) < ((beta + (beta >> 1)) >> 3));
            dEq = (maxFilterLengthP_in > 1 && maxFilterLengthQ_in > 1) &&
                  ((dq0 + dq3) < ((beta + (beta >> 1)) >> 3));
            maxFilterLengthP_out = 3'd1 + dEp;
            maxFilterLengthQ_out = 3'd1 + dEq;
          end
        end
        // else dL >= beta → dE stays 0, no filtering

        // ---- Short-block path: gate on d ----
      end else if (d < beta) begin
        // Strong decision requires both sides maxFL > 2 (§8.8.3.6.2 step 9c)
        if (dSam0 && dSam3 && (maxFilterLengthP_in > 2) && (maxFilterLengthQ_in > 2)) begin
          filter_on            = 1'b1;
          dE                   = 2'd1;  // STRONG (0-indexed)
          maxFilterLengthP_out = 3'd3;
          maxFilterLengthQ_out = 3'd3;
          dEp                  = 1'b1;
          dEq                  = 1'b1;
        end else begin
          filter_on = 1'b1;
          dE = 2'd0;  // WEAK
          dEp = (maxFilterLengthP_in > 1 && maxFilterLengthQ_in > 1) &&
                ((dp0 + dp3) < ((beta + (beta >> 1)) >> 3));
          dEq = (maxFilterLengthP_in > 1 && maxFilterLengthQ_in > 1) &&
                ((dq0 + dq3) < ((beta + (beta >> 1)) >> 3));
          maxFilterLengthP_out = 3'd1 + dEp;
          maxFilterLengthQ_out = 3'd1 + dEq;
        end
      end

    end else begin
      // ---- HEVC Fallback: gate on d only ----
      if (d < beta) begin
        if (check_strong_hevc()) begin
          filter_on            = 1'b1;
          dE                   = 2'd1;  // STRONG (0-indexed)
          maxFilterLengthP_out = 3'd3;
          maxFilterLengthQ_out = 3'd3;
          dEp                  = 1'b1;
          dEq                  = 1'b1;
        end else begin
          filter_on = 1'b1;
          dE = 2'd0;  // WEAK
          dEp = (maxFilterLengthP_in > 1 && maxFilterLengthQ_in > 1) &&
                ((dp0 + dp3) < ((beta + (beta >> 1)) >> 3));
          dEq = (maxFilterLengthP_in > 1 && maxFilterLengthQ_in > 1) &&
                ((dq0 + dq3) < ((beta + (beta >> 1)) >> 3));
          maxFilterLengthP_out = 3'd1 + dEp;
          maxFilterLengthQ_out = 3'd1 + dEq;
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // HEVC strong-filter check (H.265 §8.7.2.4)
  // -------------------------------------------------------------------------
  function automatic logic check_strong_hevc();
    logic [BIT_DEPTH+1:0] f_dp, f_dq;
    f_dp = dp0 + dp3;
    f_dq = dq0 + dq3;
    return ( (f_dp + f_dq   < (beta >> 2))     &&
             (sp0  + sq0    < (beta >> 3))      &&
             (sp3  + sq3    < (beta >> 3))      &&
             (spq0           < ((5 * tC + 1) >> 1)) &&
             (spq3           < ((5 * tC + 1) >> 1)) );
  endfunction

  // -------------------------------------------------------------------------
  // Arithmetic helpers
  // -------------------------------------------------------------------------
  function automatic [BIT_DEPTH+1:0] abs_diff_3tap(input logic [BIT_DEPTH-1:0] a, b, c);
    logic signed [11:0] val;
    val = $signed({2'b0, a}) - ($signed({2'b0, b}) << 1) + $signed({2'b0, c});
    return (val < 0) ? -val[BIT_DEPTH+1:0] : val[BIT_DEPTH+1:0];
  endfunction

  function automatic [BIT_DEPTH:0] abs_diff(input logic [BIT_DEPTH-1:0] a, b);
    logic signed [10:0] val;
    val = $signed({2'b0, a}) - $signed({2'b0, b});
    return (val < 0) ? -val[BIT_DEPTH:0] : val[BIT_DEPTH:0];
  endfunction

  function automatic [BIT_DEPTH+1:0] abs_diff_4tap(input logic [BIT_DEPTH-1:0] a, b, c, d);
    logic signed [12:0] val;
    val = $signed({2'b0, a}) - $signed({2'b0, b}) - $signed({2'b0, c}) + $signed({2'b0, d});
    return (val < 0) ? -val[BIT_DEPTH+1:0] : val[BIT_DEPTH+1:0];
  endfunction

endmodule

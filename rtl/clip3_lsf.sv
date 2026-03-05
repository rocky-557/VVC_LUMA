`timescale 1ns/1ps
// clip3_lsf.sv - Specialized Clipper for Luma Strong Filter (VVC/HEVC)
module clip3_lsf #(
    parameter int BIT_DEPTH = 8,
    parameter int INTERNAL_WIDTH = 16
) (
    input  logic signed [INTERNAL_WIDTH-1:0] val,         // Filtered value
    input  logic        [     BIT_DEPTH-1:0] p_orig,      // Original sample
    input  logic        [               9:0] tC,          // Threshold (VVC up to 395)
    input  logic        [               1:0] index,       // 0=p0, 1=p1, 2=p2
    input  logic                             mode,        // 0=HEVC, 1=VVC
    output logic        [     BIT_DEPTH-1:0] clamped_val  // Output standard 8-bit sample
);

  logic [2:0] K;
  logic signed [INTERNAL_WIDTH-1:0] min_bound, max_bound;
  logic signed [INTERNAL_WIDTH-1:0] clamped_val_int;

  // Standard-specific K-factor derivation
  always_comb begin
    if (mode == 1'b0) begin  // HEVC Mode
      K = 3'd2;
    end else begin  // VVC Mode
      case (index)
        2'd0:    K = 3'd3;
        2'd1:    K = 3'd2;
        2'd2:    K = 3'd1;
        default: K = 3'd2;
      endcase
    end
  end

  // Bound calculation
  // Correctly signed bound calculation for 16-bit internal
  assign min_bound = $signed({1'b0, p_orig}) - ($signed({1'b0, K}) * $signed({1'b0, tC}));
  assign max_bound = $signed({1'b0, p_orig}) + ($signed({1'b0, K}) * $signed({1'b0, tC}));

  // Instantiate core clipper
  clip3 #(
      .WIDTH(INTERNAL_WIDTH)
  ) u_clip (
      .min_val(min_bound),
      .max_val(max_bound),
      .val(val),
      .clamped_val(clamped_val_int)
  );

  // Final 8-bit unsigned clip (Clip1)
  always_comb begin
    if (clamped_val_int < 0) clamped_val = 8'd0;
    else if (clamped_val_int > 255) clamped_val = 8'd255;
    else clamped_val = clamped_val_int[BIT_DEPTH-1:0];
  end

endmodule

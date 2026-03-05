`timescale 1ns/1ps
// clip3.sv - Standard 3-input clipper
module clip3 #(
    parameter int WIDTH = 16  // Updated to 16-bit for Luma Long Filter headroom
) (
    input  logic signed [WIDTH-1:0] min_val,
    input  logic signed [WIDTH-1:0] max_val,
    input  logic signed [WIDTH-1:0] val,
    output logic signed [WIDTH-1:0] clamped_val
);

  always_comb begin
    if (val < min_val) clamped_val = min_val;
    else if (val > max_val) clamped_val = max_val;
    else clamped_val = val;
  end

endmodule

`timescale 1ns/1ps
// absh.sv - Absolute Value Module
module absh #(
    parameter int WIDTH = 16
) (
    input logic signed [WIDTH-1:0] val,
    output logic [WIDTH-1:0] abs_val
);

  assign abs_val = (val < 0) ? -val : val;

endmodule

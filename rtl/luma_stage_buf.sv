`timescale 1ns / 1ps
// luma_stage_buf.sv
// Internal storage: 24 rows x 128 cols
// Dual-port: separate write (from vpass) and read (from hpass)

module luma_stage_buf #(
    parameter int BIT_DEPTH = 8
) (
    input logic clk,
    input logic rst_n,

    // Write port (from vpass)
    input logic                 wr_valid,
    input logic [BIT_DEPTH-1:0] wr_data   [0:3][0:15],  // 4x16 input window
    input logic [          4:0] wr_edge,                // 1=skip cols 0-3, 31=skip cols 12-15
    input logic [          2:0] wr_row_idx,             // 0-4
    input logic [          4:0] wr_col_idx,             // 0-31

    // Read port (from hpass)
    input logic       rd_en,
    input logic [2:0] rd_row_idx,  // 0-4
    input logic [4:0] rd_col_idx,  // 0-31
    input logic       mask1,       // mask cols 12-15
    input logic       mask31,      // mask cols 0-3

    // Read output
    output logic [BIT_DEPTH-1:0] rd_data  [0:3][0:15],  // 4x16 transposed read
    output logic                 buf_valid
);

  // Internal 20x128 memory
  logic [BIT_DEPTH-1:0] mem[0:23][0:127];

  // Write address decode
  logic [4:0] wr_row_base;
  logic [6:0] wr_col_base;
  assign wr_row_base = {wr_row_idx, 2'b00};
  assign wr_col_base = {wr_col_idx, 2'b00} - 7'd8;

  // Read address decode
  logic [4:0] rd_row_base;
  logic [6:0] rd_col_base;
  assign rd_row_base = {rd_row_idx, 2'b00};
  assign rd_col_base = {rd_col_idx, 2'b00};

  // Write path
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      foreach (mem[r, c]) mem[r][c] <= '0;
      buf_valid <= 1'b0;
    end else if (wr_valid && (wr_row_idx <= 3'd5)) begin
      if (wr_edge == 5'd1) begin
        for (int r = 0; r < 4; r++)
        for (int c = 4; c < 16; c++) mem[wr_row_base+r][(wr_col_base+c)%128] <= wr_data[r][c];
      end else if (wr_edge == 5'd31) begin
        for (int r = 0; r < 4; r++)
        for (int c = 0; c < 12; c++) mem[wr_row_base+r][(wr_col_base+c)%128] <= wr_data[r][c];
      end else begin
        for (int r = 0; r < 4; r++)
        for (int c = 0; c < 16; c++) mem[wr_row_base+r][(wr_col_base+c)%128] <= wr_data[r][c];
      end
      buf_valid <= 1'b1;
    end
  end

  // Read path: transposed 16x4 → 4x16, with masking
  always_comb begin
    for (int r = 0; r < 4; r++) begin
      for (int c = 0; c < 16; c++) begin
        if (mask1 && c < 4) rd_data[r][c] = '0;
        else if (mask31 && c >= 12) rd_data[r][c] = '0;
        else if (rd_en) rd_data[r][c] = mem[(rd_row_base+c)%24][(rd_col_base+r)%128];
        else rd_data[r][c] = '0;
      end
    end
  end

endmodule

`timescale 1ns / 1ps

module tb_stage_buf;
  parameter BIT_DEPTH = 8;

  logic clk, rst_n, load_valid;
  logic [4:0] wr_edge, read_edge;
  logic [2:0] row_idx;
  logic [4:0] col_idx;
  logic [BIT_DEPTH-1:0] block_in[0:3][0:15];
  logic [BIT_DEPTH-1:0] stage_buf[0:3][0:15];
  logic buf_valid;

  luma_stage_buf #(.BIT_DEPTH(BIT_DEPTH)) uut (.*);

  initial clk = 0;
  always #5 clk = ~clk;

  task write_block(input [2:0] ri, input [4:0] ci, input [4:0] we, input [7:0] tag);
    integer r, c;
    for (r = 0; r < 4; r++)
      for (c = 0; c < 16; c++) block_in[r][c] = tag + (r * 16 + c);  // distinct values for pixels
    row_idx = ri;
    col_idx = ci;
    wr_edge = we;
    load_valid = 1;
    @(posedge clk);
    #1;
    load_valid = 0;
  endtask

  task print_buf(input string label);
    $display(
        "%s | sb[0][0..15] = %0d %0d %0d %0d | %0d %0d %0d %0d | %0d %0d %0d %0d | %0d %0d %0d %0d",
        label, stage_buf[0][0], stage_buf[0][1], stage_buf[0][2], stage_buf[0][3], stage_buf[0][4],
        stage_buf[0][5], stage_buf[0][6], stage_buf[0][7], stage_buf[0][8], stage_buf[0][9],
        stage_buf[0][10], stage_buf[0][11], stage_buf[0][12], stage_buf[0][13], stage_buf[0][14],
        stage_buf[0][15]);
  endtask

  initial begin
    rst_n = 0;
    load_valid = 0;
    wr_edge = 0;
    read_edge = 0;
    row_idx = 0;
    col_idx = 0;
    foreach (block_in[r, c]) block_in[r][c] = 0;
    @(posedge clk);
    #1;
    rst_n = 1;

    // Write 4 row groups (0-15) at col 0
    write_block(0, 0, 0, 8'd10);
    write_block(1, 0, 0, 8'd20);
    write_block(2, 0, 0, 8'd30);
    write_block(3, 0, 0, 8'd40);
    read_edge = 0;
    #1;
    print_buf("Vertical Read (Normal) col 0");

    // Test Edge 1 masking
    read_edge = 1;
    #1;
    print_buf("Vertical Read (Edge 1 masked)");

    // Write row groups at col 30 to test Edge 31
    write_block(0, 30, 0, 8'd60);
    write_block(1, 30, 0, 8'd70);
    write_block(2, 30, 0, 8'd80);
    write_block(3, 30, 0, 8'd90);
    read_edge = 31;
    #1;
    print_buf("Vertical Read (Edge 31 masked)");

    $finish;
  end
endmodule

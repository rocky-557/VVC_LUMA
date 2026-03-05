`timescale 1ns / 1ps

module tb_luma_vpass;
  parameter int BIT_DEPTH = 8;
  logic clk, rst_n, start, load_valid, mode_vvc, done, valid_out;
  logic [BIT_DEPTH-1:0] block_in[0:3][0:3];
  logic [7:0] qp_p, qp_q;
  logic signed [7:0] beta_offset, tc_offset;
  logic [2:0] maxFilterLengthP_in, maxFilterLengthQ_in;
  logic [1:0] bS;
  logic [BIT_DEPTH-1:0] p_out_vec[0:3][0:6], q_out_vec[0:3][0:6];
  logic [4:0] win_row_out, win_edge_idx_out;

  logic [BIT_DEPTH-1:0] input_mem[0:127][0:127], output_mem[0:127][0:127];

  luma_vpass #(.BIT_DEPTH(BIT_DEPTH)) dut (.*);

  initial clk = 0;
  always #5 clk = ~clk;

  initial begin
    int f_in, f_rtl;
    logic [BIT_DEPTH-1:0] val;

    f_in = $fopen("vectors/input_luma.txt", "r");
    for (int r = 0; r < 128; r++)
    for (int c = 0; c < 128; c++)
    if ($fscanf(f_in, "%d\n", val)) begin
      input_mem[r][c]  = val;
      output_mem[r][c] = val;
    end
    $fclose(f_in);

    rst_n = 0;
    start = 0;
    load_valid = 0;
    qp_p = 45;
    qp_q = 45;
    beta_offset = 0;
    tc_offset = 0;
    maxFilterLengthP_in = 3'd7;
    maxFilterLengthQ_in = 3'd7;
    bS = 2'd2;
    mode_vvc = 1;

    repeat (10) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);
    start = 1;
    @(posedge clk);
    start = 0;

    for (int rg = 0; rg < 32; rg++) begin
      for (int b = 0; b < 32; b++) begin
        load_valid = 1;
        for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) block_in[i][j] = input_mem[rg*4+i][b*4+j];
        @(posedge clk);
      end
    end
    load_valid = 0;
    wait (done);
    repeat (10) @(posedge clk);

    f_rtl = $fopen("rtl_luma_out.txt", "w");
    for (int r = 0; r < 128; r++)
    for (int c = 0; c < 128; c++) $fwrite(f_rtl, "%d\n", output_mem[r][c]);
    $fclose(f_rtl);
    $finish;
  end

  always @(posedge clk)
    if (valid_out) begin
      int r_base = win_row_out * 4;
      int c_edge = win_edge_idx_out * 4;
      for (int i = 0; i < 4; i++) begin
        // p0 at c_edge-1, p1 at c_edge-2, ..., p6 at c_edge-7
        for (int j = 0; j < 7; j++) begin
          int col_p = c_edge - (j + 1);
          int col_q = c_edge + j;
          if (col_p >= 0 && col_p < 128) output_mem[r_base+i][col_p] = p_out_vec[i][j];
          if (col_q >= 0 && col_q < 128) output_mem[r_base+i][col_q] = q_out_vec[i][j];
        end
      end
    end
endmodule

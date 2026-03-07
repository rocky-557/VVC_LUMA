`timescale 1ns / 1ps

module tb_luma_top;
  parameter BIT_DEPTH = 8;
  parameter CTU_SIZE = 128;

  logic clk, rst_n, load_valid, start;
  logic [BIT_DEPTH-1:0] block_in    [0:3][ 0:3];
  logic [BIT_DEPTH-1:0] hpass_out   [0:3][0:15];
  logic [         15:0] hpass_mask;
  logic                 hpass_valid;

  // Active filter ports
  logic [7:0] qp_p = 45, qp_q = 45;
  logic signed [7:0] beta_offset = 0, tc_offset = 0;
  logic [2:0] maxFilterLengthP_in = 7, maxFilterLengthQ_in = 7;
  logic [1:0] bS = 2;
  logic mode_vvc = 1;

  luma_top #(.BIT_DEPTH(BIT_DEPTH)) dut (.*);

  initial clk = 0;
  always #5 clk = ~clk;

  logic [BIT_DEPTH-1:0] inp[0:CTU_SIZE-1][0:CTU_SIZE-1];
  logic [BIT_DEPTH-1:0] output_mem[0:CTU_SIZE-1][0:CTU_SIZE-1];
  logic                 hp_modified[0:CTU_SIZE-1][0:CTU_SIZE-1];
  integer pass_cnt = 0, fail_cnt = 0, skip_cnt = 0;

  initial begin
    foreach (output_mem[r, c]) output_mem[r][c] = 0;
    foreach (hp_modified[r, c]) hp_modified[r][c] = 0;
  end

  // Shadow: tracks which CTU row is stored in each mem row (0-23)
  integer mem_row_to_ctu_row[0:23];

  initial begin
    for (int i = 0; i < 24; i++) mem_row_to_ctu_row[i] = -1;
  end

  // Load input
  initial begin
    integer fd, r, c, val;
    fd = $fopen("/home/raghav/Projects/HW/lma/vectors/input_luma.txt", "r");
    for (r = 0; r < CTU_SIZE; r++)
    for (c = 0; c < CTU_SIZE; c++) begin
      $fscanf(fd, "%d\n", val);
      inp[r][c] = val[7:0];
    end
    $fclose(fd);
  end

  // Stimulus
  initial begin
    integer br, bc, r, c;
    rst_n = 0;
    load_valid = 0;
    start = 0;
    foreach (block_in[r, c]) block_in[r][c] = 0;
    repeat (4) @(posedge clk);
    #1;
    rst_n = 1;
    start = 1;

    for (br = 0; br < 32; br++)
    for (bc = 0; bc < 32; bc++) begin
      for (r = 0; r < 4; r++) for (int c = 0; c < 4; c++) block_in[r][c] = inp[br*4+r][bc*4+c];
      load_valid = 1;
      @(posedge clk);
      #1;
    end
    // Pipeline Drain: extra cycles of load_valid for V-Pass AND H-Pass
    // H-Pass needs ~1200 cycles total. Input is ~1024 cycles.
    repeat (400) begin
      load_valid = 1;
      block_in   = '{default: '{default: 0}};
      @(posedge clk);
      #1;
    end
    load_valid = 0;
    repeat (2000) @(posedge clk);

    $display("HPASS vs INP: PASS=%0d FAIL=%0d SKIP=%0d", pass_cnt, fail_cnt, skip_cnt);

    begin
      integer fd_out, r, c;
      fd_out = $fopen("/home/raghav/Projects/HW/lma/vectors/passtest.txt", "w");
      for (r = 0; r < CTU_SIZE; r++)
      for (c = 0; c < CTU_SIZE; c++) $fwrite(fd_out, "%0d\n", output_mem[r][c]);
      $fclose(fd_out);
    end

    $finish;
  end

  // -------------------------------------------------------------------------
  // Update shadow on every stage buffer write
  // Track actual CTU row group (0-31)
  // -------------------------------------------------------------------------
  wire          sb_wr_valid = dut.u_stage_buf.wr_valid;
  wire    [4:0] sb_wr_row_base = dut.u_stage_buf.wr_row_base;

  integer       ctu_rg = 0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ctu_rg <= 0;
    else if (sb_wr_valid && dut.u_stage_buf.wr_edge == 5'd31) ctu_rg <= ctu_rg + 1;
  end

  wire signed [6:0] sb_wr_col = dut.u_stage_buf.wr_col_base;

  always @(posedge clk) begin
    if (sb_wr_valid) begin
      for (int r = 0; r < 4; r++) mem_row_to_ctu_row[sb_wr_row_base+r] = ctu_rg * 4 + r;
    end
  end

  // -------------------------------------------------------------------------
  // Verify H-pass output against inp using shadow CTU row mapping
  //   hpass_out[r][c]:
  //     CTU col = col_cnt*4 + r
  //     mem row = (rd_row_base + c) % 20  →  CTU row = shadow[mem_row]
  // -------------------------------------------------------------------------
  wire       hp_rd_en = hpass_valid;
  wire [4:0] hp_rd_row_base = {dut.u_hpass.out_row_idx, 2'b00};
  wire [6:0] hp_rd_col_base = {dut.u_hpass.out_col_idx, 2'b00};
  wire       hp_mask1 = dut.u_hpass.out_mask1;
  wire       hp_mask31 = dut.u_hpass.out_mask31;

  always @(posedge clk) begin
    if (hp_rd_en) begin
      for (int r = 0; r < 4; r++) begin
        for (int c = 0; c < 16; c++) begin
          int gc, mr, gr;
          logic [BIT_DEPTH-1:0] pix;

          // Capture all pixels from the H-Pass window
          gc  = (hp_rd_col_base + r) % 128;  // CTU col
          mr  = (hp_rd_row_base + c) % 24;  // mem row
          gr  = mem_row_to_ctu_row[mr];  // CTU row from shadow
          pix = hpass_out[r][c];

          if (gr < 0 || gr >= CTU_SIZE || gc < 0 || gc >= CTU_SIZE) begin
            skip_cnt = skip_cnt + 1;
          end else begin
            if (hpass_mask[c]) begin
              output_mem[gr][gc] = pix;
              hp_modified[gr][gc] = 1;
              if (pix == inp[gr][gc]) pass_cnt = pass_cnt + 1;
              else fail_cnt = fail_cnt + 1;
            end else if (!hp_modified[gr][gc]) begin
              output_mem[gr][gc] = pix;
            end
          end
        end
      end
    end
  end

endmodule

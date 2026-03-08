`timescale 1ns / 1ps
// tb_luma_top.sv

module tb_luma_top;

  parameter BIT_DEPTH = 8;
  parameter CTU_SIZE = 128;

  // =========================================================================
  // DUT I/O
  // =========================================================================
  logic clk, rst_n, load_valid, start;
  logic        [BIT_DEPTH-1:0] block_in                [0:3][ 0:3];
  logic        [BIT_DEPTH-1:0] hpass_out               [0:3][0:15];
  logic        [         15:0] hpass_mask;
  logic                        hpass_valid;

  // Filter parameters (fixed for this test)
  logic        [          7:0] qp_p = 45;
  logic        [          7:0] qp_q = 45;
  logic signed [          7:0] beta_offset = 0;
  logic signed [          7:0] tc_offset = 0;
  logic        [          2:0] maxFilterLengthP_in = 3;
  logic        [          2:0] maxFilterLengthQ_in = 3;
  logic        [          1:0] bS = 2;
  logic                        mode_vvc = 1;

  // =========================================================================
  // DUT
  // =========================================================================
  luma_top #(
      .BIT_DEPTH(BIT_DEPTH)
  ) dut (
      .clk                (clk),
      .rst_n              (rst_n),
      .load_valid         (load_valid),
      .start              (start),
      .block_in           (block_in),
      .qp_p               (qp_p),
      .qp_q               (qp_q),
      .beta_offset        (beta_offset),
      .tc_offset          (tc_offset),
      .maxFilterLengthP_in(maxFilterLengthP_in),
      .maxFilterLengthQ_in(maxFilterLengthQ_in),
      .bS                 (bS),
      .mode_vvc           (mode_vvc),
      .hpass_out          (hpass_out),
      .hpass_mask         (hpass_mask),
      .hpass_valid        (hpass_valid)
  );

  // =========================================================================
  // Hierarchical probes into DUT internals (no extra top-level ports needed)
  // =========================================================================

  // V-Pass pipelined outputs: 2-cycle delayed, aligned with stage_buf write data
  wire [4:0] vp_edge_idx = dut.u_vpass.edge_idx_out;
  wire [5:0] vp_row_group = dut.u_vpass.row_group_out;
  wire       vp_edge_valid = dut.u_vpass.edge_valid;

  // H-Pass S3 outputs: aligned with hpass_valid / hpass_out
  wire [2:0] hp_out_row_idx = dut.u_hpass.out_row_idx;
  wire [4:0] hp_out_col_idx = dut.u_hpass.out_col_idx;
  wire       hp_out_mask1 = dut.u_hpass.out_mask1;
  wire       hp_out_mask31 = dut.u_hpass.out_mask31;

  // =========================================================================
  // Clock
  // =========================================================================
  initial clk = 0;
  always #5 clk = ~clk;

  // =========================================================================
  // Reference / Verification Arrays
  // =========================================================================
  logic [BIT_DEPTH-1:0] inp        [0:CTU_SIZE-1][0:CTU_SIZE-1];
  logic [BIT_DEPTH-1:0] output_mem [0:CTU_SIZE-1][0:CTU_SIZE-1];
  logic                 hp_modified[0:CTU_SIZE-1][0:CTU_SIZE-1];
  integer pass_cnt = 0, fail_cnt = 0, skip_cnt = 0;

  // Shadow: maps each of the 24 stage-buf mem rows → CTU pixel row (0-127), -1 = unknown
  integer mem_row_to_ctu_row[0:23];
  integer total_cycles = 0;
  integer total_cycles_res = 0;
  logic counting_cycles = 0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      counting_cycles  <= 0;
      total_cycles     <= 0;
      total_cycles_res <= 0;
    end else begin
      if (start) counting_cycles <= 1;
      if (counting_cycles) total_cycles <= total_cycles + 1;
      // End trigger: last hpass block of last row group (RG 30, Col 31)
      if (hpass_valid && (dut.u_controller.hp_rg == 6'd30) && (hp_out_col_idx == 5'd31)) begin
        counting_cycles  <= 0;
        total_cycles_res <= total_cycles;
      end
    end
  end

  initial begin
    foreach (output_mem[r, c]) output_mem[r][c] = 0;
    foreach (hp_modified[r, c]) hp_modified[r][c] = 0;
    for (int i = 0; i < 24; i++) mem_row_to_ctu_row[i] = -1;
  end

  // =========================================================================
  // Load Input Vector
  // =========================================================================
  initial begin
    integer fd, r, c, val, status;
    fd = $fopen("/home/raghav/Projects/HW/lma/vectors/input_luma.txt", "r");
    if (fd == 0) begin
      $display("ERROR: Cannot open input file");
      $finish;
    end
    for (r = 0; r < CTU_SIZE; r++)
    for (c = 0; c < CTU_SIZE; c++) begin
      status = $fscanf(fd, "%d\n", val);
      inp[r][c] = val[7:0];
    end
    $fclose(fd);
  end

  // =========================================================================
  // Stimulus
  // =========================================================================
  initial begin
    integer br, bc, r, c;

    rst_n      = 0;
    load_valid = 0;
    start      = 0;
    foreach (block_in[r, c]) block_in[r][c] = 0;

    repeat (4) @(posedge clk);
    #1;
    rst_n = 1;

    // Pulse start for one cycle to initialise controller
    start = 1;
    @(posedge clk);
    #1;
    start = 0;

    // Stream all 32×32 = 1024 blocks of the CTU (row-major, 4×4 each)
    for (br = 0; br < 32; br++) begin
      for (bc = 0; bc < 32; bc++) begin
        for (r = 0; r < 4; r++) for (c = 0; c < 4; c++) block_in[r][c] = inp[br*4+r][bc*4+c];
        load_valid = 1;
        @(posedge clk);
        #1;
      end
    end

    // Drain pipeline with zeros
    repeat (1500) begin
      load_valid = 1;
      for (r = 0; r < 4; r++) for (c = 0; c < 4; c++) block_in[r][c] = 8'd0;
      @(posedge clk);
      #1;
    end
    load_valid = 0;

    repeat (200) @(posedge clk);
    $display("TOTAL CYCLES: %0d", total_cycles_res);

    // -----------------------------------------------------------------------
    // Results
    // -----------------------------------------------------------------------
    $display("========================================");
    $display("HPASS vs INP: PASS=%0d  FAIL=%0d  SKIP=%0d", pass_cnt, fail_cnt, skip_cnt);
    $display("========================================");

    begin
      integer fd_out;
      fd_out = $fopen("/home/raghav/Projects/HW/lma/vectors/passtest.txt", "w");
      if (fd_out == 0) $display("ERROR: Cannot open output file");
      else begin
        for (r = 0; r < CTU_SIZE; r++)
        for (c = 0; c < CTU_SIZE; c++) $fwrite(fd_out, "%0d\n", output_mem[r][c]);
        $fclose(fd_out);
      end
    end

    $finish;
  end

  // =========================================================================
  // Shadow Tracking: Update mem_row → CTU-row map when vpass writes stage_buf
  //
  // Uses the 2-cycle pipelined vp_row_group / vp_edge_valid so the map is
  // updated in the same cycle the data lands in luma_stage_buf.
  // =========================================================================
  integer ctu_rg_shadow = 0;

  // -------------------------------------------------------------------------
  // DEBUG: Trace (64, 108) through V-Pass and H-Pass
  // -------------------------------------------------------------------------
  always @(posedge clk) begin
    if (vp_edge_valid && (vp_edge_idx == 5'd27) && (vp_row_group == 6'd16)) begin
      $display("SYNC_VP: Cyc=%0d | RG=16, Edge=27 | In: %0d | Out: %0d | FilterOn: %b",
               total_cycles, inp[64][108], dut.u_vpass.stage_out[0][8], dut.u_vpass.filter_on_reg);
    end
    if (vp_edge_valid && (vp_edge_idx == 5'd28) && (vp_row_group == 6'd16)) begin
      $display("SYNC_VP: Cyc=%0d | RG=16, Edge=28 (x=112) | p3(x=108) Out: %0d | FilterOn: %b",
               total_cycles, dut.u_vpass.stage_out[0][4], dut.u_vpass.filter_on_reg);
    end

    // Catch EVERY write to mem[16][108] across all window offsets
    if (vp_edge_valid) begin
      for (int r = 0; r < 4; r++) begin
        if ((dut.u_stage_buf.wr_row_base + r) % 24 == 16) begin
          for (int c = 0; c < 16; c++) begin
            automatic int target_x = $signed({1'b0, dut.u_stage_buf.wr_col_idx, 2'b00}) - 8 + c;
            if (target_x == 108) begin
              // Only log if we are actually writing this pixel (not protected)
              automatic
              logic [15:0]
              current_hist = (dut.u_stage_buf.wr_edge == 5'd1) ? 16'h0 : dut.u_stage_buf.filt_hist[r];
              if (dut.u_stage_buf.wr_mask[c] || !current_hist[c]) begin
                $display(
                    "MEM_WRITE_ALL: Cyc=%0d | VP_RG=%0d | Edge=%0d | c=%0d | Wrote: %0d to (16, 108)",
                    total_cycles, vp_row_group, vp_edge_idx, c, dut.u_vpass.stage_out[r][c]);
              end
            end
          end
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // DEBUG: Direct Memory Array Monitor
  // -------------------------------------------------------------------------
  logic [7:0] prev_mem_val;
  always @(posedge clk) begin
    if (rst_n) begin
      if (dut.u_stage_buf.mem[16][108] != prev_mem_val) begin
        $display("MEM_CHANGE: Cyc=%0d | mem[16][108]: %0d -> %0d", total_cycles, prev_mem_val,
                 dut.u_stage_buf.mem[16][108]);
      end
      prev_mem_val <= dut.u_stage_buf.mem[16][108];
    end else begin
      prev_mem_val <= '0;
    end
  end

  // -------------------------------------------------------------------------
  // DEBUG: Monitor Absolute Lag (Row Groups)
  // -------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n && counting_cycles && (total_cycles % 100 == 0)) begin
      $display("SYNC_PROG: Time=%t | VP_ABS_RG=%0d | HP_ABS_RG=%0d | Delta=%0d", $time,
               dut.u_controller.vp_row_group, dut.u_controller.hp_rg, $signed
               ({1'b0, dut.u_controller.vp_row_group}) - $signed({1'b0, dut.u_controller.hp_rg}));
    end
  end

  // -------------------------------------------------------------------------
  // Shadow Tracking: Map each of the 24 buffer rows to CTU pixel row (0-127)
  // Updated on every stage buffer write by V-Pass.
  // -------------------------------------------------------------------------
  always @(posedge clk) begin
    if (vp_edge_valid && (vp_row_group < 32)) begin
      automatic int buffer_rg = vp_row_group % 6;
      for (int r = 0; r < 4; r++) begin
        mem_row_to_ctu_row[buffer_rg*4+r] = vp_row_group * 4 + r;
      end
    end
  end

  // =========================================================================
  // Verification: check H-Pass output pixels against inp[][]
  //
  // hpass_out[r][c] is the transposed 4×16 H-pass result:
  //   - column in CTU  : rd_col_base + r   (r ∈ 0..3 selects 4 adjacent CTU cols)
  //   - mem row index  : rd_row_base + c   (c ∈ 0..15 selects CTU row via shadow map)
  // =========================================================================
  always @(posedge clk) begin
    if (hpass_valid) begin
      automatic int rd_row_base = hp_out_row_idx * 4;
      automatic int rd_col_base = hp_out_col_idx * 4;

      for (int r = 0; r < 4; r++) begin
        for (int c = 4; c < 12; c++) begin
          automatic int gc = (rd_col_base + r) % CTU_SIZE;
          automatic int mr = (rd_row_base + c) % 24;
          automatic int gr = mem_row_to_ctu_row[mr];
          automatic logic [BIT_DEPTH-1:0] pix = hpass_out[r][c];

          if (gr < 0 || gr >= CTU_SIZE) begin
            skip_cnt = skip_cnt + 1;
          end else begin
            if (hpass_mask[c]) begin
              output_mem[gr][gc]  = pix;
              hp_modified[gr][gc] = 1'b1;
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

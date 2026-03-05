`timescale 1ns / 1ps

module tb_counters;

  logic clk, rst_n, load_valid;
  logic [7:0] block_in[0:3][0:3];
  logic [7:0] qp_p, qp_q;
  logic signed [7:0] beta_offset, tc_offset;
  logic [2:0] maxFLP, maxFLQ;
  logic [1:0] bS;
  logic mode_vvc, start;

  luma_vpass #(
      .BIT_DEPTH(8)
  ) uut (
      .clk(clk),
      .rst_n(rst_n),
      .start(start),
      .block_in(block_in),
      .load_valid(load_valid),
      .qp_p(qp_p),
      .qp_q(qp_q),
      .beta_offset(beta_offset),
      .tc_offset(tc_offset),
      .maxFilterLengthP_in(maxFLP),
      .maxFilterLengthQ_in(maxFLQ),
      .bS(bS),
      .mode_vvc(mode_vvc),
      .stage_out(),
      .edge_idx_out(),
      .edge_valid()
  );

  initial clk = 0;
  always #5 clk = ~clk;

  initial begin
    start = 0;
    bS = 0;
    mode_vvc = 0;
    qp_p = 0;
    qp_q = 0;
    beta_offset = 0;
    tc_offset = 0;
    maxFLP = 0;
    maxFLQ = 0;
  end

  integer cycle;
  initial begin
    rst_n = 0;
    load_valid = 0;
    cycle = 0;
    @(posedge clk);
    #1;
    rst_n = 1;

    // Load 36 blocks (enough for edge to reach 31)
    // Tag each block with its block number in pixel [0][0]
    repeat (170) begin
      // Set block_in[0][0] = cycle number as tag
      foreach (block_in[r, c]) block_in[r][c] = 0;
      block_in[0][0] = cycle[7:0];  // tag with load cycle (0-based)
      load_valid = 1;
      @(posedge clk);
      #1;
      cycle = cycle + 1;

      // Print buf contents when edge changes or at key points
      if (uut.edge_idx == 0 || uut.edge_idx == 1 || uut.edge_idx == 31)
        $display(
            "Cyc=%0d blk_cnt=%0d edge_idx=%0d | buf=[b%0d, b%0d, b%0d, b%0d]",
            cycle,
            uut.block_cnt,
            uut.edge_idx,
            uut.stage_buf[0][0] % 32,
            uut.stage_buf[0][4] % 32,
            uut.stage_buf[0][8] % 32,
            uut.stage_buf[0][12] % 32
        );
    end

    $finish;
  end

endmodule

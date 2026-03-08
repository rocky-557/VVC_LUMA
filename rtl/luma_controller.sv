`timescale 1ns / 1ps
// luma_controller.sv - Centralized Luma DBF Scanning Controller
// Manages counters and state machines for V-Pass, H-Pass, and Buffer.

module luma_controller (
    input logic clk,
    input logic rst_n,
    input logic start,      // Start processing one 128x128 CTU
    input logic load_valid, // Global enable for pipeline advance

    // V-Pass Control
    output logic [4:0] vp_block_cnt,  // 0-31 (Loading 4x4 blocks)
    output logic [4:0] vp_edge_idx,   // 0-31 (Active edges)
    output logic [5:0] vp_row_group,  // 0-31 (4-row groups in CTU)
    output logic       vp_done,       // V-Pass completed for CTU

    // Stage Buffer Control
    output logic [5:0] buf_wr_ptr,  // Write row index (0-31)
    output logic [5:0] buf_rd_ptr,  // Read row index (0-31)
    output logic       buf_rd_en,   // H-Pass reading enable

    // H-Pass Control
    output logic       hp_active,    // H-Pass in processing mode
    output logic [4:0] hp_edge_cnt,  // 1-31 (Active edges)
    output logic [4:0] hp_col_cnt,   // 0-31 (Scanning across row group)
    output logic       hp_mask1,     // Boundary mask for edge 1
    output logic       hp_mask31,    // Boundary mask for edge 31
    output logic       hp_done       // Full CTU deblocking completed
);

  // Need a register for hp_done to prevent premature completion
  logic hp_done_reg;

  // =========================================================================
  // V-Pass Scanning Logic
  // =========================================================================
  logic [4:0] vp_bc;
  logic [4:0] vp_ei;
  logic [5:0] vp_rg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vp_bc <= 5'd0;
      vp_ei <= 5'd0;
      vp_rg <= 3'd0;
    end else if (start) begin
      vp_bc <= 5'd0;
      vp_ei <= 5'd0;
      vp_rg <= 3'd0;
    end else if (load_valid && !vp_done) begin
      // Block Count (0-31)
      vp_bc <= (vp_bc == 5'd31) ? 5'd0 : vp_bc + 1'b1;

      // Edge Index (0-31 with start-up stall)
      if (vp_ei == 5'd31) begin
        vp_ei <= 5'd0;
        // Increment row group when one full row of CTU is processed
        if (vp_rg < 6'd32) vp_rg <= vp_rg + 1'b1;
      end else if (vp_ei < 5'd2 && vp_bc <= 5'd1) begin
        vp_ei <= vp_ei;  // Stall at very beginning for pipeline prefill
      end else begin
        vp_ei <= vp_ei + 1'b1;
      end
    end
  end

  assign vp_block_cnt = vp_bc;
  assign vp_edge_idx  = vp_ei;
  assign vp_row_group = vp_rg;
  assign vp_done      = (vp_rg == 6'd32);

  // =========================================================================
  // H-Pass Scanning Logic (Orthogonal Scan)
  // =========================================================================
  typedef enum logic [1:0] {
    HP_IDLE,
    HP_STALL,  // Wait for V-Pass to prefill enough lines
    HP_ACTIVE  // Scan rows/cols
  } hp_state_t;

  hp_state_t hp_state;
  logic [6:0] stall_cnt;
  logic [4:0] hp_ec;
  logic [4:0] hp_cc;
  logic [5:0] hp_rg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hp_state  <= HP_IDLE;
      stall_cnt <= 7'd0;
      hp_ec     <= 5'd1;
      hp_cc     <= 5'd0;
      hp_rg     <= 3'd0;
    end else if (start) begin
      hp_state  <= HP_STALL;
      stall_cnt <= 7'd0;
      hp_ec     <= 5'd1;
      hp_cc     <= 5'd0;
      hp_rg     <= 3'd0;
    end else if (load_valid) begin
      case (hp_state)
        HP_STALL: begin
          // Start H-Pass for a row-group boundary when V-Pass has filled enough 
          // data. Lagging by 3 row-groups (vp_rg > hp_rg + 2) matches lma baseline.
          if ((vp_rg > hp_rg + 2) || vp_done) begin
            hp_state <= HP_ACTIVE;
          end
        end

        HP_ACTIVE: begin
          // Scan all columns for the current row-group boundary
          if (hp_cc == 5'd31) begin
            hp_cc <= 5'd0;
            // Finished one edge boundary (1..31)
            if (hp_rg == 6'd30) begin
              hp_state <= HP_IDLE;
              hp_done_reg <= 1'b1;
            end else begin
              hp_rg <= hp_rg + 1'b1;
              hp_state <= HP_STALL;
            end
          end else begin
            hp_cc <= hp_cc + 1'b1;
          end
        end

        default: ;
      endcase
    end
  end

  assign hp_active   = (hp_state == HP_ACTIVE);
  assign hp_edge_cnt = hp_rg + 5'd1;  // Maps row groups 0..30 to edge indices 1..31
  assign hp_col_cnt  = hp_cc;
  assign hp_mask1    = (hp_state == HP_ACTIVE) && (hp_rg == 6'd0);
  assign hp_mask31   = (hp_state == HP_ACTIVE) && (hp_rg == 6'd30);
  assign hp_done     = hp_done_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) hp_done_reg <= 1'b0;
    else if (start) hp_done_reg <= 1'b0;
    else if (hp_state == HP_ACTIVE && hp_cc == 5'd31 && hp_rg == 6'd30) hp_done_reg <= 1'b1;
  end

  // =========================================================================
  // Buffer Control
  // =========================================================================
  assign buf_wr_ptr = vp_rg;
  assign buf_rd_ptr = hp_rg;
  assign buf_rd_en  = (hp_state == HP_ACTIVE);

endmodule


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
    input logic [         15:0] wr_mask,                // selective write mask
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

  // Internal 24x128 memory
  logic [BIT_DEPTH-1:0] mem[0:23][0:127];

  // Write address decode
  logic [4:0] wr_row_base;
  assign wr_row_base = {wr_row_idx, 2'b00};

  // Read address decode
  logic [4:0] rd_row_base;
  logic [6:0] rd_col_base;
  assign rd_row_base = {rd_row_idx, 2'b00};
  assign rd_col_base = {rd_col_idx, 2'b00};

  // Write path: sliding history mask (64 bits total)
  logic [15:0] filt_hist[0:3];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      foreach (mem[r, c]) mem[r][c] <= '0;
      foreach (filt_hist[r]) filt_hist[r] <= '0;
      buf_valid <= 1'b0;
    end else if (wr_valid && (wr_row_idx <= 3'd5)) begin
      for (int r = 0; r < 4; r++) begin
        automatic logic [15:0] updated_mask = '0;
        // Reset history at start of a row group
        automatic logic [15:0] current_hist = (wr_edge == 5'd1) ? 16'h0 : filt_hist[r];

        for (int c = 0; c < 16; c++) begin
          automatic int target_x = $signed({1'b0, wr_col_idx, 2'b00}) - 8 + c;
          if (target_x >= 0 && target_x < 128) begin
            if (wr_mask[c]) begin
              mem[wr_row_base+r][target_x] <= wr_data[r][c];
              updated_mask[c] = 1'b1;
            end else if (!current_hist[c]) begin
              mem[wr_row_base+r][target_x] <= wr_data[r][c];
              updated_mask[c] = 1'b0;
            end else begin
              updated_mask[c] = 1'b1;  // Protected
            end
          end else begin
            updated_mask[c] = 1'b0;
          end
        end
        // Shift history right by 4 columns for the next edge (Cycle i: c=4 -> Cycle i+1: c=0)
        filt_hist[r] <= {4'h0, updated_mask[15:4]};
      end
      buf_valid <= 1'b1;
    end
  end

  // Read path: transposed 16x4 → 4x16
  always_comb begin
    for (int r = 0; r < 4; r++) begin
      for (int c = 0; c < 16; c++) begin
        if (rd_en) rd_data[r][c] = mem[(rd_row_base+c)%24][(rd_col_base+r)%128];
        else rd_data[r][c] = '0;
      end
    end
  end

endmodule

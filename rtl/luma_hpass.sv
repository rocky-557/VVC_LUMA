`timescale 1ns / 1ps
// luma_hpass.sv - Luma H-Pass Deblocking Engine
// Flow per CTU row:
//   STALL (96 cyc) → ACTIVE edges 1-31 (31×32 cyc) → STALL → repeat
// Each active edge: col_cnt sweeps 0→31 (32 reads across full CTU width)
// Row address: row_idx = edge_cnt % 5 (circular 20-row buffer)

module luma_hpass #(
    parameter int BIT_DEPTH = 8
) (
    input logic clk,
    input logic rst_n,
    input logic load_valid,

    // Combinational input from luma_stage_buf (4x16 transposed read)
    input logic [BIT_DEPTH-1:0] block_in[0:3][0:15],

    // Address outputs → drive luma_stage_buf read port
    output logic [2:0] row_idx,
    output logic [4:0] col_idx,
    output logic       read_en,  // 1 = read data valid

    // Corner masking → driven to luma_stage_buf mask1/mask31
    output logic mask1,  // edge 1: mask top block
    output logic mask31  // edge 31: mask bottom block
);

  // =========================================================================
  // State machine
  // =========================================================================
  typedef enum logic [1:0] {
    STALL,
    ACTIVE
  } state_t;
  state_t state;

  logic [6:0] stall_cnt;  // 0-95
  logic [4:0] edge_cnt;  // 1-31
  logic [4:0] col_cnt;  // 0-31

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= STALL;
      stall_cnt <= 7'd0;
      edge_cnt  <= 5'd1;
      col_cnt   <= 5'd0;
    end else if (load_valid) begin
      case (state)

        STALL: begin
          if (stall_cnt == 7'd127) begin
            stall_cnt <= 7'd0;
            state     <= ACTIVE;
          end else begin
            stall_cnt <= stall_cnt + 1'b1;
          end
        end

        ACTIVE: begin
          if (col_cnt == 5'd31) begin
            col_cnt <= 5'd0;
            if (edge_cnt == 5'd31) begin
              edge_cnt <= 5'd1;
              state    <= STALL;
            end else begin
              edge_cnt <= edge_cnt + 1'b1;
            end
          end else begin
            col_cnt <= col_cnt + 1'b1;
          end
        end

        default: state <= STALL;
      endcase
    end
  end

  // =========================================================================
  // Output assignments
  // =========================================================================
  assign read_en = (state == ACTIVE) && load_valid;
  assign col_idx = col_cnt;
  assign row_idx = (edge_cnt + 5) % 6;  // (edge_cnt-1)%6
  assign mask1   = (state == ACTIVE) && (edge_cnt == 5'd1);
  assign mask31  = (state == ACTIVE) && (edge_cnt == 5'd31);

endmodule

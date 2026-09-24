////////////////////////////////////////////////////////////////////////////
//
// uart_status_tx.v
//
// Periodically emits a fixed ASCII banner over the board UART so the host PC
// can confirm that the debug channel is alive.
//
// First bring-up message (GAP_MS apart, default 100 ms):
//     "TI60 UART OK\r\n"
//
// This exists purely to validate four things in one shot:
//   1. the pin assignment (txd -> GPIOR_28)
//   2. the baud generator (115200 @ CLK_25M)
//   3. which FT4232H channel the board UART lands on
//   4. that the channel is usable for later numeric telemetry
//
// Later telemetry (edge ratio, frame counters, threshold values, ...) can
// replace the ROM below; the byte-level transmitter is untouched.
//
////////////////////////////////////////////////////////////////////////////

module uart_status_tx #(
    parameter integer CLK_HZ = 25000000,
    parameter integer BAUD   = 115200,
    parameter integer GAP_MS = 100
) (
    input  wire i_clk,
    input  wire i_rstn,
    output wire o_txd
);

    localparam integer MSG_LEN  = 14;
    localparam integer GAP_CLKS = (CLK_HZ / 1000) * GAP_MS;

    function [7:0] msg_byte;
        input integer idx;
        begin
            case (idx)
                0:  msg_byte = "T";
                1:  msg_byte = "I";
                2:  msg_byte = "6";
                3:  msg_byte = "0";
                4:  msg_byte = " ";
                5:  msg_byte = "U";
                6:  msg_byte = "A";
                7:  msg_byte = "R";
                8:  msg_byte = "T";
                9:  msg_byte = " ";
                10: msg_byte = "O";
                11: msg_byte = "K";
                12: msg_byte = 8'h0D;   // CR
                13: msg_byte = 8'h0A;   // LF
                default: msg_byte = 8'h00;
            endcase
        end
    endfunction

    localparam [1:0] S_GAP  = 2'd0,
                     S_SEND = 2'd1;

    reg [1:0]        state;
    reg [31:0]       gap_cnt;
    reg [4:0]        char_idx;
    reg              tx_valid;
    reg [7:0]        tx_byte;
    wire             tx_busy;

    uart_tx #(
        .CLK_HZ (CLK_HZ),
        .BAUD   (BAUD)
    ) u_uart_tx (
        .i_clk   (i_clk),
        .i_rstn  (i_rstn),
        .i_data  (tx_byte),
        .i_valid (tx_valid),
        .o_busy  (tx_busy),
        .o_txd   (o_txd)
    );

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            state    <= S_GAP;
            gap_cnt  <= 32'd0;
            char_idx <= 5'd0;
            tx_valid <= 1'b0;
            tx_byte  <= 8'h00;
        end else begin
            // i_valid is a one-clock pulse, so clear it every cycle.
            tx_valid <= 1'b0;

            case (state)
                S_GAP: begin
                    // Wait out the inter-message gap once the line is free.
                    if (!tx_busy) begin
                        if (gap_cnt >= GAP_CLKS) begin
                            gap_cnt  <= 32'd0;
                            char_idx <= 5'd0;
                            state    <= S_SEND;
                        end else begin
                            gap_cnt <= gap_cnt + 32'd1;
                        end
                    end
                end

                S_SEND: begin
                    // Offer one byte whenever the transmitter is idle.
                    if (!tx_busy) begin
                        tx_valid <= 1'b1;
                        tx_byte  <= msg_byte(char_idx);
                        if (char_idx == (MSG_LEN - 1)) begin
                            state <= S_GAP;
                        end else begin
                            char_idx <= char_idx + 5'd1;
                        end
                    end
                end

                default: state <= S_GAP;
            endcase
        end
    end

endmodule

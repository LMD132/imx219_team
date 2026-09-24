////////////////////////////////////////////////////////////////////////////
//
// uart_telemetry.v
//
// Numeric status line over the board UART, replacing the fixed banner of
// uart_status_tx.v (which stays in the tree as the record of the bring-up).
//
// Two 14-byte messages are emitted at 115200 8N1:
//
//   power-up, once : "TI60 UART OK\r\n"
//   after that     : "THR=nnn SH=n\r\n"  every PERIOD_MS, or immediately
//                    whenever i_update pulses (a key changed a threshold)
//
// Keeping the bring-up banner as the first line means the UART evidence from
// the previous verified bitstream still appears, and the host script does not
// need to change to confirm the channel is alive.
//
// The four-state pacer is copied from uart_status_tx.v on purpose: uart_tx's
// o_busy is registered, so there are two clocks between "offer a byte" and
// "busy is high". A two-state pacer that only tests !tx_busy fires twice in
// that window and drops every other byte. Do not simplify it back to two
// states.
//
////////////////////////////////////////////////////////////////////////////

module uart_telemetry #(
    parameter integer CLK_HZ    = 25000000,
    parameter integer BAUD      = 115200,
    parameter integer PERIOD_MS = 500
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [10:0] i_threshold,
    input  wire [3:0]  i_shift,
    input  wire        i_update,    // push a fresh line as soon as the line is free
    output wire        o_txd
);

    localparam integer MSG_LEN  = 14;   // both messages are exactly this long
    localparam integer GAP_CLKS = (CLK_HZ / 1000) * PERIOD_MS;

    // ---------------------------------------------------------------
    // Decimal digits for the floor. Only 0..255 is reachable, so three
    // digits are enough. Constant division/multiply on an 8-bit value
    // keeps this to a handful of LUTs.
    // ---------------------------------------------------------------
    wire [7:0] thr8 = i_threshold[7:0];
    wire [7:0] d_h  = thr8 / 8'd100;
    wire [7:0] rem  = thr8 - (d_h * 8'd100);
    wire [7:0] d_t  = rem / 8'd10;
    wire [7:0] d_u  = rem - (d_t * 8'd10);

    function [7:0] msg_byte;
        input        banner_sel;
        input [4:0]  idx;
        input [3:0]  dh, dt, du, ds;
        begin
            if (banner_sel) begin
                case (idx)
                    5'd0:    msg_byte = "T";
                    5'd1:    msg_byte = "I";
                    5'd2:    msg_byte = "6";
                    5'd3:    msg_byte = "0";
                    5'd4:    msg_byte = " ";
                    5'd5:    msg_byte = "U";
                    5'd6:    msg_byte = "A";
                    5'd7:    msg_byte = "R";
                    5'd8:    msg_byte = "T";
                    5'd9:    msg_byte = " ";
                    5'd10:   msg_byte = "O";
                    5'd11:   msg_byte = "K";
                    5'd12:   msg_byte = 8'h0D;   // CR
                    default: msg_byte = 8'h0A;   // LF
                endcase
            end else begin
                case (idx)
                    5'd0:    msg_byte = "T";
                    5'd1:    msg_byte = "H";
                    5'd2:    msg_byte = "R";
                    5'd3:    msg_byte = "=";
                    5'd4:    msg_byte = 8'h30 + {4'b0, dh};
                    5'd5:    msg_byte = 8'h30 + {4'b0, dt};
                    5'd6:    msg_byte = 8'h30 + {4'b0, du};
                    5'd7:    msg_byte = " ";
                    5'd8:    msg_byte = "S";
                    5'd9:    msg_byte = "H";
                    5'd10:   msg_byte = "=";
                    5'd11:   msg_byte = 8'h30 + {4'b0, ds};
                    5'd12:   msg_byte = 8'h0D;   // CR
                    default: msg_byte = 8'h0A;   // LF
                endcase
            end
        end
    endfunction

    localparam [1:0] S_GAP   = 2'd0,
                     S_LOAD  = 2'd1,
                     S_START = 2'd2,
                     S_SEND  = 2'd3;

    reg [1:0]  state;
    reg [31:0] gap_cnt;
    reg [4:0]  char_idx;
    reg        tx_valid;
    reg [7:0]  tx_byte;
    reg        banner;
    reg        pending;
    // Snapshot of the values used for the line currently being sent, so a key
    // press in the middle of a message cannot mix two readings in one line.
    reg [3:0]  d_h_reg, d_t_reg, d_u_reg, d_s_reg;
    wire       tx_busy;

    uart_tx #(
        .CLK_HZ (CLK_HZ),
        .BAUD   (BAUD)
    ) u_uart_tx (
        .i_clk   (clk),
        .i_rstn  (rst_n),
        .i_data  (tx_byte),
        .i_valid (tx_valid),
        .o_busy  (tx_busy),
        .o_txd   (o_txd)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_GAP;
            gap_cnt <= 32'd0;
            char_idx <= 5'd0;
            tx_valid <= 1'b0;
            tx_byte  <= 8'h00;
            banner   <= 1'b1;
            pending  <= 1'b1;       // send the banner straight after reset
            d_h_reg  <= 4'd0;
            d_t_reg  <= 4'd0;
            d_u_reg  <= 4'd0;
            d_s_reg  <= 4'd1;
        end else begin
            tx_valid <= 1'b0;       // i_valid is a one-clock pulse

            if (i_update) pending <= 1'b1;

            case (state)
                // Wait out the gap once the line is free, unless a key press
                // asked for an immediate line.
                S_GAP: begin
                    if (!tx_busy) begin
                        if (pending || (gap_cnt >= GAP_CLKS)) begin
                            gap_cnt  <= 32'd0;
                            char_idx <= 5'd0;
                            pending  <= 1'b0;
                            d_h_reg  <= d_h[3:0];
                            d_t_reg  <= d_t[3:0];
                            d_u_reg  <= d_u[3:0];
                            d_s_reg  <= i_shift;
                            state    <= S_LOAD;
                        end else begin
                            gap_cnt <= gap_cnt + 32'd1;
                        end
                    end
                end

                // Present one byte; it is latched by uart_tx next clock.
                S_LOAD: begin
                    tx_valid <= 1'b1;
                    tx_byte  <= msg_byte(banner, char_idx,
                                         d_h_reg, d_t_reg, d_u_reg, d_s_reg);
                    state    <= S_START;
                end

                // Hold until the transmitter actually reports busy.
                S_START: begin
                    if (tx_busy) state <= S_SEND;
                end

                // Frame is on the wire; wait for it to finish, then advance.
                S_SEND: begin
                    if (!tx_busy) begin
                        if (char_idx == (MSG_LEN - 1)) begin
                            banner <= 1'b0;     // the banner is a one-shot
                            state  <= S_GAP;
                        end else begin
                            char_idx <= char_idx + 5'd1;
                            state    <= S_LOAD;
                        end
                    end
                end

                default: state <= S_GAP;
            endcase
        end
    end

endmodule

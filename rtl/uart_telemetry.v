////////////////////////////////////////////////////////////////////////////
//
// uart_telemetry.v
//
// Numeric status line over the board UART, replacing the fixed banner of
// uart_status_tx.v (which stays in the tree as the record of the bring-up).
//
// Two messages are emitted at 115200 8N1:
//
//   power-up, once : "TI60 UART OK\r\n"                    (14 bytes)
//   after that     : "THR=nnn SH=n DS=k PIX=nnnnnn\r\n"    (30 bytes)
//                    every PERIOD_MS, or immediately whenever i_update pulses
//
// DS  is the despeckle neighbour threshold of edge_overlay_720p.v, so the log
//     records which filter setting a picture was taken with.
// PIX is the number of active pixels counted in the last video frame. A clean
//     720p stream gives exactly 1280 x 720 = 921600, so this one number is the
//     on-board evidence that the pixel pipeline sees complete frames and does
//     not drop or displace lines.
//
// PIX is 20 bits wide and is converted to six decimal digits with a sequential
// double-dabble (20 shift-and-add-3 steps, one per clock). A constant division
// on a 20-bit value would infer a wide multiplier instead.
//
// The four-state pacer is copied from uart_status_tx.v on purpose: uart_tx's
// o_busy is registered, so there are two clocks between "offer a byte" and
// "busy is high". A two-state pacer that only tests !tx_busy fires twice in
// that window and drops every other byte. Do not simplify it back to two
// states.
//
// The banner and the status line have different lengths, so the pacer works
// from a per-message length instead of one constant.
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
    input  wire [3:0]  i_despeckle,
    input  wire [19:0] i_frame_pix,  // active pixels in the last video frame
    input  wire        i_update,     // push a fresh line as soon as the line is free
    output wire        o_txd
);

    localparam [4:0]  MSG_LEN_BANNER = 5'd14;
    localparam [4:0]  MSG_LEN_STATUS = 5'd30;
    localparam integer GAP_CLKS      = (CLK_HZ / 1000) * PERIOD_MS;

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
        input [3:0]  dh, dt, du, ds, dk;
        input [23:0] pix_bcd;
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
                    5'd12:   msg_byte = " ";
                    5'd13:   msg_byte = "D";
                    5'd14:   msg_byte = "S";
                    5'd15:   msg_byte = "=";
                    5'd16:   msg_byte = 8'h30 + {4'b0, dk};
                    5'd17:   msg_byte = " ";
                    5'd18:   msg_byte = "P";
                    5'd19:   msg_byte = "I";
                    5'd20:   msg_byte = "X";
                    5'd21:   msg_byte = "=";
                    5'd22:   msg_byte = 8'h30 + pix_bcd[23:20];
                    5'd23:   msg_byte = 8'h30 + pix_bcd[19:16];
                    5'd24:   msg_byte = 8'h30 + pix_bcd[15:12];
                    5'd25:   msg_byte = 8'h30 + pix_bcd[11:8];
                    5'd26:   msg_byte = 8'h30 + pix_bcd[7:4];
                    5'd27:   msg_byte = 8'h30 + pix_bcd[3:0];
                    5'd28:   msg_byte = 8'h0D;   // CR
                    default: msg_byte = 8'h0A;   // LF
                endcase
            end
        end
    endfunction

    localparam [2:0] S_GAP   = 3'd0,
                     S_CONV  = 3'd1,
                     S_LATCH = 3'd2,
                     S_LOAD  = 3'd3,
                     S_START = 3'd4,
                     S_SEND  = 3'd5;

    reg [2:0]  state;
    reg [31:0] gap_cnt;
    reg [4:0]  char_idx;
    reg        tx_valid;
    reg [7:0]  tx_byte;
    reg        banner;
    reg        pending;
    // Snapshot of the values used for the line currently being sent, so a key
    // press in the middle of a message cannot mix two readings in one line.
    reg [3:0]  d_h_reg, d_t_reg, d_u_reg, d_s_reg, d_k_reg;
    reg [23:0] pix_bcd_reg;
    wire       tx_busy;

    // The banner is shorter than a status line, so the end-of-message test in
    // S_SEND has to look at the length of the message being sent.
    wire [4:0] msg_len = banner ? MSG_LEN_BANNER : MSG_LEN_STATUS;

    // Sequential double-dabble state: 20 binary bits -> six BCD digits.
    reg [19:0] bcd_bin;
    reg [23:0] bcd_out;
    reg [4:0]  conv_cnt;

    // "Add three" adjustment applied to every digit that is five or more
    // before each shift. No digit can overflow its nibble (9 + 3 = 12), so the
    // six nibbles can be summed as one 24-bit value without carries leaking
    // between digits.
    wire [3:0] adj5 = (bcd_out[23:20] >= 4'd5) ? 4'd3 : 4'd0;
    wire [3:0] adj4 = (bcd_out[19:16] >= 4'd5) ? 4'd3 : 4'd0;
    wire [3:0] adj3 = (bcd_out[15:12] >= 4'd5) ? 4'd3 : 4'd0;
    wire [3:0] adj2 = (bcd_out[11:8]  >= 4'd5) ? 4'd3 : 4'd0;
    wire [3:0] adj1 = (bcd_out[7:4]   >= 4'd5) ? 4'd3 : 4'd0;
    wire [3:0] adj0 = (bcd_out[3:0]   >= 4'd5) ? 4'd3 : 4'd0;
    wire [23:0] bcd_dab = bcd_out + {adj5, adj4, adj3, adj2, adj1, adj0};

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
            state     <= S_GAP;
            gap_cnt   <= 32'd0;
            char_idx  <= 5'd0;
            tx_valid  <= 1'b0;
            tx_byte   <= 8'h00;
            banner    <= 1'b1;
            pending   <= 1'b1;      // send the banner straight after reset
            d_h_reg   <= 4'd0;
            d_t_reg   <= 4'd0;
            d_u_reg   <= 4'd0;
            d_s_reg   <= 4'd1;
            d_k_reg   <= 4'd3;
            pix_bcd_reg <= 24'd0;
            bcd_bin   <= 20'd0;
            bcd_out   <= 24'd0;
            conv_cnt  <= 5'd0;
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
                            d_k_reg  <= i_despeckle;
                            bcd_bin  <= i_frame_pix;
                            bcd_out  <= 24'd0;
                            conv_cnt <= 5'd0;
                            // The banner has no PIX field, so it can skip the
                            // conversion entirely.
                            state    <= banner ? S_LOAD : S_CONV;
                        end else begin
                            gap_cnt <= gap_cnt + 32'd1;
                        end
                    end
                end

                // 20 shift-and-add-3 steps turn 20 binary bits into six digits.
                S_CONV: begin
                    bcd_out <= {bcd_dab[22:0], bcd_bin[19]};
                    bcd_bin <= {bcd_bin[18:0], 1'b0};
                    if (conv_cnt == 5'd19) state    <= S_LATCH;
                    else                   conv_cnt <= conv_cnt + 5'd1;
                end

                // bcd_out settles one clock after the last shift.
                S_LATCH: begin
                    pix_bcd_reg <= bcd_out;
                    state       <= S_LOAD;
                end

                // Present one byte; it is latched by uart_tx next clock.
                S_LOAD: begin
                    tx_valid <= 1'b1;
                    tx_byte  <= msg_byte(banner, char_idx,
                                         d_h_reg, d_t_reg, d_u_reg,
                                         d_s_reg, d_k_reg, pix_bcd_reg);
                    state    <= S_START;
                end

                // Hold until the transmitter actually reports busy.
                S_START: begin
                    if (tx_busy) state <= S_SEND;
                end

                // Frame is on the wire; wait for it to finish, then advance.
                S_SEND: begin
                    if (!tx_busy) begin
                        if (char_idx == (msg_len - 5'd1)) begin
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
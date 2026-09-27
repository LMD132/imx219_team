////////////////////////////////////////////////////////////////////////////
//
// alg_cfg_telemetry.v
//
// Status line for the runtime edge parameters, the transmit half of the
// PC tuning channel (alg_cfg_uart.v is the receive half).
//
// One 77 byte ASCII line every PERIOD_MS, plus an immediate line after every
// accepted command, so a slider on the host can be confirmed against what the
// board actually latched instead of being trusted:
//
//     M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 GF0400 CAM0077=C0\r\n
//
// The line is fixed layout: every field is either a literal or exactly the
// same width in every message, so the host can find the values by byte
// position and a human reading a serial terminal sees decimal.
//
// The last field is the answer to the host's X<grp> read-back command:
// CAM<4 decimal digits of the requested group>=<2 hex digits of the byte the
// camera returned> (FF until the first read).
//
// EPS<n> between OVC and CAM is the NMS tolerance (0..8, see alg_nms.v).
// EPF<n> (0..2, pre-filter: off / gaussian3x3 / guided) and GF<nnnn>
// (guided-filter eps, 0..2047) were appended after it for the same reason:
// every field before them keeps its byte position, and the host regex accepts
// the 77 byte line as well as the older 65 and 60 byte ones.
//
// The three 11-bit thresholds and the 10-bit read-back group index are
// converted with the double-dabble shift-and-add-3 algorithm, one value at a
// time through a single engine (11 shifts each).  There is no divider and no
// RAM in this file.
//
// The pacer below is the handshake that the sibling project already debugged
// on this board: uart_tx.o_busy is registered, so there are two clocks between
// offering a byte and busy going high. S_LOAD offers the byte, S_START waits
// for busy to rise, S_SEND waits for it to fall again, and only then does the
// character index advance - offering twice inside that window is what made an
// earlier pacer send only every other character.
//
////////////////////////////////////////////////////////////////////////////

module alg_cfg_telemetry #(
    parameter integer CLK_HZ    = 25000000,
    parameter integer BAUD      = 115200,
    parameter integer PERIOD_MS = 500
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  i_mode,
    input  wire [10:0] i_t,
    input  wire [10:0] i_lo,
    input  wire [10:0] i_hi,
    input  wire [3:0]  i_eps,
    input  wire [1:0]  i_epf,
    input  wire [10:0] i_gf_eps,
    input  wire        i_median,
    input  wire        i_gauss,
    input  wire        i_isol,
    input  wire [1:0]  i_disp,
    input  wire        i_ovc,
    input  wire [9:0]  i_cam_grp,  // X<grp> read-back address (decimal)
    input  wire [7:0]  i_cam_val,  // byte returned by that read-back (hex)
    input  wire        i_update,    // push a fresh line as soon as one is free
    output wire        o_txd
);

    localparam [6:0] MSG_LEN = 7'd77;
    localparam integer GAP_CLKS = (CLK_HZ / 1000) * PERIOD_MS;

    // ------------------------------------------------------------------ text
    function [7:0] digit_of;
        input [3:0] d;
        begin
            digit_of = 8'h30 + {4'b0, d};
        end
    endfunction

    // '0'..'9' then 'A'..'F' (the register values in the .mem file are hex)
    function [7:0] hex_of;
        input [3:0] d;
        begin
            hex_of = (d < 4'd10) ? (8'h30 + {4'b0, d}) : (8'h37 + {4'b0, d});
        end
    endfunction

    function [7:0] msg_byte;
        input [6:0]  idx;
        input [15:0] t_bcd;
        input [15:0] lo_bcd;
        input [15:0] hi_bcd;
        input [15:0] gf_bcd;
        input [15:0] cam_bcd;
        input [7:0]  cam_val;
        input [1:0]  mode;
        input [1:0]  disp;
        input        med;
        input        gau;
        input        iso;
        input        ovc;
        input [3:0]  eps;
        input [1:0]  epf;
        begin
            case (idx)
                6'd0:  msg_byte = "M";
                6'd1:  msg_byte = digit_of({2'b0, mode});
                6'd2:  msg_byte = " ";
                6'd3:  msg_byte = "T";
                6'd4:  msg_byte = digit_of(t_bcd[15:12]);
                6'd5:  msg_byte = digit_of(t_bcd[11:8]);
                6'd6:  msg_byte = digit_of(t_bcd[7:4]);
                6'd7:  msg_byte = digit_of(t_bcd[3:0]);
                6'd8:  msg_byte = " ";
                6'd9:  msg_byte = "L";
                6'd10: msg_byte = "O";
                6'd11: msg_byte = digit_of(lo_bcd[15:12]);
                6'd12: msg_byte = digit_of(lo_bcd[11:8]);
                6'd13: msg_byte = digit_of(lo_bcd[7:4]);
                6'd14: msg_byte = digit_of(lo_bcd[3:0]);
                6'd15: msg_byte = " ";
                6'd16: msg_byte = "H";
                6'd17: msg_byte = "I";
                6'd18: msg_byte = digit_of(hi_bcd[15:12]);
                6'd19: msg_byte = digit_of(hi_bcd[11:8]);
                6'd20: msg_byte = digit_of(hi_bcd[7:4]);
                6'd21: msg_byte = digit_of(hi_bcd[3:0]);
                6'd22: msg_byte = " ";
                6'd23: msg_byte = "M";
                6'd24: msg_byte = "E";
                6'd25: msg_byte = "D";
                6'd26: msg_byte = digit_of({3'b0, med});
                6'd27: msg_byte = " ";
                6'd28: msg_byte = "G";
                6'd29: msg_byte = "A";
                6'd30: msg_byte = "U";
                6'd31: msg_byte = digit_of({3'b0, gau});
                6'd32: msg_byte = " ";
                6'd33: msg_byte = "I";
                6'd34: msg_byte = "S";
                6'd35: msg_byte = "O";
                6'd36: msg_byte = digit_of({3'b0, iso});
                6'd37: msg_byte = " ";
                6'd38: msg_byte = "D";
                6'd39: msg_byte = "S";
                6'd40: msg_byte = "P";
                6'd41: msg_byte = digit_of({2'b0, disp});
                6'd42: msg_byte = " ";
                6'd43: msg_byte = "O";
                6'd44: msg_byte = "V";
                6'd45: msg_byte = "C";
                6'd46: msg_byte = digit_of({3'b0, ovc});
                6'd47: msg_byte = " ";
                6'd48: msg_byte = "E";
                6'd49: msg_byte = "P";
                6'd50: msg_byte = "S";
                6'd51: msg_byte = digit_of(eps);
                6'd52: msg_byte = " ";
                6'd53: msg_byte = "E";
                6'd54: msg_byte = "P";
                6'd55: msg_byte = "F";
                6'd56: msg_byte = digit_of({4'b0, epf});
                6'd57: msg_byte = " ";
                6'd58: msg_byte = "G";
                6'd59: msg_byte = "F";
                6'd60: msg_byte = digit_of(gf_bcd[15:12]);
                6'd61: msg_byte = digit_of(gf_bcd[11:8]);
                6'd62: msg_byte = digit_of(gf_bcd[7:4]);
                6'd63: msg_byte = digit_of(gf_bcd[3:0]);
                6'd64: msg_byte = " ";
                6'd65: msg_byte = "C";
                6'd66: msg_byte = "A";
                6'd67: msg_byte = "M";
                6'd68: msg_byte = digit_of(cam_bcd[15:12]);
                6'd69: msg_byte = digit_of(cam_bcd[11:8]);
                6'd70: msg_byte = digit_of(cam_bcd[7:4]);
                6'd71: msg_byte = digit_of(cam_bcd[3:0]);
                6'd72: msg_byte = "=";
                6'd73: msg_byte = hex_of(cam_val[7:4]);
                6'd74: msg_byte = hex_of(cam_val[3:0]);
                6'd75: msg_byte = 8'h0D;   // CR
                default: msg_byte = 8'h0A; // LF
            endcase
        end
    endfunction

    // ------------------------------------------------------------------ state
    localparam [2:0] ST_GAP   = 3'd0,
                     ST_SNAP  = 3'd1,
                     ST_CONV  = 3'd2,
                     ST_LATCH = 3'd3,
                     ST_LOAD  = 3'd4,
                     ST_START = 3'd5,
                     ST_SEND  = 3'd6;

    reg [2:0]  state;
    reg [31:0] gap_cnt;
    reg [6:0]  char_idx;        // 65 字节行: 下标要 7 位, 6 位装不下 64 会回卷
    reg        tx_valid;
    reg [7:0]  tx_byte;
    reg        pending;

    // Snapshot of the values used by the line being sent, so a command that
    // lands mid-message cannot mix two readings in one line.
    reg [1:0]  d_mode, d_disp;
    reg [10:0] d_t, d_lo, d_hi;
    reg        d_med, d_gau, d_iso, d_ovc;
    reg [3:0]  d_eps;
    reg [1:0]  d_epf;
    reg [10:0] d_gf_eps;
    reg [15:0] t_bcd, lo_bcd, hi_bcd, gf_bcd, cam_bcd;
    reg [9:0]  d_cam_grp;
    reg [7:0]  d_cam_val;

    // One double-dabble engine, used five times per line (t, lo, hi, the
    // guided-filter eps, and the read-back group index).  conv_sel therefore
    // counts to 4; it was 0..3 when the line was 65 bytes.
    reg [15:0] bcd_reg;
    reg [10:0] bin_reg;
    reg [2:0]  conv_sel;
    reg [3:0]  conv_cnt;

    wire [3:0] adj3 = (bcd_reg[15:12] >= 4'd5) ? 4'd3 : 4'd0;
    wire [3:0] adj2 = (bcd_reg[11:8]  >= 4'd5) ? 4'd3 : 4'd0;
    wire [3:0] adj1 = (bcd_reg[7:4]   >= 4'd5) ? 4'd3 : 4'd0;
    wire [3:0] adj0 = (bcd_reg[3:0]   >= 4'd5) ? 4'd3 : 4'd0;
    wire [15:0] bcd_dab = bcd_reg + {adj3, adj2, adj1, adj0};

    wire tx_busy;

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
            state     <= ST_GAP;
            gap_cnt   <= 32'd0;
            char_idx  <= 6'd0;
            tx_valid  <= 1'b0;
            tx_byte   <= 8'h00;
            pending   <= 1'b1;      // push the power-on values straight away
            d_mode    <= 2'd0;
            d_disp    <= 2'd0;
            d_t       <= 11'd0;
            d_lo      <= 11'd0;
            d_hi      <= 11'd0;
            d_med     <= 1'b0;
            d_gau     <= 1'b0;
            d_iso     <= 1'b0;
            d_ovc     <= 1'b0;
            d_eps     <= 4'd0;
            d_epf     <= 2'd0;
            d_gf_eps  <= 11'd0;
            t_bcd     <= 16'd0;
            lo_bcd    <= 16'd0;
            hi_bcd    <= 16'd0;
            gf_bcd    <= 16'd0;
            cam_bcd   <= 16'd0;
            d_cam_grp <= 10'd0;
            d_cam_val <= 8'hFF;   // piv2_config's read register resets to FF
            bcd_reg   <= 16'd0;
            bin_reg   <= 11'd0;
            conv_sel  <= 3'd0;
            conv_cnt  <= 4'd0;
        end else begin
            tx_valid <= 1'b0;       // i_valid is a one-clock pulse

            if (i_update) pending <= 1'b1;

            case (state)
                // Wait out the gap once the wire is free, unless a command
                // asked for an immediate line.
                ST_GAP: begin
                    if (!tx_busy) begin
                        if (pending || (gap_cnt >= GAP_CLKS)) begin
                            gap_cnt <= 32'd0;
                            pending <= 1'b0;
                            d_mode  <= i_mode;
                            d_t     <= i_t;
                            d_lo    <= i_lo;
                            d_hi    <= i_hi;
                            d_med   <= i_median;
                            d_gau   <= i_gauss;
                            d_iso   <= i_isol;
                            d_disp  <= i_disp;
                            d_ovc   <= i_ovc;
                            d_eps   <= i_eps;
                            d_epf   <= i_epf;
                            d_gf_eps<= i_gf_eps;
                            d_cam_grp<= i_cam_grp;
                            d_cam_val<= i_cam_val;
                            state   <= ST_SNAP;
                        end else begin
                            gap_cnt <= gap_cnt + 32'd1;
                        end
                    end
                end

                // Start the conversion of the first value.
                ST_SNAP: begin
                    bcd_reg  <= 16'd0;
                    bin_reg  <= d_t;
                    conv_sel <= 3'd0;
                    conv_cnt <= 4'd0;
                    state    <= ST_CONV;
                end

                // 11 shift-and-add-3 steps turn 11 binary bits into 4 digits.
                ST_CONV: begin
                    bcd_reg <= {bcd_dab[14:0], bin_reg[10]};
                    bin_reg <= {bin_reg[9:0], 1'b0};
                    if (conv_cnt == 4'd10) state    <= ST_LATCH;
                    else                   conv_cnt <= conv_cnt + 4'd1;
                end

                // bcd_reg settles one clock after the last shift.
                ST_LATCH: begin
                    case (conv_sel)
                        3'd0:    t_bcd   <= bcd_reg;
                        3'd1:    lo_bcd  <= bcd_reg;
                        3'd2:    hi_bcd  <= bcd_reg;
                        3'd3:    gf_bcd  <= bcd_reg;
                        default: cam_bcd <= bcd_reg;
                    endcase
                    if (conv_sel == 3'd4) begin
                        char_idx <= 7'd0;
                        state    <= ST_LOAD;
                    end else begin
                        conv_sel <= conv_sel + 3'd1;
                        bcd_reg  <= 16'd0;
                        bin_reg  <= (conv_sel == 3'd0) ? d_lo :
                                    (conv_sel == 3'd1) ? d_hi :
                                    (conv_sel == 3'd2) ? d_gf_eps :
                                                         {1'b0, d_cam_grp};
                        conv_cnt <= 4'd0;
                        state    <= ST_CONV;
                    end
                end

                // Present one byte; uart_tx latches it next clock.
                ST_LOAD: begin
                    tx_valid <= 1'b1;
                    tx_byte  <= msg_byte(char_idx, t_bcd, lo_bcd, hi_bcd,
                                         gf_bcd, cam_bcd, d_cam_val,
                                         d_mode, d_disp, d_med, d_gau, d_iso, d_ovc,
                                         d_eps, d_epf);
                    state    <= ST_START;
                end

                // Hold until the transmitter actually reports busy.
                ST_START: begin
                    if (tx_busy) state <= ST_SEND;
                end

                // Frame is on the wire; wait for it to finish, then advance.
                ST_SEND: begin
                    if (!tx_busy) begin
                        if (char_idx == (MSG_LEN - 7'd1)) begin
                            state <= ST_GAP;
                        end else begin
                            char_idx <= char_idx + 7'd1;
                            state    <= ST_LOAD;
                        end
                    end
                end

                default: state <= ST_GAP;
            endcase
        end
    end

endmodule

////////////////////////////////////////////////////////////////////////////
//
// alg_cfg_uart.v
//
// Runtime parameter channel for the contest-4 edge pipeline (rtl/algo/alg_top.v).
//
// alg_top already takes every tunable point as a register port (cfg_mode,
// cfg_t, cfg_lo, cfg_hi, cfg_median_en, cfg_gauss_en, cfg_isol_en,
// cfg_disp_mode, cfg_ov_color), but the top level ties them to constants, so
// tuning used to mean editing Verilog, recompiling (~2 min) and re-flashing
// (~1 min) for every value. This module turns them into live registers fed
// from the board UART: FT4232H channel C, already proven on this board by the
// sibling project (pins R14 = GPIOR_28 out, R4 = GPIOL_02 in, 115200 8N1).
//
// Protocol: one ASCII line per parameter, terminated by LF or CR.
//
//     M<n>   cfg_mode       0 = Sobel single threshold
//                           1 = Sobel dual threshold
//                           2 = Canny (values above 2 clamp to 2)
//     T<n>   cfg_t          Sobel / NMS threshold   0..2047
//     L<n>   cfg_lo         hysteresis low          0..2047
//     H<n>   cfg_hi         hysteresis high         0..2047
//     N<n>   cfg_median_en  0/1
//     G<n>   cfg_gauss_en   0/1
//     I<n>   cfg_isol_en    0/1
//     D<n>   cfg_disp_mode  0..3
//     C<n>   cfg_ov_color   0/1
//     R      every parameter back to its power-on default
//
// "T24", "T=24" and "T 24" are the same command: every character that is
// neither a digit nor a key letter is a separator. The value is a
// *saturating* accumulate of the digits in the line, so "T9999" clamps
// instead of wrapping. Several commands may share one line ("T24 L21 H58");
// each one commits when the next key letter or the end of line shows up.
//
// Nothing here is in the video path: this register file lives in the CLK_25M
// domain and alg_cfg_sync.v hands the values to the HDMI pixel clock domain.
//
////////////////////////////////////////////////////////////////////////////

module alg_cfg_uart #(
    parameter [1:0]  MODE_INIT   = 2'd2,
    parameter [10:0] T_INIT      = 11'd24,
    parameter [10:0] LO_INIT     = 11'd21,
    parameter [10:0] HI_INIT     = 11'd58,
    parameter        MEDIAN_INIT = 1'b1,
    parameter        GAUSS_INIT  = 1'b0,
    parameter        ISOL_INIT   = 1'b1,
    parameter [1:0]  DISP_INIT   = 2'd0,
    parameter        OVC_INIT    = 1'b1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  i_data,
    input  wire        i_valid,
    output reg  [1:0]  o_mode,
    output reg  [10:0] o_t,
    output reg  [10:0] o_lo,
    output reg  [10:0] o_hi,
    output reg         o_median_en,
    output reg         o_gauss_en,
    output reg         o_isol_en,
    output reg  [1:0]  o_disp_mode,
    output reg         o_ov_color,
    output reg         o_commit
);

    localparam [3:0] K_NONE = 4'd0,
                     K_MODE = 4'd1,
                     K_T    = 4'd2,
                     K_LO   = 4'd3,
                     K_HI   = 4'd4,
                     K_MED  = 4'd5,
                     K_GAU  = 4'd6,
                     K_ISO  = 4'd7,
                     K_DSP  = 4'd8,
                     K_OVC  = 4'd9,
                     K_RST  = 4'd10;

    localparam S_KEY = 1'b0,
               S_VAL = 1'b1;

    // ---------------------------------------------------------------- decode
    // Explicit widths everywhere: an implicit wire here is one bit wide in
    // Efinity and silently destroys the digit value (see the trap recorded in
    // the sibling project's uart docs).
    function [3:0] key_of;
        input [7:0] c;
        begin
            case (c)
                8'h4D, 8'h6D: key_of = K_MODE;   // M m
                8'h54, 8'h74: key_of = K_T;      // T t
                8'h4C, 8'h6C: key_of = K_LO;     // L l
                8'h48, 8'h68: key_of = K_HI;     // H h
                8'h4E, 8'h6E: key_of = K_MED;    // N n
                8'h47, 8'h67: key_of = K_GAU;    // G g
                8'h49, 8'h69: key_of = K_ISO;    // I i
                8'h44, 8'h64: key_of = K_DSP;    // D d
                8'h43, 8'h63: key_of = K_OVC;    // C c
                8'h52, 8'h72: key_of = K_RST;    // R r
                default:      key_of = K_NONE;
            endcase
        end
    endfunction

    // Saturating accumulate of the digits in the line.  The intermediate has to
    // be wide enough for the *unsaturated* product (2047 * 10 + 9 = 20479), or
    // the comparison against the ceiling never fires and the value silently
    // wraps: a 13 bit intermediate turned "T9999" into 1807 instead of 2047.
    function [11:0] acc_next;
        input [11:0] a;
        input [7:0]  d;
        reg   [15:0] t;
        begin
            t = {4'b0, a} * 16'd10 + {8'b0, d};
            acc_next = (t > 16'd2047) ? 12'd2047 : t[11:0];
        end
    endfunction

    wire [3:0] w_key    = key_of(i_data);
    wire       w_is_dig = (i_data >= 8'h30) && (i_data <= 8'h39);
    wire [7:0] w_digit  = i_data - 8'h30;
    wire       w_eol    = (i_data == 8'h0A) || (i_data == 8'h0D);

    // ---------------------------------------------------------------- parser
    reg        state;
    reg [3:0]  key;
    reg [11:0] acc;

    reg        apply_en;
    reg [3:0]  apply_key;
    reg [11:0] apply_val;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_KEY;
            key       <= K_NONE;
            acc       <= 12'd0;
            apply_en  <= 1'b0;
            apply_key <= K_NONE;
            apply_val <= 12'd0;
        end else begin
            apply_en <= 1'b0;

            if (state == S_KEY) begin
                if (i_valid && (w_key != K_NONE)) begin
                    key   <= w_key;
                    acc   <= 12'd0;
                    state <= S_VAL;
                end
            end else begin
                if (i_valid) begin
                    if (w_eol) begin
                        // End of line: commit whatever has been accumulated.
                        apply_en  <= 1'b1;
                        apply_key <= key;
                        apply_val <= acc;
                        key       <= K_NONE;
                        state     <= S_KEY;
                    end else if (w_is_dig) begin
                        acc <= acc_next(acc, w_digit);
                    end else if (w_key != K_NONE) begin
                        // Next command on the same line: commit this one.
                        apply_en  <= 1'b1;
                        apply_key <= key;
                        apply_val <= acc;
                        key       <= w_key;
                        acc       <= 12'd0;
                    end
                    // anything else is a separator and is ignored
                end
            end
        end
    end

    // ----------------------------------------------------------------- apply
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_mode      <= MODE_INIT;
            o_t         <= T_INIT;
            o_lo        <= LO_INIT;
            o_hi        <= HI_INIT;
            o_median_en <= MEDIAN_INIT;
            o_gauss_en  <= GAUSS_INIT;
            o_isol_en   <= ISOL_INIT;
            o_disp_mode <= DISP_INIT;
            o_ov_color  <= OVC_INIT;
            o_commit    <= 1'b0;
        end else begin
            o_commit <= apply_en;
            if (apply_en) begin
                case (apply_key)
                    K_MODE: o_mode      <= (apply_val > 12'd2)    ? 2'd2    : apply_val[1:0];
                    K_T:    o_t         <= (apply_val > 12'd2047) ? 11'd2047 : apply_val[10:0];
                    K_LO:   o_lo        <= (apply_val > 12'd2047) ? 11'd2047 : apply_val[10:0];
                    K_HI:   o_hi        <= (apply_val > 12'd2047) ? 11'd2047 : apply_val[10:0];
                    K_MED:  o_median_en <= (apply_val != 12'd0);
                    K_GAU:  o_gauss_en  <= (apply_val != 12'd0);
                    K_ISO:  o_isol_en   <= (apply_val != 12'd0);
                    K_DSP:  o_disp_mode <= (apply_val > 12'd3)    ? 2'd3    : apply_val[1:0];
                    K_OVC:  o_ov_color  <= (apply_val != 12'd0);
                    K_RST: begin
                        o_mode      <= MODE_INIT;
                        o_t         <= T_INIT;
                        o_lo        <= LO_INIT;
                        o_hi        <= HI_INIT;
                        o_median_en <= MEDIAN_INIT;
                        o_gauss_en  <= GAUSS_INIT;
                        o_isol_en   <= ISOL_INIT;
                        o_disp_mode <= DISP_INIT;
                        o_ov_color  <= OVC_INIT;
                    end
                    default: ;   // K_NONE can only appear if a line was empty
                endcase
            end
        end
    end

endmodule

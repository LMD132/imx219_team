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
//     E<n>   cfg_nms_eps    NMS tolerance           0..8 (above 8 clamps to 8)
//                           Only the CANNY path reads it.  0 = the value the
//                           reference Python algorithm uses, so the default
//                           build is bit-identical to it; dragging it up on
//                           the PC tuner trades ~0.2 px of line width for a
//                           much steadier contour (see alg_nms.v).
//     P<n>   cfg_epf        pre-filter (EPF)          0..2 (above 2 clamps to 2)
//                           0 = off, 1 = 3x3 gaussian, 2 = guided filter.
//                           Same three settings as the reference live_tune.py
//                           EPF slider, whose default is 2 (guided filter).
//     F<n>   cfg_gf_eps     guided-filter eps        0..2047 (reference 400)
//                           The regularisation term of guided_filter(): the
//                           larger it is the flatter the result becomes.  Only
//                           the EPF=2 path reads it (see algo/alg_gf.v).
//     B<n>   cfg_brg        edge gap bridging         0..3 (above 3 clamps to 3)
//                           0 = off, 1/2/3 = fill 1 / 3 / 5 px holes of a broken
//                           line along the 4 axes of a 7x7 window.  Only the
//                           dual-threshold modes (mode 1/2) read it: it repairs
//                           the "a straight edge comes out as dashes" look of
//                           Canny.  Default 2.  See algo/alg_ebridge.v.
//     N<n>   cfg_median_en  0/1
//     G<n>   cfg_gauss_en   0/1
//     I<n>   cfg_isol_en    0/1
//     D<n>   cfg_disp_mode  0..3
//     C<n>   cfg_ov_color   0/1
//     S<n>   cfg_shp_en     0/1  (创意拓展⑥ 形状识别总开关: 0 = 不画框不画字)
//     Y<n>   cfg_shp_min    bbox 最小边长 px        8..255  (参考 24)
//     Z<n>   cfg_shp_fill   圆/矩形 填充率分界      800..990 (参考 875)
//                            (千分比; 圆/空心圆环实测 ≈785, 方形框 ≈1000)
//     W<n>   cfg_shp_nbox   同时显示的框数上限      1..6  (参考 4)
//     A<n>   cfg_shp_area   最大 bbox 面积(占全屏%) 5..100 (参考 50)
//     R      every parameter back to its power-on default
//     X<n>   read camera register group <n> (0..78) back over I2C and show
//            it as the CAM field of the status line.  <n> indexes this
//            build's register table (piv2_720p_7M_2L_reg.mem): group g
//            occupies bytes 3g..3g+2 = [addr_hi, addr_lo, value], so the
//            read re-issues those two address bytes and clocks out the one
//            data byte.  Examples: X77 -> AGAIN (0x0157), X75 -> exposure
//            high (0x015A), X71 -> frame length high (0x0160).
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
    parameter [3:0]  EPS_INIT    = 4'd0,
    parameter [1:0]  EPF_INIT    = 2'd2,
    parameter [10:0] GFEPS_INIT  = 11'd400,
    parameter [1:0]  BRG_INIT    = 2'd2,
    parameter        MEDIAN_INIT = 1'b1,
    parameter        GAUSS_INIT  = 1'b0,
    parameter        ISOL_INIT   = 1'b1,
    parameter [1:0]  DISP_INIT   = 2'd0,
    parameter        OVC_INIT    = 1'b1,
    parameter        SHP_INIT    = 1'b1,
    parameter [7:0]  SHP_MIN_INIT= 8'd24,
    parameter [9:0]  SHP_FIL_INIT= 10'd875,
    parameter [2:0]  SHP_NBX_INIT= 3'd4,
    parameter [6:0]  SHP_ARE_INIT= 7'd50
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  i_data,
    input  wire        i_valid,
    output reg  [1:0]  o_mode,
    output reg  [10:0] o_t,
    output reg  [10:0] o_lo,
    output reg  [10:0] o_hi,
    output reg  [3:0]  o_eps,
    output reg  [1:0]  o_epf,
    output reg  [10:0] o_gf_eps,
    output reg  [1:0]  o_brg,
    output reg         o_median_en,
    output reg         o_gauss_en,
    output reg         o_isol_en,
    output reg  [1:0]  o_disp_mode,
    output reg         o_ov_color,
    output reg         o_shp_en,
    output reg  [7:0]  o_shp_min,
    output reg  [9:0]  o_shp_fill,
    output reg  [2:0]  o_shp_nbox,
    output reg  [6:0]  o_shp_area,
    output reg         o_commit,
    output reg  [9:0]  o_cam_grp,      // last X<grp> value (read-back index)
    output reg         o_cam_rd        // 1-cycle pulse: start one read-back
);

    localparam [4:0] K_NONE = 5'd0,
                     K_MODE = 5'd1,
                     K_T    = 5'd2,
                     K_LO   = 5'd3,
                     K_HI   = 5'd4,
                     K_MED  = 5'd5,
                     K_GAU  = 5'd6,
                     K_ISO  = 5'd7,
                     K_DSP  = 5'd8,
                     K_OVC  = 5'd9,
                     K_RST  = 5'd10,
                     K_CAM  = 5'd11,
                     K_EPS  = 5'd12,
                     K_EPF  = 5'd13,
                     K_GFE  = 5'd14,
                     K_BRG  = 5'd15,
                     K_SHP  = 5'd16,     // 形状识别开关
                     K_SZ   = 5'd17,     // 形状最小边长
                     K_FIL  = 5'd18,     // 填充率分界
                     K_NBX  = 5'd19,     // 框数上限
                     K_ARE  = 5'd20;     // 最大面积百分比

    localparam S_KEY = 1'b0,
               S_VAL = 1'b1;

    // ---------------------------------------------------------------- decode
    // Explicit widths everywhere: an implicit wire here is one bit wide in
    // Efinity and silently destroys the digit value (see the trap recorded in
    // the sibling project's uart docs).
    function [4:0] key_of;
        input [7:0] c;
        begin
            case (c)
                8'h4D, 8'h6D: key_of = K_MODE;   // M m
                8'h54, 8'h74: key_of = K_T;      // T t
                8'h4C, 8'h6C: key_of = K_LO;     // L l
                8'h48, 8'h68: key_of = K_HI;     // H h
                8'h45, 8'h65: key_of = K_EPS;    // E e
                8'h50, 8'h70: key_of = K_EPF;    // P p
                8'h46, 8'h66: key_of = K_GFE;    // F f
                8'h42, 8'h62: key_of = K_BRG;    // B b
                8'h4E, 8'h6E: key_of = K_MED;    // N n
                8'h47, 8'h67: key_of = K_GAU;    // G g
                8'h49, 8'h69: key_of = K_ISO;    // I i
                8'h44, 8'h64: key_of = K_DSP;    // D d
                8'h43, 8'h63: key_of = K_OVC;    // C c
                8'h52, 8'h72: key_of = K_RST;    // R r
                8'h58, 8'h78: key_of = K_CAM;    // X x
                8'h53, 8'h73: key_of = K_SHP;    // S s
                8'h59, 8'h79: key_of = K_SZ;     // Y y
                8'h5A, 8'h7A: key_of = K_FIL;    // Z z
                8'h57, 8'h77: key_of = K_NBX;    // W w
                8'h41, 8'h61: key_of = K_ARE;    // A a
                default:      key_of = K_NONE;
            endcase
        end
    endfunction

    // Saturating accumulate of the digits in the line.  The intermediate has to
    // be wide enough for the *unsaturated* product (4095 * 10 + 9 = 40959), or
    // the comparison against the ceiling never fires and the value silently
    // wraps: a 13 bit intermediate turned "T9999" into 1807 instead of 2047.
    // The ceiling is the 12 bit accumulator limit (4095); every field clamps
    // again to its own width when it is applied.
    function [11:0] acc_next;
        input [11:0] a;
        input [7:0]  d;
        reg   [15:0] t;
        begin
            t = {4'b0, a} * 16'd10 + {8'b0, d};
            acc_next = (t > 16'd4095) ? 12'd4095 : t[11:0];
        end
    endfunction

    wire [4:0] w_key    = key_of(i_data);
    wire       w_is_dig = (i_data >= 8'h30) && (i_data <= 8'h39);
    wire [7:0] w_digit  = i_data - 8'h30;
    wire       w_eol    = (i_data == 8'h0A) || (i_data == 8'h0D);

    // ---------------------------------------------------------------- parser
    reg        state;
    reg [4:0]  key;
    reg [11:0] acc;

    reg        apply_en;
    reg [4:0]  apply_key;
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
            o_eps       <= EPS_INIT;
            o_epf       <= EPF_INIT;
            o_gf_eps    <= GFEPS_INIT;
            o_brg       <= BRG_INIT;
            o_median_en <= MEDIAN_INIT;
            o_gauss_en  <= GAUSS_INIT;
            o_isol_en   <= ISOL_INIT;
            o_disp_mode <= DISP_INIT;
            o_ov_color  <= OVC_INIT;
            o_shp_en    <= SHP_INIT;
            o_shp_min   <= SHP_MIN_INIT;
            o_shp_fill  <= SHP_FIL_INIT;
            o_shp_nbox  <= SHP_NBX_INIT;
            o_shp_area  <= SHP_ARE_INIT;
            o_commit    <= 1'b0;
            o_cam_grp   <= 10'd0;
            o_cam_rd    <= 1'b0;
        end else begin
            o_commit <= apply_en;
            o_cam_rd <= 1'b0;      // X reads are one-clock request pulses
            if (apply_en) begin
                case (apply_key)
                    K_MODE: o_mode      <= (apply_val > 12'd2)    ? 2'd2    : apply_val[1:0];
                    K_T:    o_t         <= (apply_val > 12'd2047) ? 11'd2047 : apply_val[10:0];
                    K_LO:   o_lo        <= (apply_val > 12'd2047) ? 11'd2047 : apply_val[10:0];
                    K_HI:   o_hi        <= (apply_val > 12'd2047) ? 11'd2047 : apply_val[10:0];
                    // NMS 容差: 4bit 寄存器, 超过 8 直接夹到 8 (再大只会把线糊粗)
                    K_EPS:  o_eps       <= (apply_val > 12'd8)    ? 4'd8    : apply_val[3:0];
                    // EPF 档位: 0 关 / 1 高斯3x3 / 2 导向滤波, 超过 2 夹到 2
                    K_EPF:  o_epf       <= (apply_val > 12'd2)    ? 2'd2    : apply_val[1:0];
                    // 导向滤波 eps: 11bit 寄存器, 超过 2047 夹到 2047 (参考值 400)
                    K_GFE:  o_gf_eps    <= (apply_val > 12'd2047) ? 11'd2047 : apply_val[10:0];
                    // 断线桥接档位: 2bit 寄存器, 超过 3 夹到 3
                    K_BRG:  o_brg       <= (apply_val > 12'd3)    ? 2'd3    : apply_val[1:0];
                    K_MED:  o_median_en <= (apply_val != 12'd0);
                    K_GAU:  o_gauss_en  <= (apply_val != 12'd0);
                    K_ISO:  o_isol_en   <= (apply_val != 12'd0);
                    K_DSP:  o_disp_mode <= (apply_val > 12'd3)    ? 2'd3    : apply_val[1:0];
                    K_OVC:  o_ov_color  <= (apply_val != 12'd0);
                    // 形状识别: 开关 + 4 个判据(全部有内部限幅, 这里再夹一次)
                    K_SHP:  o_shp_en    <= (apply_val != 12'd0);
                    K_SZ:   o_shp_min   <= (apply_val < 12'd8)    ? 8'd8    :
                                           ((apply_val > 12'd255) ? 8'd255 : apply_val[7:0]);
                    K_FIL:  o_shp_fill  <= (apply_val < 12'd800)  ? 10'd800 :
                                           ((apply_val > 12'd990) ? 10'd990 : apply_val[9:0]);
                    K_NBX:  o_shp_nbox  <= (apply_val < 12'd1)    ? 3'd1    :
                                           ((apply_val > 12'd6)   ? 3'd6    : apply_val[2:0]);
                    K_ARE:  o_shp_area  <= (apply_val < 12'd5)    ? 7'd5    :
                                           ((apply_val > 12'd100) ? 7'd100  : apply_val[6:0]);
                    K_RST: begin
                        o_mode      <= MODE_INIT;
                        o_t         <= T_INIT;
                        o_lo        <= LO_INIT;
                        o_hi        <= HI_INIT;
                        o_eps       <= EPS_INIT;
                        o_epf       <= EPF_INIT;
                        o_gf_eps    <= GFEPS_INIT;
                        o_brg       <= BRG_INIT;
                        o_median_en <= MEDIAN_INIT;
                        o_gauss_en  <= GAUSS_INIT;
                        o_isol_en   <= ISOL_INIT;
                        o_disp_mode <= DISP_INIT;
                        o_ov_color  <= OVC_INIT;
                        o_shp_en    <= SHP_INIT;
                        o_shp_min   <= SHP_MIN_INIT;
                        o_shp_fill  <= SHP_FIL_INIT;
                        o_shp_nbox  <= SHP_NBX_INIT;
                        o_shp_area  <= SHP_ARE_INIT;
                    end
                    // Index into the register table this build actually programs:
                    // MEM_DEPTH=237 bytes / 3 = groups 0..78.  Above that the
                    // re-issued address bytes are all zero, so clamp instead.
                    K_CAM: begin
                        o_cam_grp <= (apply_val > 12'd78) ? 10'd78 : apply_val[9:0];
                        o_cam_rd  <= 1'b1;
                    end
                    default: ;   // K_NONE can only appear if a line was empty
                endcase
            end
        end
    end

endmodule

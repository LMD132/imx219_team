///////////////////////////////////////////////////////////////////////////////
// image_processing_top.v — 赛题四 实时边缘检测图像处理系统(顶层组装)
// 对应 Python: run_pipeline() / canny() + split_view()。
//
// 固定流水线(模块全部运行, 统一延迟 D_TOT = 7*HACT+7 拍):
//   RGB -> gray -> median -> gauss -> sobel -> nms -> hysteresis -> isolated -> 分屏
//   algo      : 0 = Sobel 保底(单阈值 thr / mode_dual 双阈值)
//               1 = Canny 加分(5x5 高斯 + NMS + 双阈值滞后)
//   median_en : 启用 3x3 中值
//   isol_en   : 启用孤立点消除
//   color_mode: 0=白边, 1=红边(右半面板)
//   split_en  : 1=左灰度/右边缘, 0=全屏边缘叠加灰度
//   box_en    : 画面中心固定红框(左右面板都画)
//
// 未实现(见集成文档): temporal_blend(需 DDR 上一帧)、detect_shapes/otsu(软件函数)、
//                      GRAY/EDGE 文字标签(需字库 ROM)。
// 接口: 24bit RGB 像素流 + de/hs/vs(与 imx219_hdmi_720p 工程 hdmi_tx_* 同协议)。
///////////////////////////////////////////////////////////////////////////////
module image_processing_top #(
    parameter HACT = 1280,   // 行有效像素(行缓存深度)
    parameter VACT = 720     // 帧有效行数
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             i_de,
    input  wire             i_hs,
    input  wire             i_vs,
    input  wire [7:0]       i_r,
    input  wire [7:0]       i_g,
    input  wire [7:0]       i_b,
    // 参数寄存器(外部按键/UART/VIO 驱动)
    input  wire [7:0]       thr,
    input  wire [7:0]       thr_hi,
    input  wire [7:0]       thr_lo,
    input  wire             mode_dual,
    input  wire             algo,
    input  wire             median_en,
    input  wire             isol_en,
    input  wire             color_mode,
    input  wire             split_en,
    input  wire             box_en,
    output reg              o_de,
    output reg              o_hs,
    output reg              o_vs,
    output reg  [7:0]       o_r,
    output reg  [7:0]       o_g,
    output reg  [7:0]       o_b
);
    // ---- 各级相对输入的延迟(拍) ----
    localparam D_M   = HACT + 1;        // median
    localparam D_G   = 3*HACT + 3;      // gauss
    localparam D_S   = 4*HACT + 4;      // sobel
    localparam D_N   = 5*HACT + 5;      // nms
    localparam D_H   = 6*HACT + 6;      // hysteresis
    localparam D_TOT = 7*HACT + 7;      // isolated(总)

    // =====================================================================
    // 1. RGB -> gray: (77R+150G+29B)>>8
    // =====================================================================
    wire [15:0] ysum = 77*i_r + 150*i_g + 29*i_b;
    wire [7:0]  gray = ysum[15:8];

    // =====================================================================
    // 2. median (输出 D_M)
    // =====================================================================
    wire [7:0] med;
    wire       med_de, med_hs, med_vs;
    median3x3 #(.W(8), .DEPTH(HACT)) u_med (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_hs(i_hs), .i_vs(i_vs), .i_pix(gray),
        .o_de(med_de), .o_hs(med_hs), .o_vs(med_vs), .o_pix(med));

    // gray 对齐各级
    wire [7:0] gray_dm, gray_dg, gray_dtot;
    delay_n #(.N(D_M), .W(8))   u_gm  (.clk(clk), .din(gray), .dout(gray_dm));
    delay_n #(.N(D_G), .W(8))   u_gg  (.clk(clk), .din(gray), .dout(gray_dg));
    delay_n #(.N(D_TOT), .W(8)) u_gt  (.clk(clk), .din(gray), .dout(gray_dtot));
    // med 对齐 gauss 输出(D_G)
    wire [7:0] med_align_g;
    delay_n #(.N(2*HACT+2), .W(8)) u_mag (.clk(clk), .din(med), .dout(med_align_g));

    // =====================================================================
    // 3. gauss 5x5 (输入 D_M, 输出 D_G)
    // =====================================================================
    wire [7:0] gauss_in = median_en ? med : gray_dm;
    wire [7:0] gauss;
    wire       gauss_de, gauss_hs, gauss_vs;
    gaussian5x5 #(.W(8), .DEPTH(HACT)) u_gauss (
        .clk(clk), .rst_n(rst_n),
        .i_de(med_de), .i_hs(med_hs), .i_vs(med_vs), .i_pix(gauss_in),
        .o_de(gauss_de), .o_hs(gauss_hs), .o_vs(gauss_vs), .o_pix(gauss));

    // =====================================================================
    // 4. sobel (输入 D_G, 输出 D_S): mag12 + dir
    // =====================================================================
    wire [7:0] sobel_in = algo ? gauss : (median_en ? med_align_g : gray_dg);
    wire [11:0] mag12;
    wire [1:0]  dir;
    wire        sobel_de, sobel_hs, sobel_vs;
    sobel3x3 #(.W(8), .DEPTH(HACT)) u_sob (
        .clk(clk), .rst_n(rst_n),
        .i_de(gauss_de), .i_hs(gauss_hs), .i_vs(gauss_vs), .i_pix(sobel_in),
        .o_de(sobel_de), .o_hs(sobel_hs), .o_vs(sobel_vs),
        .o_mag(mag12), .o_dir(dir));

    wire [7:0] mag8   = (mag12 > 8'd255) ? 8'hFF : mag12[7:0];
    wire [7:0] single = (mag8 >= thr) ? 8'hFF : 8'd0;
    // mag8 对齐 nms 输出(D_N)
    wire [7:0] mag8_align_n;
    delay_n #(.N(HACT+1), .W(8)) u_m8n (.clk(clk), .din(mag8), .dout(mag8_align_n));
    // single 对齐 D_TOT
    wire [7:0] single_dtot;
    delay_n #(.N(3*HACT+3), .W(8)) u_s14 (.clk(clk), .din(single), .dout(single_dtot));

    // =====================================================================
    // 5. NMS (输入 D_S, 输出 D_N)
    // =====================================================================
    wire [7:0] nms;
    wire       nms_de, nms_hs, nms_vs;
    canny_nms #(.MW(12), .DEPTH(HACT)) u_nms (
        .clk(clk), .rst_n(rst_n),
        .i_de(sobel_de), .i_hs(sobel_hs), .i_vs(sobel_vs),
        .i_mag(mag12), .i_dir(dir),
        .o_de(nms_de), .o_hs(nms_hs), .o_vs(nms_vs), .o_mag(nms));

    // =====================================================================
    // 6. hysteresis (输入 D_N, 输出 D_H)
    // =====================================================================
    wire [7:0] hys_in = algo ? nms : mag8_align_n;
    wire [7:0] edge_hys;
    wire       hys_de, hys_hs, hys_vs;
    hysteresis #(.DEPTH(HACT)) u_hys (
        .clk(clk), .rst_n(rst_n),
        .i_de(nms_de), .i_hs(nms_hs), .i_vs(nms_vs),
        .i_mag(hys_in), .t_lo(thr_lo), .t_hi(thr_hi),
        .o_de(hys_de), .o_hs(hys_hs), .o_vs(hys_vs), .o_edge(edge_hys));

    // edge_hys 对齐 D_TOT
    wire [7:0] edge_hys_dtot;
    delay_n #(.N(HACT+1), .W(8)) u_ht (.clk(clk), .din(edge_hys), .dout(edge_hys_dtot));

    // =====================================================================
    // 7. remove_isolated (输入 D_H, 输出 D_TOT)
    // =====================================================================
    wire [7:0] edge_isol;
    wire       isol_de, isol_hs, isol_vs;
    remove_isolated #(.DEPTH(HACT), .MIN_NEIGH(1)) u_isol (
        .clk(clk), .rst_n(rst_n),
        .i_de(hys_de), .i_hs(hys_hs), .i_vs(hys_vs), .i_edge(edge_hys),
        .o_de(isol_de), .o_hs(isol_hs), .o_vs(isol_vs), .o_edge(edge_isol));

    // =====================================================================
    // 8. 最终 edge 选择
    // =====================================================================
    wire [7:0] edge_dual  = isol_en ? edge_isol : edge_hys_dtot;
    wire [7:0] edge_final = algo ? edge_dual :
                            (mode_dual ? edge_dual : single_dtot);

    // =====================================================================
    // 9. 行列计数(打拍 D_TOT, 用于分屏/红框)
    // =====================================================================
    reg [15:0] hcnt, vcnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            hcnt <= 16'd0; vcnt <= 16'd0;
        end else if (i_vs) begin
            hcnt <= 16'd0; vcnt <= 16'd0;
        end else if (i_hs) begin
            hcnt <= 16'd0;
            vcnt <= vcnt + 1'b1;
        end else if (i_de) begin
            hcnt <= hcnt + 1'b1;
        end
    end
    wire [15:0] hc, vc;
    delay_n #(.N(D_TOT), .W(16)) u_hc (.clk(clk), .din(hcnt), .dout(hc));
    delay_n #(.N(D_TOT), .W(16)) u_vc (.clk(clk), .din(vcnt), .dout(vc));

    wire de_d, hs_d, vs_d;
    delay_n #(.N(D_TOT), .W(1)) u_de (.clk(clk), .din(i_de), .dout(de_d));
    delay_n #(.N(D_TOT), .W(1)) u_dh (.clk(clk), .din(i_hs), .dout(hs_d));
    delay_n #(.N(D_TOT), .W(1)) u_dv (.clk(clk), .din(i_vs), .dout(vs_d));

    // =====================================================================
    // 10. 分屏 + 黄色分隔线 + 中心红框
    // =====================================================================
    wire is_left  = split_en && (hc < (HACT/2 - 1));
    wire is_sep   = split_en && (hc == (HACT/2 - 1) || hc == (HACT/2));
    wire is_right = split_en && (hc > HACT/2);

    localparam HALF = (VACT < HACT) ? (VACT/4) : (HACT/4);
    wire [15:0] cx = HACT/2;
    wire [15:0] cy = VACT/2;
    wire box_h_range = (hc >= cx - HALF) && (hc <= cx + HALF);
    wire box_v_range = (vc >= cy - HALF) && (vc <= cy + HALF);
    wire box_h_line  = (hc == cx - HALF || hc == cx + HALF) && box_v_range;
    wire box_v_line  = (vc == cy - HALF || vc == cy + HALF) && box_h_range;
    wire box_pixel   = box_en && (box_h_line || box_v_line);

    wire is_edge = (edge_final != 8'd0);
    // 右面板: 白边 或 红边(黑底)
    wire [7:0] right_r = color_mode ? (is_edge ? 8'hFF : 8'd0) : edge_final;
    wire [7:0] right_g = color_mode ? 8'd0 : edge_final;
    wire [7:0] right_b = color_mode ? 8'd0 : edge_final;
    // 全屏模式: 边缘(白/红)叠加灰度
    wire [7:0] full_r = is_edge ? (color_mode ? 8'hFF : 8'hFF) : gray_dtot;
    wire [7:0] full_g = is_edge ? (color_mode ? 8'd0  : 8'hFF) : gray_dtot;
    wire [7:0] full_b = is_edge ? (color_mode ? 8'h0  : 8'hFF) : gray_dtot;

    wire [7:0] r_pix = box_pixel ? 8'hFF :
                       is_sep    ? 8'hFF :
                       is_left   ? gray_dtot :
                       is_right  ? right_r :
                       split_en  ? edge_final : full_r;
    wire [7:0] g_pix = box_pixel ? 8'd0 :
                       is_sep    ? 8'hFF :
                       is_left   ? gray_dtot :
                       is_right  ? right_g :
                       split_en  ? edge_final : full_g;
    wire [7:0] b_pix = box_pixel ? 8'd0 :
                       is_sep    ? 8'd0 :
                       is_left   ? gray_dtot :
                       is_right  ? right_b :
                       split_en  ? edge_final : full_b;

    always @(posedge clk) begin
        if (!rst_n) begin
            o_de <= 1'b0; o_hs <= 1'b0; o_vs <= 1'b0;
            o_r <= 8'd0; o_g <= 8'd0; o_b <= 8'd0;
        end else begin
            o_de <= de_d; o_hs <= hs_d; o_vs <= vs_d;
            o_r <= r_pix; o_g <= g_pix; o_b <= b_pix;
        end
    end
endmodule

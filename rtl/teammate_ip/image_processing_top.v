///////////////////////////////////////////////////////////////////////////////
// image_processing_top.v — 赛题四 实时边缘检测图像处理系统(顶层组装)
// 对应 Python: run_pipeline() / canny() + split_view()。
//
// 固定流水线(模块全部运行, 统一延迟 D_TOT = 7*HACT+7 拍):
//   RGB -> gray -> median -> gauss -> sobel -> nms -> hysteresis -> isolated -> 分屏
//
// 【资源修正版】所有"行级延迟"一律用 line_delay_n(BRAM 行缓存), 不再用 delay_n 移位链;
//   de/hs/vs 合并为 3bit 一条 BRAM 链; 行列计数 hc/vc 在输出级用延迟后同步实时计数
//   (天然对齐, 零延迟)。delay_n 仅在 line_delay_n 内部承担几拍零头。
//
//   algo      : 0=Sobel(单阈值 thr / mode_dual 双阈值), 1=Canny
//   median_en : 3x3 中值; isol_en : 孤立点消除
//   color_mode: 0=白边, 1=红边; split_en: 1=分屏, 0=全屏叠加; box_en: 中心红框
///////////////////////////////////////////////////////////////////////////////
module image_processing_top #(
    parameter HACT = 1280,
    parameter VACT = 720
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             i_de,
    input  wire             i_hs,
    input  wire             i_vs,
    input  wire [7:0]       i_r,
    input  wire [7:0]       i_g,
    input  wire [7:0]       i_b,
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
    localparam D_M   = HACT + 1;
    localparam D_G   = 3*HACT + 3;
    localparam D_S   = 4*HACT + 4;
    localparam D_N   = 5*HACT + 5;
    localparam D_H   = 6*HACT + 6;
    localparam D_TOT = 7*HACT + 7;

    // =====================================================================
    // 1. RGB -> gray
    // =====================================================================
    wire [15:0] ysum = 77*i_r + 150*i_g + 29*i_b;
    wire [7:0]  gray = ysum[15:8];

    // =====================================================================
    // 2. median (D_M)
    // =====================================================================
    wire [7:0] med;
    wire       med_de, med_hs, med_vs;
    median3x3 #(.W(8), .DEPTH(HACT)) u_med (
        .clk(clk), .rst_n(rst_n),
        .i_de(i_de), .i_hs(i_hs), .i_vs(i_vs), .i_pix(gray),
        .o_de(med_de), .o_hs(med_hs), .o_vs(med_vs), .o_pix(med));

    // gray 对齐各级(BRAM 行延迟, we=i_de)
    wire [7:0] gray_dm, gray_dg, gray_dtot;
    line_delay_n #(.WIDTH(8), .DEPTH(HACT), .N(D_M))   u_gm
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(gray), .dout(gray_dm));
    line_delay_n #(.WIDTH(8), .DEPTH(HACT), .N(D_G))   u_gg
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(gray), .dout(gray_dg));
    line_delay_n #(.WIDTH(8), .DEPTH(HACT), .N(D_TOT)) u_gt
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(gray), .dout(gray_dtot));
    // med 对齐 gauss 输出(D_G), we=med_de
    wire [7:0] med_align_g;
    line_delay_n #(.WIDTH(8), .DEPTH(HACT), .N(2*HACT+2)) u_mag
        (.clk(clk), .rst_n(rst_n), .we(med_de), .din(med), .dout(med_align_g));

    // =====================================================================
    // 3. gauss (D_G)
    // =====================================================================
    wire [7:0] gauss_in = median_en ? med : gray_dm;
    wire [7:0] gauss;
    wire       gauss_de, gauss_hs, gauss_vs;
    gaussian5x5 #(.W(8), .DEPTH(HACT)) u_gauss (
        .clk(clk), .rst_n(rst_n),
        .i_de(med_de), .i_hs(med_hs), .i_vs(med_vs), .i_pix(gauss_in),
        .o_de(gauss_de), .o_hs(gauss_hs), .o_vs(gauss_vs), .o_pix(gauss));

    // =====================================================================
    // 4. sobel (D_S)
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
    // mag8 对齐 nms(D_N), single 对齐 D_TOT; we=sobel_de
    wire [7:0] mag8_align_n, single_dtot;
    line_delay_n #(.WIDTH(8), .DEPTH(HACT), .N(HACT+1))   u_m8n
        (.clk(clk), .rst_n(rst_n), .we(sobel_de), .din(mag8),   .dout(mag8_align_n));
    line_delay_n #(.WIDTH(8), .DEPTH(HACT), .N(3*HACT+3)) u_s14
        (.clk(clk), .rst_n(rst_n), .we(sobel_de), .din(single), .dout(single_dtot));

    // =====================================================================
    // 5. NMS (D_N)
    // =====================================================================
    wire [7:0] nms;
    wire       nms_de, nms_hs, nms_vs;
    canny_nms #(.MW(12), .DEPTH(HACT)) u_nms (
        .clk(clk), .rst_n(rst_n),
        .i_de(sobel_de), .i_hs(sobel_hs), .i_vs(sobel_vs),
        .i_mag(mag12), .i_dir(dir),
        .o_de(nms_de), .o_hs(nms_hs), .o_vs(nms_vs), .o_mag(nms));

    // =====================================================================
    // 6. hysteresis (D_H)
    // =====================================================================
    wire [7:0] hys_in = algo ? nms : mag8_align_n;
    wire [7:0] edge_hys;
    wire       hys_de, hys_hs, hys_vs;
    hysteresis #(.DEPTH(HACT)) u_hys (
        .clk(clk), .rst_n(rst_n),
        .i_de(nms_de), .i_hs(nms_hs), .i_vs(nms_vs),
        .i_mag(hys_in), .t_lo(thr_lo), .t_hi(thr_hi),
        .o_de(hys_de), .o_hs(hys_hs), .o_vs(hys_vs), .o_edge(edge_hys));

    // edge_hys 对齐 D_TOT; we=hys_de
    wire [7:0] edge_hys_dtot;
    line_delay_n #(.WIDTH(8), .DEPTH(HACT), .N(HACT+1)) u_ht
        (.clk(clk), .rst_n(rst_n), .we(hys_de), .din(edge_hys), .dout(edge_hys_dtot));

    // =====================================================================
    // 7. remove_isolated (D_TOT)
    // =====================================================================
    wire [7:0] edge_isol;
    wire       isol_de, isol_hs, isol_vs;
    remove_isolated #(.DEPTH(HACT), .MIN_NEIGH(1)) u_isol (
        .clk(clk), .rst_n(rst_n),
        .i_de(hys_de), .i_hs(hys_hs), .i_vs(hys_vs), .i_edge(edge_hys),
        .o_de(isol_de), .o_hs(isol_hs), .o_vs(isol_vs), .o_edge(edge_isol));

    // =====================================================================
    // 8. edge 选择
    // =====================================================================
    wire [7:0] edge_dual  = isol_en ? edge_isol : edge_hys_dtot;
    wire [7:0] edge_final = algo ? edge_dual :
                            (mode_dual ? edge_dual : single_dtot);

    // =====================================================================
    // 9. 同步 de/hs/vs 合并为 3bit, 一条 BRAM 链延迟到 D_TOT
    // =====================================================================
    wire [2:0] sync_d;
    line_delay_n #(.WIDTH(3), .DEPTH(HACT), .N(D_TOT)) u_sync
        (.clk(clk), .rst_n(rst_n), .we(i_de),
         .din({i_de, i_hs, i_vs}), .dout(sync_d));
    wire fde = sync_d[2];
    wire fhs = sync_d[1];
    wire fvs = sync_d[0];

    // =====================================================================
    // 10. 输出级实时计数(用延迟后同步, 与像素天然对齐, 无需移位链)
    // =====================================================================
    reg [15:0] hc, vc;
    always @(posedge clk) begin
        if (!rst_n) begin
            hc <= 16'd0; vc <= 16'd0;
        end else if (fvs) begin
            hc <= 16'd0; vc <= 16'd0;
        end else if (fhs) begin
            hc <= 16'd0; vc <= vc + 1'b1;
        end else if (fde) begin
            hc <= hc + 1'b1;
        end
    end

    // =====================================================================
    // 11. 分屏 + 黄色分隔线 + 中心红框
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
    wire [7:0] right_r = color_mode ? (is_edge ? 8'hFF : 8'd0) : edge_final;
    wire [7:0] right_g = color_mode ? 8'd0 : edge_final;
    wire [7:0] right_b = color_mode ? 8'd0 : edge_final;
    wire [7:0] full_r = is_edge ? 8'hFF : gray_dtot;
    wire [7:0] full_g = is_edge ? (color_mode ? 8'd0 : 8'hFF) : gray_dtot;
    wire [7:0] full_b = is_edge ? (color_mode ? 8'd0 : 8'hFF) : gray_dtot;

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
            o_de <= fde; o_hs <= fhs; o_vs <= fvs;
            o_r <= r_pix; o_g <= g_pix; o_b <= b_pix;
        end
    end
endmodule

//=============================================================================
// alg_top.v -- 赛题4 实时边缘检测流水线顶层
//   (灰度 -> 中值3x3 -> 高斯5x5 -> Sobel3x3 -> NMS -> 阈值/滞后 -> 桥接 -> 去孤点 -> 显示)
//
//  算法全部来自 GitHub 仓库 liuziyaoyao1210-sudo/FPGA-Python (edge_pipeline.py),
//  按 rtl_model.py 的定点/截位逐位改写为 Verilog, 与 Python 金标准逐位对拍。
//
//  数据流(全部 1 pixel/clk, 无除法器/无开方/无乘法器):
//    相机RGB --> alg_gray((77R+150G+29B)>>8) --> 扩展光栅流(每行 W+VEXT, 帧尾 REXT 行)
//        |                                             |
//        |                                             +--> alg_median3 (延迟 4)   高阶①
//        |                                             +--> alg_gauss5  (延迟 5, CANNY 档)  高阶④
//        |                                             +--> alg_sobel3  (延迟 4, mag 全量程 11bit)  基础③
//        |                                             +--> alg_nms     (延迟 4, CANNY 档)  高阶④
//        |                                             +--> alg_thresh  (延迟 4)  基础③ / 高阶④
//        |                                             +--> alg_ebridge (延迟 4)  断线桥接(7x7, 高阶④)
//        |                                             +--> alg_despeckle (延迟 4)  高阶④
//        |                                                    |
//        |     (彩色原图 + 显示屏时序, 不经算法链)               v
//        +---------------------------------------------> alg_vdisp  --> HDMI 输出
//                                                    (行缓存对齐 + 4 种显示模式)
//
//  === 显示对齐(本文件最容易写错的地方, 已逐拍仿真验证) ===
//  主链每级窗口模块把"窗口中心"的标签减去 H2, 且 de 从前端被切掉 H2 拍。8 级窗口
//    H2 合计 = 1(中值)+4(导向滤波: 两级 6x6)+2(高斯)+1(Sobel)+1(NMS)+1(阈值膨胀)
//              +3(边缘桥接 7x7)+1(去孤点) = 14
//  所以 dsp 级在时钟 t 输出的"边缘值"对应的源像素 = 顶层输入在 t-L 时刻的像素,
//  而它的 (x,y) 标签 = 源坐标 - 11 (标签是"源像素坐标", 不是屏幕坐标)。
//  因此 dsp 标签不能直接当屏幕坐标用: 边缘值出现时, 彩色光栅已经跑到 (x+11, y+11),
//  直接叠加会让边缘整体右下移 11 行 11 列(实测 306 显示像素里错 80 个)。
//  正确做法是交给 alg_vdisp 用行缓存重建对齐: 彩色行缓存按"显示坐标"读写、边缘行
//  缓存按"dsp 标签"写, 两者各自归位 -> 逐像素严格对齐(实测 0 mismatch)。
//  L = 1(灰度) + 4(中值) + 25(导向滤波, 三档都跑同一套流水, 旁路也保持 25 拍)
//    + 5(高斯, 旁路也保持 5 拍) + 4(Sobel) + 4(NMS) + 4(阈值) + 4(桥接) + 4(去孤点)
//    = 55  (见 docs/ALGO_RTL.md 的延迟表, 由 check_chain.py 实测复核)
//  图像最外 14 行/列是流式固有边界: 窗口需要未来行/列, 该处 de=0, 边缘显示为 0。
//
//  运行期可配: MODE / 阈值 / NMS 容差 eps / 前置滤波 EPF(0 关 1 高斯 2 导向) /
//              导向滤波 eps / 断线桥接 BRG(0 关 1~3 档) / 中值开关 / 去孤点开关 /
//              显示模式 / 叠加底色
//=============================================================================

module alg_top #(
    parameter integer W        = 1280,
    parameter integer VEXT     = 16,
    parameter integer H        = 720,
    parameter integer REXT     = 8,
    parameter integer HTOTAL   = 1650,          // 输入光栅行周期(clk 数, 含消隐)
    parameter integer HALF     = 640,           // W/2
    parameter integer ROWD     = 14             // 算法各级 H2 累计(垂直/水平提前量)
)(
    input  wire        clk,
    input  wire        rst_n,

    // 相机/显示光栅(1 pixel/clk, 带 h/v 消隐)
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,
    input  wire [7:0]  in_r,
    input  wire [7:0]  in_g,
    input  wire [7:0]  in_b,

    // 运行期配置(按键/寄存器; 不接则用顶层寄存器里的定稿值)
    input  wire [1:0]  cfg_mode,        // 0=SOBEL单阈值 1=SOBEL双阈值 2=CANNY
    input  wire [10:0] cfg_t,
    input  wire [10:0] cfg_lo,
    input  wire [10:0] cfg_hi,
    input  wire [3:0]  cfg_eps,         // NMS 容差 0..8 (只 CANNY 档有效, 0 = 参考代码)
    input  wire [1:0]  cfg_epf,         // 前置滤波 0=关 1=3x3高斯 2=导向滤波(参考代码默认档)
    input  wire [10:0] cfg_gf_eps,      // 导向滤波 eps 0..2000 (参考代码 400)
    input  wire [1:0]  cfg_brg,         // 断线桥接档 0..3 (0=关; 只双阈值档生效)
    input  wire        cfg_median_en,
    input  wire        cfg_gauss_en,
    input  wire        cfg_isol_en,
    input  wire [1:0]  cfg_disp_mode,
    input  wire        cfg_ov_color,

    // 形状识别(创意拓展⑥): 开关 + 4 个判据参数(全部由调参台在线改)
    input  wire        cfg_shp_en,        // 0 = 关闭(不画框不画字)
    input  wire [7:0]  cfg_shp_min,       // bbox 最小边长(px)   默认 24
    input  wire [9:0]  cfg_shp_fill,      // 圆/矩形 填充率分界   默认 875
    input  wire [2:0]  cfg_shp_nbox,      // 显示框数上限 1..6    默认 4
    input  wire [6:0]  cfg_shp_area,      // 最大面积(占全屏%)   默认 50

    output wire [9:0]  diag_cnt,
    output wire [15:0] diag_ovf,
    output wire [31:0] diag_slot_drop_total,
    output wire [31:0] diag_fifo_full_total,
    output wire        diag_last_fault,
    output wire [3:0]  diag_last_reason,
    output wire        diag_frame_valid,

    output wire        out_vs,
    output wire        out_hs,
    output wire        out_de,
    output wire [11:0] out_x,
    output wire [12:0] out_y,
    output wire [7:0]  out_r,
    output wire [7:0]  out_g,
    output wire [7:0]  out_b
);

wire gauss_on = (cfg_mode == 2'd2) ? 1'b1 : cfg_gauss_en;

//--------------------------------------------------------------------------
// 1) 灰度化 + 扩展光栅流
//--------------------------------------------------------------------------
wire        g_vs, g_hs, g_de;
wire [11:0] g_x;
wire [12:0] g_y;
wire [7:0]  g_d;

alg_gray #(
    .W(W), .VEXT(VEXT), .H(H), .REXT(REXT), .PAD_EDGE(1)
) u_gray (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_r(in_r), .in_g(in_g), .in_b(in_b),
    .out_vs(g_vs), .out_hs(g_hs), .out_de(g_de),
    .out_x(g_x), .out_y(g_y), .out_data(g_d)
);

//--------------------------------------------------------------------------
// 3) 3x3 中值滤波(高阶①)
//--------------------------------------------------------------------------
wire        med_vs, med_hs, med_de, med_def;
wire [11:0] med_x;
wire [12:0] med_y;
wire [7:0]  med_d;

alg_median3 #(.W(W), .VEXT(VEXT), .H(H)) u_med (
    .clk(clk), .rst_n(rst_n), .en(cfg_median_en),
    .in_vs(g_vs), .in_hs(g_hs), .in_de(g_de),
    .in_x(g_x), .in_y(g_y), .in_data(g_d),
    .out_vs(med_vs), .out_hs(med_hs), .out_de_full(med_def), .out_de(med_de),
    .out_x(med_x), .out_y(med_y), .out_data(med_d)
);

//--------------------------------------------------------------------------
// 4a) 前置滤波 EPF(live_tune.py 的 EPF 滑条, 插在中值之后):
//       0 = 关(直通)   1 = 3x3 高斯   2 = 导向滤波 guided_filter(radius=6, eps)
//     ★ 三档共用同一套流水, 延迟恒为 25 拍 -> 换档不会让画面跳, ROWD 也不变。
//--------------------------------------------------------------------------
wire        epf_vs, epf_hs, epf_de, epf_def;
wire [11:0] epf_x;
wire [12:0] epf_y;
wire [7:0]  epf_d;

alg_gf #(.W(W), .VEXT(VEXT), .H(H)) u_epf (
    .clk(clk), .rst_n(rst_n),
    .epf(cfg_epf), .gf_eps(cfg_gf_eps),
    .in_vs(med_vs), .in_hs(med_hs), .in_de(med_def),
    .in_x(med_x), .in_y(med_y), .in_data(med_d),
    .out_vs(epf_vs), .out_hs(epf_hs), .out_de_full(epf_def), .out_de(epf_de),
    .out_x(epf_x), .out_y(epf_y), .out_data(epf_d)
);

//--------------------------------------------------------------------------
// 4b) 5x5 整数高斯(Canny 档前置)
//--------------------------------------------------------------------------
wire        gau_vs, gau_hs, gau_de, gau_def;
wire [11:0] gau_x;
wire [12:0] gau_y;
wire [7:0]  gau_d;

alg_gauss5 #(.W(W), .VEXT(VEXT), .H(H)) u_gau (
    .clk(clk), .rst_n(rst_n), .en(gauss_on),
    .in_vs(epf_vs), .in_hs(epf_hs), .in_de(epf_def),
    .in_x(epf_x), .in_y(epf_y), .in_data(epf_d),
    .out_vs(gau_vs), .out_hs(gau_hs), .out_de_full(gau_def), .out_de(gau_de),
    .out_x(gau_x), .out_y(gau_y), .out_data(gau_d)
);

//--------------------------------------------------------------------------
// 5) Sobel 梯度(基础③, mag 全量程 11bit)
//--------------------------------------------------------------------------
wire        sob_vs, sob_hs, sob_de, sob_def;
wire [11:0] sob_x;
wire [12:0] sob_y;
wire [10:0] sob_mag;
wire [1:0]  sob_dir;
wire signed [11:0] sob_gx, sob_gy;

alg_sobel3 #(.W(W), .VEXT(VEXT), .H(H)) u_sob (
    .clk(clk), .rst_n(rst_n),
    .in_vs(gau_vs), .in_hs(gau_hs), .in_de(gau_def),
    .in_x(gau_x), .in_y(gau_y), .in_data(gau_d),
    .out_vs(sob_vs), .out_hs(sob_hs), .out_de_full(sob_def), .out_de(sob_de),
    .out_x(sob_x), .out_y(sob_y),
    .out_mag(sob_mag), .out_dir(sob_dir), .out_gx(sob_gx), .out_gy(sob_gy)
);

//--------------------------------------------------------------------------
// 6) NMS(Canny 档) + 4 拍幅值延迟(给 SOBEL 档用, 保证换档不跳)
//--------------------------------------------------------------------------
wire        nms_vs, nms_hs, nms_de, nms_def;
wire [11:0] nms_x;
wire [12:0] nms_y;
wire [7:0]  nms_d;

alg_nms #(.W(W), .VEXT(VEXT), .H(H)) u_nms (
    .clk(clk), .rst_n(rst_n),
    .in_vs(sob_vs), .in_hs(sob_hs), .in_de(sob_def),
    .in_x(sob_x), .in_y(sob_y), .in_mag(sob_mag), .in_dir(sob_dir),
    .cfg_eps(cfg_eps),
    .out_vs(nms_vs), .out_hs(nms_hs), .out_de_full(nms_def), .out_de(nms_de),
    .out_x(nms_x), .out_y(nms_y), .out_data(nms_d)
);

wire        sob4_vs, sob4_hs, sob4_de;
wire [11:0] sob4_x;
wire [12:0] sob4_y;
wire [10:0] sob4_mag;

alg_stream_delay #(.DW(11), .D(4)) u_magdly (
    .clk(clk), .rst_n(rst_n),
    .in_vs(sob_vs), .in_hs(sob_hs), .in_de(sob_def),
    .in_x(sob_x), .in_y(sob_y), .in_data(sob_mag),
    .out_vs(sob4_vs), .out_hs(sob4_hs), .out_de(sob4_de),
    .out_x(sob4_x), .out_y(sob4_y), .out_data(sob4_mag)
);

// 配置在帧间稳定, 直接组合选择: CANNY -> NMS(8bit); 其余 -> 全量程梯度
wire [1:0]  cfg_mode_d = cfg_mode;
wire [10:0] thr_mag  = (cfg_mode_d == 2'd2) ? {3'b0, nms_d} : sob4_mag;
wire        thr_vs   = (cfg_mode_d == 2'd2) ? nms_vs  : sob4_vs;
wire        thr_hs   = (cfg_mode_d == 2'd2) ? nms_hs  : sob4_hs;
wire        thr_din  = (cfg_mode_d == 2'd2) ? nms_def : sob4_de;
wire [11:0] thr_x    = (cfg_mode_d == 2'd2) ? nms_x   : sob4_x;
wire [12:0] thr_y    = (cfg_mode_d == 2'd2) ? nms_y   : sob4_y;

//--------------------------------------------------------------------------
// 7) 阈值 / 双阈值滞后(基础③ + 高阶④)
//--------------------------------------------------------------------------
wire        thr_vso, thr_hso, thr_de, thr_def;
wire [11:0] thr_xo;
wire [12:0] thr_yo;
wire [7:0]  thr_d;

alg_thresh #(.W(W), .VEXT(VEXT), .H(H)) u_thr (
    .clk(clk), .rst_n(rst_n),
    .in_vs(thr_vs), .in_hs(thr_hs), .in_de(thr_din),
    .in_x(thr_x), .in_y(thr_y), .in_data(thr_mag),
    .cfg_mode(cfg_mode_d), .cfg_t(cfg_t), .cfg_lo(cfg_lo), .cfg_hi(cfg_hi),
    .out_vs(thr_vso), .out_hs(thr_hso), .out_de_full(thr_def), .out_de(thr_de),
    .out_x(thr_xo), .out_y(thr_yo), .out_data(thr_d)
);

//--------------------------------------------------------------------------
// 8a) 边缘断线桥接(高阶④, 在二值边缘图上做 4 轴方向的闭运算)
//     一根直线被打成短段(空洞 1~5px)时把它们补回连续; 只在双阈值档生效。
//     参数 cfg_brg=0 时逐位透传(等价上一版, 便于回退对照)。
//--------------------------------------------------------------------------
wire        brg_vs, brg_hs, brg_de, brg_def;
wire [11:0] brg_x;
wire [12:0] brg_y;
wire [7:0]  brg_d;

alg_ebridge #(.W(W), .VEXT(VEXT), .H(H)) u_brg (
    .clk(clk), .rst_n(rst_n),
    .in_vs(thr_vso), .in_hs(thr_hso), .in_de(thr_def),
    .in_x(thr_xo), .in_y(thr_yo), .in_data(thr_d),
    .cfg_k(cfg_brg), .cfg_mode(cfg_mode_d),
    .out_vs(brg_vs), .out_hs(brg_hs), .out_de_full(brg_def), .out_de(brg_de),
    .out_x(brg_x), .out_y(brg_y), .out_data(brg_d)
);

//--------------------------------------------------------------------------
// 8) 孤立点消除(高阶④)
//--------------------------------------------------------------------------
wire        dsp_vs, dsp_hs, dsp_de, dsp_def;
wire [11:0] dsp_x;
wire [12:0] dsp_y;
wire [7:0]  dsp_d;

alg_despeckle #(.W(W), .VEXT(VEXT), .H(H)) u_dsp (
    .clk(clk), .rst_n(rst_n), .en(cfg_isol_en),
    .in_vs(brg_vs), .in_hs(brg_hs), .in_de(brg_def),
    .in_x(brg_x), .in_y(brg_y), .in_data(brg_d),
    .out_vs(dsp_vs), .out_hs(dsp_hs), .out_de_full(dsp_def), .out_de(dsp_de),
    .out_x(dsp_x), .out_y(dsp_y), .out_data(dsp_d)
);

//--------------------------------------------------------------------------
// 8b) 形状识别(创意拓展⑥): 在 dsp 边缘流上做游程连通域 + 几何特征分类
//     输出最多 6 个框(bbox + 类别)给 alg_vdisp 画出来; 只读旁路, 不占 BRAM。
//     参数 cfg_shp_en=0 时内部清表、输出全 0 -> 与上一版逐位一致(可回退对照)。
//--------------------------------------------------------------------------
wire [6*12-1:0] shp_bx0, shp_bx1;
wire [6*13-1:0] shp_by0, shp_by1;
wire [6*3-1:0]  shp_bcls;
wire [5:0]      shp_bval;
wire [9:0]      shp_cnt;
wire [15:0]     shp_ovf;
wire [31:0]     shp_slot_drop_total, shp_fifo_full_total;
wire            shp_last_fault, shp_frame_valid;
wire [3:0]      shp_last_reason;

assign diag_cnt = shp_cnt;
assign diag_ovf = shp_ovf;
assign diag_slot_drop_total = shp_slot_drop_total;
assign diag_fifo_full_total = shp_fifo_full_total;
assign diag_last_fault = shp_last_fault;
assign diag_last_reason = shp_last_reason;
assign diag_frame_valid = shp_frame_valid;

shp_detect #(.W(W), .H(H), .NB(8), .NBX(6)) u_shp (
    .clk(clk), .rst_n(rst_n),
    .cfg_en(cfg_shp_en), .cfg_min_size(cfg_shp_min),
    .cfg_max_boxes(cfg_shp_nbox), .cfg_fill_th(cfg_shp_fill),
    .cfg_max_area(cfg_shp_area),
    .in_vs(dsp_vs), .in_de(dsp_def),
    .in_x(dsp_x), .in_y(dsp_y), .in_d(dsp_d),
    .o_bx0(shp_bx0), .o_bx1(shp_bx1),
    .o_by0(shp_by0), .o_by1(shp_by1),
    .o_bcls(shp_bcls), .o_bval(shp_bval),
    .o_cnt(shp_cnt), .o_ovf(shp_ovf),
    .o_slot_drop_total(shp_slot_drop_total),
    .o_fifo_full_total(shp_fifo_full_total),
    .o_last_fault(shp_last_fault), .o_last_reason(shp_last_reason),
    .o_frame_valid(shp_frame_valid)
);

//--------------------------------------------------------------------------
// 9) 显示合成与对齐(alg_vdisp)
//    alg_vdisp 内部: 显示光栅 = 输入光栅整体延迟 TDLY = ROWS*HTOTAL 拍, 彩色
//    行缓存按"显示坐标"读出, 边缘行缓存按 dsp 标签(= 源像素坐标)写入 ->
//    两者在屏幕上逐像素严格对齐(详见 alg_vdisp.v 头注释)。
//--------------------------------------------------------------------------
alg_vdisp #(
    .W(W), .H(H), .HTOTAL(HTOTAL), .ROWD(ROWD), .HALF(HALF)
) u_vdisp (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_rgb({in_r, in_g, in_b}),
    .ed_de(dsp_def), .ed_x(dsp_x), .ed_y(dsp_y), .ed_d(dsp_d),
    .mode(cfg_disp_mode), .ov_color(cfg_ov_color),
    .shp_en(cfg_shp_en),
    .shp_bx0(shp_bx0), .shp_bx1(shp_bx1),
    .shp_by0(shp_by0), .shp_by1(shp_by1),
    .shp_bcls(shp_bcls), .shp_bval(shp_bval),
    .out_vs(out_vs), .out_hs(out_hs), .out_de(out_de),
    .out_x(out_x), .out_y(out_y),
    .out_r(out_r), .out_g(out_g), .out_b(out_b)
);

endmodule

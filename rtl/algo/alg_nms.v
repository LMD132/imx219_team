//=============================================================================
// alg_nms.v -- 赛题4 高阶④ Canny 非极大值抑制(NMS)
//
//  输入: {dir[1:0], mag[10:0]}  (13bit, 来自 alg_sobel3, 全量程 mag)
//  3x3 邻域(EDGE 边界), 按梯度方向取两侧邻居做非对称比较:
//      0  (左右) -> (m > L)  & (m >= R)
//      90 (上下) -> (m > U)  & (m >= D)
//      45 (主对角) -> (m > UL) & (m >= DR)
//      135(副对角) -> (m > UR) & (m >= DL)
//  保留则输出 clip(m,0,255), 否则 0   (与 Python nms_rtl() 一致)
//
//  cfg_eps (运行期可调, 4bit): NMS 容差. eps=0 时逐位等于上面的参考实现;
//      eps>0 时比较变成 (m + eps 与两侧邻居比), 容忍半像素相位处两个候选像素
//      "近等值二选一"的翻转(线条沿轮廓流动抖动的根因). 只在 CANNY 档有效。
//
//  流水线延迟: 输入 -> out_de = 4 拍 (窗口 3 + 寄存 1)
//=============================================================================

//=============================================================================
//  ★ 2026-09-28 增补: 亚像素方向插值 NMS (cfg_inms = 1)
//
//  为什么加这一级(实测/文献依据):
//    上面 4 方向量化只认 0/45/90/135 四根轴。真实梯度方向落在两根轴之间时
//    (例如 20°、67°), "该跟哪一对邻居比"是被强行归到最近轴的 —— 归轴边界
//    (22.5°/67.5°/112.5°/157.5°) 附近, 幅值只要抖 1 个 LSB 就会在两根轴之间
//    跳, 保留像素在相邻行之间来回换位: 肉眼就是"沿轮廓流动的抖动"; 一条斜边
//    还会同时留下 2~3 列并列的保留点("一根线变几根, 中间有缝")。
//    Sobel 档不做 NMS(线宽 2~3px), 同样的抖动被线宽摊开所以看不出来 ——
//    这正是"Canny 比 Sobel 毛躁"的算法级来源。
//
//  做法(与 cv2 的插值 NMS 同构, 但改成免除法形式, 零延时增加):
//    设中心梯度 (gx,gy), 令 a = min(|gx|,|gy|), b = max(|gx|,|gy|)  (b>0)
//    沿梯度方向的两个候选点 = "主轴邻居" 与 "对角邻居" 的线性插值:
//        前向 n_f = ((b-a)*M_f + a*D_f) / b
//        后向 n_b = ((b-a)*M_b + a*D_b) / b
//    保留条件  m > n_f 且 m >= n_b, 两边同乘 b(纯正数) 得
//        keep = (b*m > (b-a)*M_f + a*D_f) && (b*m >= (b-a)*M_b + a*D_b)
//    -> 不需要除法器, 把"比值权重"变成 3 个乘法/侧; a=0 时逐位退化成 4 方向
//       量化版, a=b 时退化成对角比较版, 中间连续过渡 -> 归轴跳变消失。
//    方向选择: |gx|>=|gy| 走水平(左右 + 上/下斜); 否则走垂直(上下 + 左/右斜);
//       斜向哪一侧由 gy(gx) 的符号决定。邻居编号见下面 m0..m8。
//
//  cfg_inms = 0 -> 逐位等于原参考实现(默认, 便于 A/B 对照与回退);
//  cfg_inms = 1 -> 插值版。
//  延迟: 两条路径都是 4 拍(插值是纯组合, 不插流水线) -> ROWD/TDLY 不变。
//  资源: 5 个 12x11 无符号乘法(Efinity 会用 DSP 或 LUT)+ 若干比较器。
//=============================================================================

module alg_nms #(
    parameter integer W    = 1280,
    parameter integer VEXT = 16,
    parameter integer H    = 720
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,
    input  wire [11:0] in_x,
    input  wire [12:0] in_y,
    input  wire [10:0] in_mag,
    input  wire [1:0]  in_dir,
    input  wire signed [11:0] in_gx,   // 中心梯度 Gx (来自 alg_sobel3.out_gx)
    input  wire signed [11:0] in_gy,   // 中心梯度 Gy (来自 alg_sobel3.out_gy)
    input  wire [3:0]  cfg_eps,       // NMS 容差 0..8 (0 = 与参考代码逐位一致)
    input  wire        cfg_inms,      // 1 = 亚像素方向插值 NMS (0 = 参考 4 方向)
    output wire        out_vs,
    output wire        out_hs,
    output wire        out_de_full,
    output wire        out_de,
    output wire [11:0] out_x,
    output wire [12:0] out_y,
    output reg  [7:0]  out_data
);

wire        w_vs, w_hs, w_de;
wire [11:0] w_x;
wire [12:0] w_y;
wire [116:0] win;

alg_win #(
    .DW(13), .W(W), .VEXT(VEXT), .H(H), .N(3), .PAD_EDGE(1)
) u_win (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_x(in_x), .in_y(in_y), .in_data({in_dir, in_mag}),
    .out_vs(w_vs), .out_hs(w_hs), .out_de(w_de),
    .out_x(w_x), .out_y(w_y), .win(win)
);

// win[k*13 +: 13] = {dir, mag}
wire [10:0] m0 = win[10:0];
wire [10:0] m1 = win[23:13];
wire [10:0] m2 = win[36:26];
wire [10:0] m3 = win[49:39];
wire [10:0] m4 = win[62:52];
wire [10:0] m5 = win[75:65];
wire [10:0] m6 = win[88:78];
wire [10:0] m7 = win[101:91];
wire [10:0] m8 = win[114:104];
wire [1:0]  dc = win[64:63];       // 中心方向

//--------------------------------------------------------------------------
// 中心梯度 (gx,gy) 延迟 3 拍 -> 与 3x3 窗口中心 m4 同拍
//   (alg_win N=3 的窗口延迟是 3 拍; sobel 的 out_gx/out_gy 与 out_de_full 同拍)
//   24bit 打包成 {gx, gy} 走一个移位寄存器, 不占 BRAM。
//--------------------------------------------------------------------------
wire signed [23:0] cgxy;
wire               cg_de;
alg_stream_delay #(.DW(24), .D(3)) u_gdly (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_x(in_x), .in_y(in_y), .in_data({in_gx, in_gy}),
    .out_vs(), .out_hs(), .out_de(cg_de),
    .out_x(), .out_y(), .out_data(cgxy)
);
wire signed [11:0] cgx = cgxy[23:12];
wire signed [11:0] cgy = cgxy[11:0];

// 容差 eps (运行期可调, 只 CANNY 档用):
//   eps=0 时 me == m4, 四个 keep 与 edge_pipeline.nms() / rtl_model.nms_rtl() 逐位一致;
//   eps>0 时中心加 eps 再与邻居比, 容忍半像素相位处两个候选像素"近等值二选一"的
//   翻转 —— 那是线条沿轮廓上下流动抖动的原因。代价是线宽略增(离线实测 1.00 -> 1.2~1.3 px)。
//   和 m4 一样是 11bit 量程, 加宽到 12bit 防溢出(最大 2047 + 8 = 2055)。
wire [11:0] me = {1'b0, m4} + {8'b0, cfg_eps};

wire keep0 = (me > {1'b0, m3}) & (me >= {1'b0, m5});     // 0   : L / R
wire keep1 = (me > {1'b0, m1}) & (me >= {1'b0, m7});     // 90  : U / D
wire keep2 = (me > {1'b0, m0}) & (me >= {1'b0, m8});     // 45  : UL / DR
wire keep3 = (me > {1'b0, m2}) & (me >= {1'b0, m6});     // 135 : UR / DL

wire keep_ref = (dc == 2'd0) ? keep0 :
                (dc == 2'd1) ? keep1 :
                (dc == 2'd2) ? keep2 : keep3;

//--------------------------------------------------------------------------
// 亚像素方向插值 NMS (cfg_inms=1): 免除法形式, 见文件头注释
//   a = min(|gx|,|gy|)   b = max(|gx|,|gy|)   (b-a) 与 a 就是两个插值权重分子
//   hor = 1: |gx|>=|gy| -> 主轴是左右(m3/m5), 斜轴是上/下对角
//   hor = 0: 主轴是上下(m1/m7), 斜轴是左/右对角
//   斜轴取哪一边由另一轴的符号决定(gy 定水平档的上下, gx 定垂直档的左右)
//--------------------------------------------------------------------------
wire [11:0] egx = cgx[11] ? (~cgx + 12'd1) : cgx;   // |gx|  (cgx 范围 ±1020)
wire [11:0] egy = cgy[11] ? (~cgy + 12'd1) : cgy;   // |gy|
wire        hor = (egx >= egy);
wire [11:0] ub  = hor ? egx : egy;                  // b
wire [11:0] ua  = hor ? egy : egx;                  // a
wire [11:0] uba = ub - ua;                          // b - a  (>=0)
wire        sgy = cgy[11];                          // gy < 0
wire        sgx = cgx[11];                          // gx < 0

// 前向(右/下)与后向(左/上)的 主轴邻居 M / 对角邻居 D
wire [10:0] nfm = hor ? m5 : m7;
wire [10:0] nfd = hor ? (sgy ? m2 : m8) : (sgx ? m6 : m8);
wire [10:0] nbm = hor ? m3 : m1;
wire [10:0] nbd = hor ? (sgy ? m6 : m0) : (sgx ? m2 : m0);

wire [25:0] lhs_f = {3'b000, (uba * nfm)} + {3'b000, (ua * nfd)};
wire [25:0] lhs_b = {3'b000, (uba * nbm)} + {3'b000, (ua * nbd)};
wire [25:0] cent  = {2'b00, (ub * me)};

wire keep_ip = (cent > lhs_f) && (cent >= lhs_b);

wire keep = cfg_inms ? keep_ip : keep_ref;

wire [10:0] mv = (m4 > 11'd255) ? 11'd255 : m4;

always @(posedge clk) begin
    if (!rst_n) out_data <= 8'd0;
    else        out_data <= keep ? mv[7:0] : 8'd0;
end

// 时序/坐标与 out_data(4 拍) 同拍
wire        c_vs, c_hs, c_de;
wire [11:0] c_x;
wire [12:0] c_y;
alg_stream_delay #(.DW(1), .D(1)) u_cdly (
    .clk(clk), .rst_n(rst_n),
    .in_vs(w_vs), .in_hs(w_hs), .in_de(w_de),
    .in_x(w_x), .in_y(w_y), .in_data(1'b0),
    .out_vs(c_vs), .out_hs(c_hs), .out_de(c_de),
    .out_x(c_x), .out_y(c_y), .out_data()
);

assign out_vs      = c_vs;
assign out_hs      = c_hs;
assign out_de_full = c_de;
assign out_de      = c_de & (c_y < H);
assign out_x       = c_x;
assign out_y       = c_y;

endmodule

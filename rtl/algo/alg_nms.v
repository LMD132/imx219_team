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
//  做法(与经典 Canny/cv2 的插值 NMS 同构, 免除法 + 16 档量化权重):
//    沿梯度方向的候选点 = "主轴邻居 M" 与 "对角邻居 D" 的线性插值:
//        n = ((15-w)*M + w*D) / 15,   w = floor(15*a/b)
//        a = min(|gx|,|gy|), b = max(|gx|,|gy|)   (b==0 -> w=0)
//    keep = (15*m > 15*n_strict) && (15*m >= 15*n_loose)
//         = 15*(m4+eps) 与 (15-w)*M + w*D 比 —— 无除法器/无 b, 只需 4 个 11x4 乘法。
//    w 的 16 档端点精确: a=0 -> w=0(退化成 4 方向量化版), a=b -> w=15(退化成
//    对角比较版), 中间连续过渡 -> 归轴跳变消失。
//    邻居选择: 主轴取 |.| 大的那根轴(hor), 对角取同象限的角邻居(见下面的
//    p_m/p_d/q_m/q_d); 严格侧口径与参考实现一致(见 code 的 strict 位)。
//
//  ★ 2026-09-28 修正(硬件对齐, 这是本模块能用的关键):
//    alg_win 的 3x3 窗口"内容坐标"比输入流晚 1 行 + 1 列 + 2 拍(窗口中心 =
//    输入的 (x-1,y-1)); 旧版用 alg_stream_delay(D=3) 延迟中心梯度, 实测
//    "延迟线标签 - 窗口标签"恒为 (+1,+1) —— 也就是插值用的是"下一行右边一列"
//    的梯度, 整条链对拍在帧顶/帧尾成片失配。
//    行周期还有 1 拍级抖动, 固定拍数延迟不可靠; 因此改为把插值需要的全部梯度
//    信息压成 7bit code, 跟 mag/dir 一起进窗口数据(行缓存/列移位同路) —— 对齐
//    由结构保证, 与行周期无关。窗口数据 13bit -> 20bit, 行缓存 +1 块/银行。
//
//  code[6:0] = {sgx, strict, hor, w[3:0]}:
//    sgx    = gx < 0
//    hor    = |gx| >= |gy|
//    strict = (gy < 0) | ((gy == 0) & (gx < 0))
//             —— 参考实现"严格侧"口径(y 偏移 <=0 的那侧用 '>', gy==0 取 x 小侧)
//    w      = floor(15*min/max), 由 15 个常量比较器(15a >= k*b, k=1..15)求和得到
//    对角邻居的上下选择用 sgy_eff = strict: 二者只在 gy==0 时不同, 而那时 w=0
//    (对角项权重为 0), 比较结果不受影响 —— check_inms.py 逐位自检覆盖。
//
//  自检(sim/algo/model/check_inms.py + check_inms_rtl.py 真 RTL 对拍):
//    · 四条轴(min(|gx|,|gy|)=0 或 |gx|=|gy|)上与参考实现逐位一致
//    · 合成斜边(阶跃 215 灰阶 + 高斯噪声)线宽变细、位置误差变小
//
//  cfg_inms = 1 -> 插值版(板端默认, 调参台 J 键可切, 见 alg_cfg_uart.v);
//  cfg_inms = 0 -> 逐位等于原参考实现(便于 A/B 对照与一键回退)。
//  延迟: 两条路径都是 4 拍(插值是纯组合, 不插流水线) -> ROWD/TDLY 不变。
//  资源: 4 个 11x4 无符号乘法 + 15 个 14bit 比较器; 行缓存 13->20bit(+1 块/银行)。
//  离线对比过 floor(15a/b) 与 round((30a+b)/(2b)) 两种量化: 合成斜边上指标差 <2%,
//  取 floor 更省(15 个比较器, 无额外加法), 见 sim/algo/model/check_inms.py 的 [2] 表。
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

localparam integer NW = 20;        // 窗口字宽 = {code[6:0], dir[1:0], mag[10:0]}

//--------------------------------------------------------------------------
// 输入级: 由当前像素梯度 (in_gx,in_gy) 生成 7bit 插值 code (组合)
//   a = min(|gx|,|gy|)  b = max(|gx|,|gy|)   w = floor(15*a/b) (b==0 -> 0)
//   w 用 15 个常量比较器求和实现(免除法): w = #{k=1..15 : 15*a >= k*b}
//--------------------------------------------------------------------------
wire [11:0] igx_abs = in_gx[11] ? (~in_gx + 12'd1) : in_gx;
wire [11:0] igy_abs = in_gy[11] ? (~in_gy + 12'd1) : in_gy;
wire        i_hor   = (igx_abs >= igy_abs);
wire [11:0] i_a     = i_hor ? igy_abs : igx_abs;    // min
wire [11:0] i_b     = i_hor ? igx_abs : igy_abs;    // max (<= 2040 实际 <=1020)
wire [13:0] i_a15   = {2'b00, i_a} * 14'd15;        // 15*a  (<= 15300)

// 位宽: |gx|,|gy| <= 1020 (alg_sobel3 全量程输出) -> 15*b <= 15300 < 2^14, 不溢出
wire [13:0] i_bk [1:15];
wire        i_ge [1:15];
genvar gk;
generate
for (gk = 1; gk <= 15; gk = gk + 1) begin : g_w
    assign i_bk[gk] = i_b * gk;                     // 常量乘法, 综合成移位加法
    assign i_ge[gk] = (i_a15 >= i_bk[gk]);
end
endgenerate
wire [3:0] i_w_raw = i_ge[1] + i_ge[2] + i_ge[3] + i_ge[4] + i_ge[5]
                   + i_ge[6] + i_ge[7] + i_ge[8] + i_ge[9] + i_ge[10]
                   + i_ge[11] + i_ge[12] + i_ge[13] + i_ge[14] + i_ge[15];
wire [3:0] i_w = (i_b == 12'd0) ? 4'd0 : i_w_raw;   // 零梯度 -> 权重 0

wire [6:0] i_code = {in_gx[11],
                     (in_gy[11] | ((in_gy == 12'sd0) & in_gx[11])),
                     i_hor, i_w};

wire        w_vs, w_hs, w_de;
wire [11:0] w_x;
wire [12:0] w_y;
wire [179:0] win;

alg_win #(
    .DW(NW), .W(W), .VEXT(VEXT), .H(H), .N(3), .PAD_EDGE(1)
) u_win (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_x(in_x), .in_y(in_y), .in_data({i_code, in_dir, in_mag}),
    .out_vs(w_vs), .out_hs(w_hs), .out_de(w_de),
    .out_x(w_x), .out_y(w_y), .win(win)
);

// win[k*NW +: NW] = {code[6:0], dir[1:0], mag[10:0]}
wire [10:0] m0 = win[0*NW + 0 +: 11];
wire [10:0] m1 = win[1*NW + 0 +: 11];
wire [10:0] m2 = win[2*NW + 0 +: 11];
wire [10:0] m3 = win[3*NW + 0 +: 11];
wire [10:0] m4 = win[4*NW + 0 +: 11];
wire [10:0] m5 = win[5*NW + 0 +: 11];
wire [10:0] m6 = win[6*NW + 0 +: 11];
wire [10:0] m7 = win[7*NW + 0 +: 11];
wire [10:0] m8 = win[8*NW + 0 +: 11];
wire [1:0]  dc = win[4*NW + 11 +: 2];          // 中心方向(参考路径用)
// 中心像素的插值 code (与 m4 同一块行缓存 -> 天然同像素)
wire        cc_sgx = win[4*NW + 19];
wire        cc_str = win[4*NW + 18];
wire        cc_hor = win[4*NW + 17];
wire [3:0]  cc_w   = win[4*NW + 16 -: 4];

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
// 亚像素方向插值 NMS (cfg_inms=1): 免除法 + 16 档权重, 见文件头注释
//   中心像素的 code 由窗口中心词给出(cc_*), 邻居取窗口里的 m0..m8
//   P 侧 = 梯度正方向那一对邻居, Q 侧 = 反方向那一对
//   (hor=1 主轴是左右, hor=0 主轴是上下; 对角取同象限的角邻居)
//--------------------------------------------------------------------------
wire        sgy_eff = cc_str;   // = (gy<0) | (gy==0 & gx<0); 差异仅在 w==0 时出现
wire [10:0] p_m = cc_hor ? (cc_sgx ? m3 : m5) : (sgy_eff ? m1 : m7);
wire [10:0] p_d = cc_sgx ? (sgy_eff ? m0 : m6) : (sgy_eff ? m2 : m8);
wire [10:0] q_m = cc_hor ? (cc_sgx ? m5 : m3) : (sgy_eff ? m7 : m1);
wire [10:0] q_d = cc_sgx ? (sgy_eff ? m8 : m2) : (sgy_eff ? m6 : m0);

wire [3:0]  wgt_d = cc_w;
wire [3:0]  wgt_m = 4'd15 - cc_w;
// 权重和恒为 15 -> 和 <= 15*2047, 15bit 不溢出
wire [14:0] lp = wgt_m * p_m + wgt_d * p_d;
wire [14:0] lq = wgt_m * q_m + wgt_d * q_d;
// ★ cent = 15*(m4+eps) 必须先把 me 扩到 15bit 再移位: Verilog 移位结果宽度 = 左操作数
//   宽度, 12bit 的 (me<<4) 会把高位丢掉(me>255 后 cent 完全错), 仿真/综合一致地错。
wire [14:0] me15 = {3'b0, me};
wire [14:0] cent = (me15 << 4) - me15;           // 15*me (<= 15*2055 = 30825 < 2^15)

wire [14:0] l_strict = cc_str ? lp : lq;
wire [14:0] l_loose  = cc_str ? lq : lp;

wire keep_ip = (cent > l_strict) && (cent >= l_loose);

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

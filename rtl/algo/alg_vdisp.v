//=============================================================================
// alg_vdisp.v -- 赛题4: 显示对准(行缓存) + 四种显示合成
//
//  为什么需要"显示对准"(实测结论, 见 docs/ALGO_RTL.md):
//    算法主链是 6 级级联窗口(中值 H2=1 + 高斯 H2=2 + Sobel 1 + NMS 1 +
//    阈值 1 + 去孤点 1)。每级窗口都要"下一行/下一列"才能算出当前像素,
//    所以 dsp 级输出"源像素 (x,y) 的边缘"时, 输入光栅已经流到 (x+7,y+7)
//    (7 = 各级 H2 累计; SOBEL 单/双阈值档走 NMS 旁路, 提前量是 6)。
//    也就是说 dedge 的标签 = 源像素坐标, 但它出现的时刻比彩色流晚几千拍
//    (约 7 行)。直接把 dedge 和彩色叠加 -> 边缘整体右下移 7 行 7 列
//    (实测 306 个显示像素里错 80 个)。
//
//  做法(全部在显示侧, 一行算法都不改):
//    * 显示光栅 = 输入光栅整体延迟 TDLY = 8*HTOTAL 拍(整行数): 行内相位不变,
//      显示器拿到的仍是一路合法光栅, 只是整帧晚 8 行。
//    * 彩色行缓存 8 行 x W(地址 = (行号 mod 8)*W + 列): 写=输入光栅, 读=显示
//      光栅。同一地址每隔 8 行被写一次、也被读一次, 读正好落在"上一次写"上
//      (READ_FIRST 保证同拍读写取旧值) -> 彩色与显示位置逐像素严格对齐。
//    * 边缘行缓存用同一套地址, 但写地址用 dsp 标签 (ed_x,ed_y)(=源像素坐标):
//      于是边缘值自动落回它所属的屏幕位置。
//    * 读地址计数器由"提前 2 拍"的显示光栅(e_de)驱动, 抵消行缓存的 2 拍读延迟,
//      这样地址算术里不需要额外的 +2 补偿。
//    * 灰度由延迟后的彩色现算 (77R+150G+29B)>>8(与 alg_gray 完全一致), 不另存。
//
//  显示模式:
//    mode 0: 同视野左右分屏(2:1 水平抽取): 左半=灰度全画幅, 右半=边缘全画幅
//    mode 1: 彩色原图 + 红边叠加(ov_color=0 时底色用灰度)
//    mode 2: 左右分区(1:1): 左半=画面左半灰度, 右半=画面右半边缘
//    mode 3: 全屏二值边缘
//
//  ★ mode 0 的"2:1 抽取"只发生在显示侧(参考实现是两幅全分辨率并排, 我们塞进
//    1280 宽必须 2:1)。旧版读地址是 2*rx -> 只留偶列, 奇数整列被丢掉: 一条 1px
//    细边缘会被打成断续虚线/珠状, 一动就像"电流在流"。修法 = 边缘行缓存改成一个
//    字存相邻两列(总位数不变), mode 0 读出时两列按位取或 -> 信息不丢(等效把边缘
//    加粗到 2px, 这正是消珠状需要的); 1:1 档(mode 1/2/3)按列奇偶选字节, 与改动
//    前逐像素完全一致, 零回归。
//
//  参数约束:
//    ROWD 必须 = 算法各级 H2 之和(本设计 = 14: 中值1+导向滤波4+高斯2+Sobel1+
//    NMS1+阈值1+断线桥接3+去孤点1), ROWS = ROWD+1 = 15(不再要求 2 的幂, 行号用 mod-15
//    计数器, 见下面 1)/2) 段);
//    TDLY = ROWS*HTOTAL 必须 < 2**TW(时延 RAM 深度, 本设计 TW=15 -> 32768,
//    而 15*2047 = 30705 < 32768 ✓)。
//    行缓存安全性(实测推导): 读一行比写晚 ROWS 行, 而同一 bank 要再过 ROWS 行
//    才会被下一行覆盖 -> 读总是落在"本 bank 上一次写"上(余量 1~2 拍)。
//    边缘写地址门控 ed_y < H 把帧尾复现行(alg_gray 的 REXT 行)排除在外。
//
//  资源(12 行): 彩色 12xW x16bit(RGB565; 原来是 24bit, 加导向滤波的 15 个行
//        缓存后 BRAM 预算不够, 显示侧降到 565 —— 算法/边缘完全不受影响) +
//        边缘 12xceil(W/2) x16bit(两列合一字) + 时延 RAM 1 块(3bit, 32768 深)。
//        显示灰度由 565 还原的 RGB 现算(与 alg_gray 同式), 最多差 1~2 LSB。
//=============================================================================

module alg_vdisp #(
    parameter integer W      = 1280,   // 有效像素宽度
    parameter integer H      = 720,    // 有效行数
    parameter integer HTOTAL = 1650,   // 输入光栅行周期初值(clk 数, 含消隐)
    parameter integer ROWD   = 11,     // 算法垂直/水平提前量(各级 H2 累计)
    parameter integer HALF   = 640     // W/2
)(
    input  wire        clk,
    input  wire        rst_n,

    // 输入(相机 / HDMI 源)光栅
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,
    input  wire [23:0] in_rgb,

    // 边缘流(dsp 级): (ed_x, ed_y) = 源像素标签, ed_de = 标签有效
    input  wire        ed_de,
    input  wire [11:0] ed_x,
    input  wire [12:0] ed_y,
    input  wire [7:0]  ed_d,

    input  wire [1:0]  mode,
    input  wire        ov_color,

    output wire        out_vs,
    output wire        out_hs,
    output wire        out_de,
    output wire [11:0] out_x,
    output wire [12:0] out_y,
    output wire [7:0]  out_r,
    output wire [7:0]  out_g,
    output wire [7:0]  out_b
);

localparam integer ROWS = ROWD + 1;                 // 行缓存行数 = 提前量 + 1
localparam integer RWB  = $clog2(ROWS);             // 行号 mod ROWS 计数位宽
localparam integer SIZE = ROWS * W;                 // 行缓存字数
localparam integer AW   = $clog2(SIZE);             // 行缓存地址位宽
localparam integer WS   = (W + 1) / 2;              // 边缘行缓存: 一个字存相邻两列
localparam integer SIZEE = ROWS * WS;               // 边缘行缓存字数
localparam integer AWE  = $clog2(SIZEE);            // 边缘行缓存地址位宽
localparam integer TW   = 15;                       // 时延 RAM 地址位宽(32768 深)
localparam integer AB   = AW + 1;                   // 行缓存地址运算位宽(留 1 位防溢出)
localparam integer HTL0 = (HTOTAL > 2047) ? 2047 : HTOTAL;  // 保证 ROWS*HTL0 < 2**TW
// 显示整体延迟 TDLY = ROWS * 行周期(运行时值, 见下面的实测)

//--------------------------------------------------------------------------
// 0) 时延 RAM: 输出光栅(延迟 TDLY) + 读相位光栅(延迟 TDLY-2)
//    行周期 lper 用"输入光栅连续 3 次相同的行首间距"实测修正: 本工程的显示
//    光栅来自相机(MIPI RX -> 去马赛克)链路, 其行周期不是综合期常量, 所以不
//    能用死的 HTOTAL 常数(否则 TDLY 不是行周期整数倍 -> 画面水平错位/撕裂)。
//    参数 HTOTAL 只作上电初值, 实测一旦成立就自动切换。
//--------------------------------------------------------------------------
reg [TW-1:0] wctr;
always @(posedge clk) begin
    if (!rst_n) wctr <= {TW{1'b0}};
    else        wctr <= wctr + 1'b1;
end

reg  [15:0] hcnt;      // 距上次行首的 clk 数
reg  [15:0] cand;      // 行周期候选值
reg  [1:0]  ccnt;      // 候选值连续命中次数
reg  [15:0] lper;      // 当前采用的行周期
reg         in_de_d;
wire        lstart = in_de & ~in_de_d;

always @(posedge clk) begin
    if (!rst_n) begin
        hcnt <= 16'd0; cand <= 16'd0; ccnt <= 2'd0; in_de_d <= 1'b0;
        lper <= HTL0[15:0];
    end else begin
        in_de_d <= in_de;
        hcnt <= lstart ? 16'd1 : (hcnt + 16'd1);
        if (lstart) begin
            if (hcnt == cand) ccnt <= (ccnt == 2'd3) ? 2'd3 : (ccnt + 2'd1);
            else begin cand <= hcnt; ccnt <= 2'd1; end
            // 连续 3 次相同才采纳(滤掉帧间垂直消隐造成的超长"行周期")
            if ((hcnt == cand) && (ccnt >= 2'd2) && (hcnt <= 16'd2047))
                lper <= hcnt;
        end
    end
end

wire [31:0]   tdly_w = lper * ROWS;         // 常数乘 -> 移位, 无 DSP
wire [TW-1:0] TDLY   = tdly_w[TW-1:0];

wire [TW-1:0] ra_rd  = wctr + 4 - TDLY;             // 读地址相位(比显示相位提前 2 拍)

// 只留一套时延 RAM(读相位), 显示相位由它的输出再打 2 拍得到 —— 与原来
// u_tim_o(raddr = wctr+2-TDLY) + u_tim_e(raddr = wctr+4-TDLY) 两套 RAM
// 逐位等价(RAM 读延迟相同, 丢掉的那 4 块 RAM 正好被行缓存扩到 12 行吃掉)。
wire [2:0] tim_rd;                                  // 读相位 {vs,hs,de}

simple_dual_port_ram #(
    .DATA_WIDTH(3), .ADDR_WIDTH(TW), .OUTPUT_REG("TRUE"), .RAM_INIT_FILE("")
) u_tim (
    .wdata({in_vs, in_hs, in_de}), .waddr(wctr), .we(1'b1), .wclk(clk),
    .raddr(ra_rd), .re(1'b1), .rclk(clk), .rdata(tim_rd)
);

reg [2:0] tim_rd1, tim_rd2;
always @(posedge clk) begin
    if (!rst_n) begin tim_rd1 <= 3'd0; tim_rd2 <= 3'd0; end
    else        begin tim_rd1 <= tim_rd; tim_rd2 <= tim_rd1; end
end

wire d_vs = tim_rd2[2], d_hs = tim_rd2[1], d_de = tim_rd2[0];   // 显示相位
wire e_vs = tim_rd[2],  e_de = tim_rd[0];                       // 读相位(早 2 拍)

// 上电后前 TDLY 拍, 读地址还没被写过(仿真为 x), 用 primed 把输出关掉
reg primed;
always @(posedge clk) begin
    if (!rst_n) primed <= 1'b0;
    else if (wctr >= TDLY) primed <= 1'b1;
end

//--------------------------------------------------------------------------
// 1) 输入侧行列计数 -> 彩色行缓存写地址
//--------------------------------------------------------------------------
reg [11:0] wx;
reg [12:0] wy;
reg        in_de_r;
reg [RWB-1:0] wy_m;                 // wy mod ROWS (ROWS=12 不是 2 的幂, 位选不行)

always @(posedge clk) begin
    if (!rst_n) begin
        wx <= 12'd0; wy <= 13'd0; in_de_r <= 1'b0; wy_m <= {RWB{1'b0}};
    end else begin
        in_de_r <= in_de;
        if (in_vs) begin
            wx <= 12'd0;
            wy <= 13'd0;
            wy_m <= {RWB{1'b0}};
        end else begin
            if (in_de) wx <= (wx == (W-1)) ? 12'd0 : (wx + 12'd1);
            else       wx <= 12'd0;
            if (~in_de & in_de_r) begin
                wy   <= (wy == (H-1)) ? 13'd0 : (wy + 13'd1);
                wy_m <= (wy_m == (ROWS-1)) ? {RWB{1'b0}} : (wy_m + 1'b1);
            end
        end
    end
end

wire [AB-1:0] c_waddr = (wy_m * W) + wx;

//--------------------------------------------------------------------------
// 2) 读相位列计数(提前 2 拍) -> 行缓存读地址 + 显示坐标
//--------------------------------------------------------------------------
reg [11:0] rx;
reg [12:0] ry;
reg        e_de_r;
reg [RWB-1:0] ry_m;                 // ry mod ROWS

always @(posedge clk) begin
    if (!rst_n) begin
        rx <= 12'd0; ry <= 13'd0; e_de_r <= 1'b0; ry_m <= {RWB{1'b0}};
    end else begin
        e_de_r <= e_de;
        if (e_vs) begin
            rx <= 12'd0;
            ry <= 13'd0;
            ry_m <= {RWB{1'b0}};
        end else begin
            if (e_de) rx <= (rx == (W-1)) ? 12'd0 : (rx + 12'd1);
            else      rx <= 12'd0;
            if (~e_de & e_de_r) begin
                ry   <= (ry == (H-1)) ? 13'd0 : (ry + 13'd1);
                ry_m <= (ry_m == (ROWS-1)) ? {RWB{1'b0}} : (ry_m + 1'b1);
            end
        end
    end
end

// 输出坐标 = 读相位坐标晚 2 拍(与行缓存输出数据同拍)
reg [11:0] ox1, ox2;
reg [12:0] oy1, oy2;
always @(posedge clk) begin
    if (!rst_n) begin
        ox1 <= 12'd0; ox2 <= 12'd0; oy1 <= 13'd0; oy2 <= 13'd0;
    end else begin
        ox1 <= rx; ox2 <= ox1;
        oy1 <= ry; oy2 <= oy1;
    end
end

wire        lft  = (rx < HALF);
wire [12:0] rx2  = {rx, 1'b0};                      // 2*rx   (mode 0 左半)
wire [12:0] rxh  = (rx - HALF) << 1;                // 2*(rx-HALF) (mode 0 右半)
wire [12:0] col_c = (mode == 2'd0) ? (lft ? rx2 : rxh) : {1'b0, rx};

// mode 2 拍延迟: 行缓存地址在"当前 rx/mode"这拍给出, 数据 2 拍后才出来,
// 所以读出端的选列/mode 判断必须用同拍的 mode_d2 与 ox2(= rx 晚 2 拍)
reg [1:0] mode_d1, mode_d2;
always @(posedge clk) begin
    if (!rst_n) begin mode_d1 <= 2'd0; mode_d2 <= 2'd0; end
    else        begin mode_d1 <= mode; mode_d2 <= mode_d1; end
end

wire [AB-1:0] c_base = ry_m * W;
wire [AB-1:0] c_ra   = c_base + col_c;              // 可能越过 SIZE -> 回卷
wire [AB-1:0] r_rd   = (c_ra >= SIZE) ? (c_ra - SIZE) : c_ra;

//--------------------------------------------------------------------------
// 3) 彩色行缓存(24bit x W) + 边缘行缓存(16bit x W/2, 一个字存相邻两列)
//
//    边缘字 = {奇列, 偶列}(低字节 = 偶列)。写侧: 偶列先暂存, 奇列到达那一拍
//    整字写入(ed_x 只在 ed_de 时 +1, 同一行的偶列一定紧邻其奇列到达, 不会错配);
//    W 为奇数时最后一对只有偶列, 偶列那一拍就把高字节写 0(不会被误读成边缘)。
//    读侧: 地址按"列号>>1"算, 与彩色同一列;
//      mode 0      -> 相邻两列取或, 2:1 抽取不丢奇数整列(修"细线被打成虚线")
//      其余 1:1 档 -> 按列奇偶选字节, 输出与旧版逐像素一致
//    注意取或/选字节用的 ox2[0] 必须与 edg_pair 同拍(见上面的 2 拍延迟推导)。
//--------------------------------------------------------------------------
wire [15:0] col_dout;                               // RGB565
wire [15:0] edg_pair;
wire [7:0]  edg_dout;

wire        ed_in   = ed_de & (ed_x < W) & (ed_y < H);
// 边缘写行号 = 帧内行号 mod ROWS(与读侧 ry_m 同一套编号)。
// ★ 行首必须用 ed_de 的"上升沿"判: dsp 标签 ed_y 在行间消隐里就跳到下一行,
//   若用 (ed_de & ed_y!=ed_y_d) 判, ed_y_d 在消隐期已经追平 -> 行首永不触发 ->
//   所有边缘都写进 bank0, 其余行读出 x(实测 mode3 只有 y=0 有值, 正是此因)。
//   另外不能用 wy_m: 边缘值到达时输入光栅已经流过 ROWD 行去了。
// ★ 写地址必须用"组合的下一 bank"(ed_rm_w): ed_rm 寄存器要到行首之后一拍才更新,
//   若写地址直接用 ed_rm, 每行第 0 个像素(偶列 x=0)会落进上一行的 bank, 而它写的
//   是 {8'h00, ed_d} -> 把上一行那个字的奇列字节清成 0(实测 (y=7,x=1) 边缘丢失)。
reg           ed_de_r;
reg [RWB-1:0] ed_rm;
wire          ed_row_start = ed_de & ~ed_de_r;
wire [RWB-1:0] ed_rm_nxt = (ed_y == 13'd0) ? {RWB{1'b0}}
                         : ((ed_rm == (ROWS-1)) ? {RWB{1'b0}} : (ed_rm + 1'b1));
wire [RWB-1:0] ed_rm_w  = ed_row_start ? ed_rm_nxt : ed_rm;

always @(posedge clk) begin
    if (!rst_n) begin ed_de_r <= 1'b0; ed_rm <= {RWB{1'b0}}; end
    else begin
        ed_de_r <= ed_de;
        if (ed_row_start) ed_rm <= ed_rm_nxt;
    end
end

wire [13:0] e_waddr = (ed_rm_w * WS) + {1'b0, ed_x[11:1]};
wire [13:0] e_ra    = (ry_m * WS) + {1'b0, col_c[12:1]};   // 与彩色同一列 -> 所属字
reg  [7:0]  edg_even;                                  // 偶列暂存
wire [15:0] e_wdata = ed_x[0] ? {ed_d, edg_even} : {8'h00, ed_d};

// 彩色行缓存: 写侧压成 RGB565(16bit), 读侧还原回 888(位复制, 再做灰度和叠加)。
// 24bit -> 16bit 是为了腾出 BRAM 给导向滤波(行数 8 -> 12 之后 24bit 放不下)。
wire [15:0] col_565 = {in_rgb[23:19], in_rgb[15:10], in_rgb[7:3]};

// 行缓存用精确深度的 alg_ring_ram: simple_dual_port_ram 会把 19200 撑成 32768
// 深, BRAM 32->64 块, 256 块装不下(详见 alg_ring_ram.v 头注释)。
alg_ring_ram #(
    .DATA_WIDTH(16), .ADDR_WIDTH(AW), .DEPTH(SIZE), .OUTPUT_REG("TRUE")
) u_cring (
    .wdata(col_565), .waddr(c_waddr[AW-1:0]), .we(in_de), .wclk(clk),
    .raddr(r_rd[AW-1:0]), .re(1'b1), .rclk(clk), .rdata(col_dout)
);

wire [23:0] col_888 = {col_dout[15:11], col_dout[15:13],
                       col_dout[10:5],  col_dout[10:9],
                       col_dout[4:0],   col_dout[4:2]};

alg_ring_ram #(
    .DATA_WIDTH(16), .ADDR_WIDTH(AWE), .DEPTH(SIZEE), .OUTPUT_REG("TRUE")
) u_ering (
    .wdata(e_wdata), .waddr(e_waddr[AWE-1:0]), .we(ed_in), .wclk(clk),
    .raddr(e_ra[AWE-1:0]), .re(1'b1), .rclk(clk), .rdata(edg_pair)
);

always @(posedge clk) begin
    if (!rst_n) edg_even <= 8'd0;
    else if (ed_in & ~ed_x[0]) edg_even <= ed_d;
end

assign edg_dout = (mode_d2 == 2'd0) ? (edg_pair[7:0] | edg_pair[15:8])
                                    : (ox2[0] ? edg_pair[15:8] : edg_pair[7:0]);

//--------------------------------------------------------------------------
// 4) 输出级(2 级流水): 行缓存读出先寄存, 再算灰度/合成并寄存输出。
//    关键路径 = "寄存器 -> 加法树/选择 -> 输出寄存器"(不含 RAM 的 Tco),
//    为 74.25MHz(hdmi_tx_slow_clk) 留时序余量(基线 setup slack 仅 +0.467ns)。
//--------------------------------------------------------------------------
reg  [23:0] col_q;
reg  [7:0]  edg_q;
reg  [11:0] x_q;
reg  [12:0] y_q;
reg         de_q, vs_q, hs_q;

always @(posedge clk) begin
    if (!rst_n) begin
        col_q <= 24'd0; edg_q <= 8'd0; x_q <= 12'd0; y_q <= 13'd0;
        de_q  <= 1'b0;  vs_q  <= 1'b0; hs_q <= 1'b0;
    end else begin
        col_q <= col_888; edg_q <= edg_dout;
        x_q   <= ox2;      y_q   <= oy2;
        de_q  <= d_de;     vs_q  <= d_vs;  hs_q <= d_hs;
    end
end

// 灰度现算(与 alg_gray 逐位一致): (77R+150G+29B)>>8
wire [15:0] r16 = {8'd0, col_q[23:16]};
wire [15:0] g16 = {8'd0, col_q[15:8]};
wire [15:0] b16 = {8'd0, col_q[7:0]};
wire [15:0] luma_sum = (r16 << 6) + (r16 << 3) + (r16 << 2) + r16
                     + (g16 << 7) + (g16 << 4) + (g16 << 2) + (g16 << 1)
                     + (b16 << 5) - (b16 << 2) + b16;
wire [7:0]  gray_d = luma_sum[15:8];

wire lft_d = (x_q < HALF);

wire [7:0] base_r = ov_color ? col_q[23:16] : gray_d;
wire [7:0] base_g = ov_color ? col_q[15:8]  : gray_d;
wire [7:0] base_b = ov_color ? col_q[7:0]   : gray_d;
wire       e_on   = (edg_q != 8'd0);

reg [7:0] px_r, px_g, px_b;
always @* begin
    if (mode == 2'd0 || mode == 2'd2) begin      // 分屏: 左灰度 / 右边缘
        px_r = lft_d ? gray_d : edg_q;
        px_g = px_r;
        px_b = px_r;
    end else if (mode == 2'd1) begin             // 彩色 + 红边叠加
        if (e_on) begin px_r = 8'hFF; px_g = 8'h00; px_b = 8'h00; end
        else      begin px_r = base_r; px_g = base_g; px_b = base_b; end
    end else begin                               // 纯边缘
        px_r = edg_q; px_g = edg_q; px_b = edg_q;
    end
end

// 输出寄存器(与 out_de/out_x/out_y 同拍)
reg [7:0]  orr, org, orb;
reg [11:0] x2_r;
reg [12:0] y2_r;
reg        de2_r, vs2_r, hs2_r;

always @(posedge clk) begin
    if (!rst_n) begin
        orr <= 8'd0; org <= 8'd0; orb <= 8'd0;
        x2_r <= 12'd0; y2_r <= 13'd0;
        de2_r <= 1'b0; vs2_r <= 1'b0; hs2_r <= 1'b0;
    end else begin
        orr <= primed ? px_r : 8'd0;
        org <= primed ? px_g : 8'd0;
        orb <= primed ? px_b : 8'd0;
        x2_r <= x_q;  y2_r <= y_q;
        de2_r <= de_q; vs2_r <= vs_q; hs2_r <= hs_q;
    end
end

assign out_x = x2_r;
assign out_y = y2_r;
assign out_de = de2_r & primed;
assign out_vs = vs2_r & primed;
assign out_hs = hs2_r & primed;
assign out_r = orr;
assign out_g = org;
assign out_b = orb;

endmodule

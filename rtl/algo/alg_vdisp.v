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
//  参数约束:
//    ROWD 必须 = 算法各级 H2 之和(本设计 = 7), ROWS = ROWD+1 必须是 2 的幂;
//    TDLY = ROWS*HTOTAL 必须 < 2**14(时延 RAM 深度)。
//    行缓存安全性(实测推导): 读一行比写晚 ROWS 行, 而同一 bank 要再过 ROWS 行
//    才会被下一行覆盖 -> 读总是落在"本 bank 上一次写"上(余量 1~2 拍)。
//    边缘写地址门控 ed_y < H 把帧尾复现行(alg_gray 的 REXT 行)排除在外。
//
//  资源: 彩色 8xW x24bit + 边缘 8xW x8bit + 时延 RAM 2 块(3bit / 2bit)
//=============================================================================

module alg_vdisp #(
    parameter integer W      = 1280,   // 有效像素宽度
    parameter integer H      = 720,    // 有效行数
    parameter integer HTOTAL = 1650,   // 输入光栅行周期初值(clk 数, 含消隐)
    parameter integer ROWD   = 7,      // 算法垂直/水平提前量(各级 H2 累计)
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

localparam integer ROWS = 1 << $clog2(ROWD+1);      // 行缓存行数(2 的幂)
localparam integer SIZE = ROWS * W;                 // 行缓存字数
localparam integer AW   = $clog2(SIZE);             // 行缓存地址位宽
localparam integer TW   = 14;                       // 时延 RAM 地址位宽(16384 深)
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

wire [TW-1:0] ra_out = wctr + 2 - TDLY;             // 输出相位
wire [TW-1:0] ra_rd  = wctr + 4 - TDLY;             // 读地址相位(提前 2 拍)

wire [2:0] tim_o;                                   // {vs,hs,de}
wire [1:0] tim_e;                                   // {vs,de}

simple_dual_port_ram #(
    .DATA_WIDTH(3), .ADDR_WIDTH(TW), .OUTPUT_REG("TRUE"), .RAM_INIT_FILE("")
) u_tim_o (
    .wdata({in_vs, in_hs, in_de}), .waddr(wctr), .we(1'b1), .wclk(clk),
    .raddr(ra_out), .re(1'b1), .rclk(clk), .rdata(tim_o)
);

simple_dual_port_ram #(
    .DATA_WIDTH(2), .ADDR_WIDTH(TW), .OUTPUT_REG("TRUE"), .RAM_INIT_FILE("")
) u_tim_e (
    .wdata({in_vs, in_de}), .waddr(wctr), .we(1'b1), .wclk(clk),
    .raddr(ra_rd), .re(1'b1), .rclk(clk), .rdata(tim_e)
);

wire d_vs = tim_o[2], d_hs = tim_o[1], d_de = tim_o[0];
wire e_vs = tim_e[1], e_de = tim_e[0];

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

always @(posedge clk) begin
    if (!rst_n) begin
        wx <= 12'd0; wy <= 13'd0; in_de_r <= 1'b0;
    end else begin
        in_de_r <= in_de;
        if (in_vs) begin
            wx <= 12'd0;
            wy <= 13'd0;
        end else begin
            if (in_de) wx <= (wx == (W-1)) ? 12'd0 : (wx + 12'd1);
            else       wx <= 12'd0;
            if (~in_de & in_de_r) wy <= (wy == (H-1)) ? 13'd0 : (wy + 13'd1);
        end
    end
end

wire [13:0] c_waddr = (wy[2:0] * W) + wx;

//--------------------------------------------------------------------------
// 2) 读相位列计数(提前 2 拍) -> 行缓存读地址 + 显示坐标
//--------------------------------------------------------------------------
reg [11:0] rx;
reg [12:0] ry;
reg        e_de_r;

always @(posedge clk) begin
    if (!rst_n) begin
        rx <= 12'd0; ry <= 13'd0; e_de_r <= 1'b0;
    end else begin
        e_de_r <= e_de;
        if (e_vs) begin
            rx <= 12'd0;
            ry <= 13'd0;
        end else begin
            if (e_de) rx <= (rx == (W-1)) ? 12'd0 : (rx + 12'd1);
            else      rx <= 12'd0;
            if (~e_de & e_de_r) ry <= (ry == (H-1)) ? 13'd0 : (ry + 13'd1);
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

wire [13:0] c_base = ry[2:0] * W;
wire [14:0] c_ra   = c_base + col_c;                // 可能越过 SIZE -> 回卷
wire [13:0] r_rd   = (c_ra >= SIZE) ? (c_ra - SIZE) : c_ra[13:0];

//--------------------------------------------------------------------------
// 3) 彩色行缓存 + 边缘行缓存(同地址, 一块 simple_dual_port_ram 各一)
//--------------------------------------------------------------------------
wire [23:0] col_dout;
wire [7:0]  edg_dout;
wire        ed_we = ed_de & (ed_x < W) & (ed_y < H);
wire [14:0] e_waddr = (ed_y[2:0] * W) + ed_x;

simple_dual_port_ram #(
    .DATA_WIDTH(24), .ADDR_WIDTH(AW), .OUTPUT_REG("TRUE"), .RAM_INIT_FILE("")
) u_cring (
    .wdata(in_rgb), .waddr(c_waddr[AW-1:0]), .we(in_de), .wclk(clk),
    .raddr(r_rd[AW-1:0]), .re(1'b1), .rclk(clk), .rdata(col_dout)
);

simple_dual_port_ram #(
    .DATA_WIDTH(8), .ADDR_WIDTH(AW), .OUTPUT_REG("TRUE"), .RAM_INIT_FILE("")
) u_ering (
    .wdata(ed_d), .waddr(e_waddr[AW-1:0]), .we(ed_we), .wclk(clk),
    .raddr(r_rd[AW-1:0]), .re(1'b1), .rclk(clk), .rdata(edg_dout)
);

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
        col_q <= col_dout; edg_q <= edg_dout;
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
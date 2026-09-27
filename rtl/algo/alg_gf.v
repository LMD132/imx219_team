//=============================================================================
// alg_gf.v -- 赛题4 EPF 档(中值之后的前置滤波, live_tune.py 的 EPF 滑条)
//
//  算法来源(唯一权威): FPGA-Python
//    * edge_pipeline.py :: guided_filter(gray, radius=6, eps=400)
//          mean_I  = boxFilter(I, 6)        mean_II = boxFilter(I*I, 6)
//          var     = mean_II - mean_I^2
//          a       = var / (var + eps)      b       = mean_I - a*mean_I
//          out     = clip(boxFilter(a,6)*I + boxFilter(b,6), 0, 255)
//      (cv2 默认 anchor=(3,3) 的 6x6 盒窗 = 6 抽头 [x-3..x+2], 硬件上就是
//       alg_win(N=6) 的 36 个 tap 直接求和, 见 rtl_model.box6_sum_int)
//    * live_tune.py EPF: 0=关 1=gaussian3x3 2=导向滤波
//      gaussian3x3 核 = [1,2,1;2,4,2;1,2,1]/16 (整数版 sum>>4, 同 alg_gauss3.v)
//
//  硬件结构(与 rtl_model.guided_filter_int 逐位对应):
//    级1: alg_win(N=6) 取 I 的 6x6 窗 -> S1 = ΣI, S2 = ΣI^2
//         V   = 36*S2 - S1^2 = 1296*var (25bit)
//         a_q8 = sat8(round(256*V/(V+1296*eps)))        <- u_div (9 级流水)
//         mI_q8 = round(256*mean_I) = (S1*455+32)>>6
//         b_q  = (mI_q8*(256-a_q8) + 2^15) >> 16        (= mean_I*(1-a))
//    级2: alg_win(N=6) 取 a_q8 的 6x6 窗 -> Sa, alg_win(N=6) 取 b_q -> Sb
//         u = (Sa*I + 128) >> 8;  q = clip( ((u+Sb)*455 + 8192) >> 14, 0, 255)
//
//  epf!=2 时: 级1 只算 gaussian3x3(epf==1) 或直通(epf==0) 当作 a 通道,
//  b 通道填 0; 级2 只取窗口中心(直通)。于是三个档位的 H2(垂直提前量)恒为
//  2+2 = 4 拍、总延迟恒为 25 拍 -> 换档不改变显示对齐, ROWD 也不随档位变化。
//
//  流水线延迟: 输入 -> out_data = 3(窗1) + 16(级1) + 3(窗2) + 3(级2) = 25 拍
//  en/旁路约定: 与 alg_gauss3/alg_gauss5 一致, 延迟不随档位改变。
//  资源: 3 x alg_win(N=6) = 3 x 5 bank x 2 块 RAM10 = 30 块; 除法器纯 LUT/FF。
//=============================================================================

module alg_gf #(
    parameter integer W    = 1280,
    parameter integer VEXT = 16,
    parameter integer H    = 720
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  epf,          // 0=关 1=3x3 高斯 2=导向滤波
    input  wire [10:0] gf_eps,       // 导向滤波 eps (0..2000, 参考值 400)
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,
    input  wire [11:0] in_x,
    input  wire [12:0] in_y,
    input  wire [7:0]  in_data,
    output wire        out_vs,
    output wire        out_hs,
    output wire        out_de_full,
    output wire        out_de,
    output wire [11:0] out_x,
    output wire [12:0] out_y,
    output reg  [7:0]  out_data
);

localparam integer C1 = 16;          // 窗1 输出 -> a/b 送进窗2 的拍数
localparam integer LW = 3;           // alg_win 固有延迟
localparam integer D2 = C1 + LW;     // 19: 窗2 输出相对窗1 输出的拍数

//--------------------------------------------------------------------------
// 级1 输入窗: I 的 6x6 窗
//--------------------------------------------------------------------------
wire        w1_vs, w1_hs, w1_de;
wire [11:0] w1_x;
wire [12:0] w1_y;
wire [287:0] win1;

alg_win #(
    .DW(8), .W(W), .VEXT(VEXT), .H(H), .N(6), .PAD_EDGE(1)
) u_win1 (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_x(in_x), .in_y(in_y), .in_data(in_data),
    .out_vs(w1_vs), .out_hs(w1_hs), .out_de(w1_de),
    .out_x(w1_x), .out_y(w1_y), .win(win1)
);

function [7:0] tp;                  // win[(i*6+j)*8 +: 8]
    input [287:0] w;
    input integer i;
    input integer j;
    begin
        tp = w[(i*6 + j)*8 +: 8];
    end
endfunction

function [15:0] sqf;                // 8x8 平方(综合成乘法器/DSP)
    input [7:0] x;
    begin
        sqf = x * x;
    end
endfunction

// 行方向 6 抽头和(<= 1530, 11bit) 与 行方向平方和(<= 390150, 19bit)
wire [10:0] s1r0 = tp(win1,0,0)+tp(win1,0,1)+tp(win1,0,2)+tp(win1,0,3)+tp(win1,0,4)+tp(win1,0,5);
wire [10:0] s1r1 = tp(win1,1,0)+tp(win1,1,1)+tp(win1,1,2)+tp(win1,1,3)+tp(win1,1,4)+tp(win1,1,5);
wire [10:0] s1r2 = tp(win1,2,0)+tp(win1,2,1)+tp(win1,2,2)+tp(win1,2,3)+tp(win1,2,4)+tp(win1,2,5);
wire [10:0] s1r3 = tp(win1,3,0)+tp(win1,3,1)+tp(win1,3,2)+tp(win1,3,3)+tp(win1,3,4)+tp(win1,3,5);
wire [10:0] s1r4 = tp(win1,4,0)+tp(win1,4,1)+tp(win1,4,2)+tp(win1,4,3)+tp(win1,4,4)+tp(win1,4,5);
wire [10:0] s1r5 = tp(win1,5,0)+tp(win1,5,1)+tp(win1,5,2)+tp(win1,5,3)+tp(win1,5,4)+tp(win1,5,5);

wire [18:0] q0 = sqf(tp(win1,0,0))+sqf(tp(win1,0,1))+sqf(tp(win1,0,2))+sqf(tp(win1,0,3))+sqf(tp(win1,0,4))+sqf(tp(win1,0,5));
wire [18:0] q1 = sqf(tp(win1,1,0))+sqf(tp(win1,1,1))+sqf(tp(win1,1,2))+sqf(tp(win1,1,3))+sqf(tp(win1,1,4))+sqf(tp(win1,1,5));
wire [18:0] q2 = sqf(tp(win1,2,0))+sqf(tp(win1,2,1))+sqf(tp(win1,2,2))+sqf(tp(win1,2,3))+sqf(tp(win1,2,4))+sqf(tp(win1,2,5));
wire [18:0] q3 = sqf(tp(win1,3,0))+sqf(tp(win1,3,1))+sqf(tp(win1,3,2))+sqf(tp(win1,3,3))+sqf(tp(win1,3,4))+sqf(tp(win1,3,5));
wire [18:0] q4 = sqf(tp(win1,4,0))+sqf(tp(win1,4,1))+sqf(tp(win1,4,2))+sqf(tp(win1,4,3))+sqf(tp(win1,4,4))+sqf(tp(win1,4,5));
wire [18:0] q5 = sqf(tp(win1,5,0))+sqf(tp(win1,5,1))+sqf(tp(win1,5,2))+sqf(tp(win1,5,3))+sqf(tp(win1,5,4))+sqf(tp(win1,5,5));

// EPF=1 的 gaussian3x3: 窗口中心 3x3 (索引 2..4) 的 [1,2,1]^2/16, 与 alg_gauss3 同式
wire [9:0] g3r0 = {2'b0,tp(win1,2,2)} + {1'b0,tp(win1,2,3),1'b0} + {2'b0,tp(win1,2,4)};
wire [9:0] g3r1 = {2'b0,tp(win1,3,2)} + {1'b0,tp(win1,3,3),1'b0} + {2'b0,tp(win1,3,4)};
wire [9:0] g3r2 = {2'b0,tp(win1,4,2)} + {1'b0,tp(win1,4,3),1'b0} + {2'b0,tp(win1,4,4)};
wire [11:0] g3s = {2'b0,g3r0} + {1'b0,g3r1,1'b0} + {2'b0,g3r2};
wire [7:0]  g3  = g3s[11:4];

//--------------------------------------------------------------------------
// 级1 流水: A+1 行和 -> A+2 S1/S2 -> A+3 P/Q/M -> A+4 V/d/mI_q8 -> 除法 11 拍
//--------------------------------------------------------------------------
reg [12:0] r1a, r1b;                  // 3 行和(<= 4590, 13bit)
reg [20:0] r2a, r2b;                  // 3 行平方和(<= 1170450, 21bit)
reg [7:0]  r_cen, r_aval;             // 窗口中心 / 非 GF 档的 a 通道值

always @(posedge clk) begin
    if (!rst_n) begin
        r1a <= 13'd0; r1b <= 13'd0; r2a <= 21'd0; r2b <= 21'd0;
        r_cen <= 8'd0; r_aval <= 8'd0;
    end else begin
        r1a <= s1r0 + s1r1 + s1r2;
        r1b <= s1r3 + s1r4 + s1r5;
        r2a <= q0 + q1 + q2;
        r2b <= q3 + q4 + q5;
        // r_cen = 输出坐标 C 处的像素 I(x,y): 窗2 输出标签 C = 窗1 标签 - 2,
        //   而 alg_win 的 win[j] = 标签-3+j, 所以窗1 的 (1,1) 抽头正好是坐标 C 的像素。
        //   (不能用锚点 (3,3): 那是坐标 C+2 的像素, 会让 u = mean_a*I 整体错两像素。)
        r_cen  <= tp(win1,1,1);
        // r_aval = 非 GF 档的 a 通道(= 该标签坐标处的原像素/3x3 高斯), 锚点 (3,3) 正确
        r_aval <= (epf == 2'd1) ? g3 : tp(win1,3,3);
    end
end

reg [13:0] s1;                        // ΣI  (<= 9180)
reg [21:0] s2;                        // ΣI^2(<= 2340900)
always @(posedge clk) begin
    if (!rst_n) begin s1 <= 14'd0; s2 <= 22'd0; end
    else        begin s1 <= r1a + r1b; s2 <= r2a + r2b; end
end

// K = 1296*eps (运行期; 1024+256+16 移位加法, 无乘法器)
reg [26:0] k_r;
wire [21:0] k_c = (gf_eps << 10) + (gf_eps << 8) + (gf_eps << 4);
always @(posedge clk) begin
    if (!rst_n) k_r <= 27'd0;
    else        k_r <= {5'b0, k_c};
end

reg [26:0] v_r;                       // 1296*var (<= 21067776, 25bit)
reg [26:0] d_r;                       // V + K
reg [15:0] miq_r;                     // round(256*mean_I) <= 65264
// 36*S2 = (S2<<5)+(S2<<2); S1*S1 用乘法器 -> V = 1296*var (数学上 >= 0)
wire [27:0] vv = ( (s2 << 5) + (s2 << 2) ) - (s1 * s1);
// ★ 坑: 如果直接写 (s1 * 11'd455) + 16'd32, 整个表达式按 16bit 求值,
//   s1*455 (<= 4176900, 需 22bit) 会被截成 16bit -> mean_I 全错。
//   这里显式给足 22bit 上下文 (s1 扩展到 22bit 后再乘), 与 rtl_model 逐位一致。
wire [21:0] miq_n = (s1 * 16'd455) + 22'd32;      // <= 4176932 < 2^22
always @(posedge clk) begin
    if (!rst_n) begin
        v_r <= 27'd0; d_r <= 27'd0; miq_r <= 16'd0;
    end else begin
        v_r   <= vv[26:0];
        d_r   <= vv[26:0] + k_r;
        miq_r <= miq_n >> 6;
    end
end

// 级1 的除法: num = V<<8, d = V+K -> 11 拍后 a_q8
wire [33:0] num_w = {7'b0, v_r} << 8;
wire [24:0] den_w = d_r[24:0];
wire [7:0]  a_q8;

alg_gf_div #(
    .NUMW(34), .DENW(25), .NQ(9)
) u_div (
    .clk(clk), .rst_n(rst_n),
    .in_num(num_w), .in_d(den_w),
    .out_a(a_q8)
);

// mI_q8 要等到 a_q8 那一拍(A+15): 从 A+4 起延迟 11 拍
reg [15:0] miq_sr [0:10];
integer mi;
always @(posedge clk) begin
    if (!rst_n) begin
        for (mi = 0; mi < 11; mi = mi + 1) miq_sr[mi] <= 16'd0;
    end else begin
        miq_sr[0] <= miq_r;
        for (mi = 1; mi < 11; mi = mi + 1) miq_sr[mi] <= miq_sr[mi-1];
    end
end

// b_q = (mI_q8*(256-a_q8) + 2^15) >> 16   (A+14 组合, A+15 寄存)
// A+15 -> A+16 再寄存一级: 旁路支路(av_sr[14])与标签流(u_lb1, C1=16)都在 A+16 有效,
// 导向支路必须同拍(否则 win2 会把 a/b 配到前一列的标签上, 整体错一列)。
wire [8:0]  nva  = 9'd256 - {1'b0, a_q8};
wire [24:0] bmul = miq_sr[10] * nva;
wire [24:0] bprod = bmul + 25'd32768;
reg [7:0]  a_q8d, b_q;               // A+15
reg [7:0]  a_gfd, b_gfd;             // A+16 -> 送 win2
always @(posedge clk) begin
    if (!rst_n) begin
        a_q8d <= 8'd0; b_q <= 8'd0;
        a_gfd <= 8'd0; b_gfd <= 8'd0;
    end else begin
        a_q8d <= a_q8;  b_q <= bprod[23:16];
        a_gfd <= a_q8d; b_gfd <= b_q;
    end
end

//--------------------------------------------------------------------------
// 级1 -> 级2: 标签流延迟 C1, 旁路值延迟 C1-1, 供 win2 当拍取用
//--------------------------------------------------------------------------
wire        d1_vs, d1_hs, d1_de;
wire [11:0] d1_x;
wire [12:0] d1_y;

alg_stream_delay #(.DW(1), .D(C1)) u_lb1 (
    .clk(clk), .rst_n(rst_n),
    .in_vs(w1_vs), .in_hs(w1_hs), .in_de(w1_de),
    .in_x(w1_x), .in_y(w1_y), .in_data(1'b0),
    .out_vs(d1_vs), .out_hs(d1_hs), .out_de(d1_de),
    .out_x(d1_x), .out_y(d1_y), .out_data()
);

// 非 GF 档的 a 通道 = r_aval (A+1), 延迟 15 拍到 A+16
reg [7:0] av_sr [0:14];
wire [7:0] av16 = av_sr[14];
integer ai;
always @(posedge clk) begin
    if (!rst_n) begin
        for (ai = 0; ai < 15; ai = ai + 1) av_sr[ai] <= 8'd0;
    end else begin
        av_sr[0] <= r_aval;
        for (ai = 1; ai < 15; ai = ai + 1) av_sr[ai] <= av_sr[ai-1];
    end
end

wire [7:0] a_in = (epf == 2'd2) ? a_gfd : av16;
wire [7:0] b_in = (epf == 2'd2) ? b_gfd : 8'd0;

//--------------------------------------------------------------------------
// 级2 窗: a 通道与 b 通道各一个 alg_win(N=6)
//--------------------------------------------------------------------------
wire        w2_vs, w2_hs, w2_de;
wire [11:0] w2_x;
wire [12:0] w2_y;
wire [287:0] win2;

alg_win #(
    .DW(8), .W(W), .VEXT(VEXT), .H(H), .N(6), .PAD_EDGE(1)
) u_win2 (
    .clk(clk), .rst_n(rst_n),
    .in_vs(d1_vs), .in_hs(d1_hs), .in_de(d1_de),
    .in_x(d1_x), .in_y(d1_y), .in_data(a_in),
    .out_vs(w2_vs), .out_hs(w2_hs), .out_de(w2_de),
    .out_x(w2_x), .out_y(w2_y), .win(win2)
);

wire        w3_vs, w3_hs, w3_de;
wire [11:0] w3_x;
wire [12:0] w3_y;
wire [287:0] win3;

alg_win #(
    .DW(8), .W(W), .VEXT(VEXT), .H(H), .N(6), .PAD_EDGE(1)
) u_win3 (
    .clk(clk), .rst_n(rst_n),
    .in_vs(d1_vs), .in_hs(d1_hs), .in_de(d1_de),
    .in_x(d1_x), .in_y(d1_y), .in_data(b_in),
    .out_vs(w3_vs), .out_hs(w3_hs), .out_de(w3_de),
    .out_x(w3_x), .out_y(w3_y), .win(win3)
);

// Sa/Sb: a/b 通道 6x6 窗和 (<= 9180, 14bit)
wire [13:0] sa0 = tp(win2,0,0)+tp(win2,0,1)+tp(win2,0,2)+tp(win2,0,3)+tp(win2,0,4)+tp(win2,0,5);
wire [13:0] sa1 = tp(win2,1,0)+tp(win2,1,1)+tp(win2,1,2)+tp(win2,1,3)+tp(win2,1,4)+tp(win2,1,5);
wire [13:0] sa2 = tp(win2,2,0)+tp(win2,2,1)+tp(win2,2,2)+tp(win2,2,3)+tp(win2,2,4)+tp(win2,2,5);
wire [13:0] sa3 = tp(win2,3,0)+tp(win2,3,1)+tp(win2,3,2)+tp(win2,3,3)+tp(win2,3,4)+tp(win2,3,5);
wire [13:0] sa4 = tp(win2,4,0)+tp(win2,4,1)+tp(win2,4,2)+tp(win2,4,3)+tp(win2,4,4)+tp(win2,4,5);
wire [13:0] sa5 = tp(win2,5,0)+tp(win2,5,1)+tp(win2,5,2)+tp(win2,5,3)+tp(win2,5,4)+tp(win2,5,5);
wire [13:0] sb0 = tp(win3,0,0)+tp(win3,0,1)+tp(win3,0,2)+tp(win3,0,3)+tp(win3,0,4)+tp(win3,0,5);
wire [13:0] sb1 = tp(win3,1,0)+tp(win3,1,1)+tp(win3,1,2)+tp(win3,1,3)+tp(win3,1,4)+tp(win3,1,5);
wire [13:0] sb2 = tp(win3,2,0)+tp(win3,2,1)+tp(win3,2,2)+tp(win3,2,3)+tp(win3,2,4)+tp(win3,2,5);
wire [13:0] sb3 = tp(win3,3,0)+tp(win3,3,1)+tp(win3,3,2)+tp(win3,3,3)+tp(win3,3,4)+tp(win3,3,5);
wire [13:0] sb4 = tp(win3,4,0)+tp(win3,4,1)+tp(win3,4,2)+tp(win3,4,3)+tp(win3,4,4)+tp(win3,4,5);
wire [13:0] sb5 = tp(win3,5,0)+tp(win3,5,1)+tp(win3,5,2)+tp(win3,5,3)+tp(win3,5,4)+tp(win3,5,5);
wire [14:0] sa = ((sa0+sa1)+(sa2+sa3))+(sa4+sa5);
wire [14:0] sb = ((sb0+sb1)+(sb2+sb3))+(sb4+sb5);

// I(x,y) 参考值: 窗1 中心延迟 19 拍(A+1 -> A+19)
reg [7:0] cen_sr [0:17];
wire [7:0] iref = cen_sr[17];
integer ci;
always @(posedge clk) begin
    if (!rst_n) begin
        for (ci = 0; ci < 18; ci = ci + 1) cen_sr[ci] <= 8'd0;
    end else begin
        cen_sr[0] <= r_cen;
        for (ci = 1; ci < 18; ci = ci + 1) cen_sr[ci] <= cen_sr[ci-1];
    end
end

// 级2: A+20 prod/rsb, A+21 w, A+22 q (与 rtl_model 逐位一致)
reg [21:0] pr_r;
reg [13:0] sb_r;
wire [21:0] prod = sa[13:0] * iref;               // <= 2340900
always @(posedge clk) begin
    if (!rst_n) begin pr_r <= 22'd0; sb_r <= 14'd0; end
    else        begin pr_r <= prod;  sb_r <= sb[13:0]; end
end

reg [14:0] w_r;                                   // <= 18326
always @(posedge clk) begin
    if (!rst_n) w_r <= 15'd0;
    else        w_r <= ((pr_r + 22'd128) >> 8) + {1'b0, sb_r};
end

wire [23:0] qmul = (w_r * 15'd455) + 24'd8192;
wire [7:0]  q_c  = (qmul[23:14] > 10'd255) ? 8'd255 : qmul[21:14];

// 非 GF 档: 输出 = 窗2 的中心锚点(A+19)。GF 支路是 "pr_r/w_r 2 级 + out_data 1 级"
// 到 A+22, 旁路支路必须同拍: bp_sr 只能 2 级(否则标签比数据快 1 拍 -> 整体错一列)。
reg [7:0] bp_sr [0:1];
wire [7:0] bpx = bp_sr[1];
integer bi;
always @(posedge clk) begin
    if (!rst_n) begin
        for (bi = 0; bi < 2; bi = bi + 1) bp_sr[bi] <= 8'd0;
    end else begin
        bp_sr[0] <= tp(win2,3,3);
        for (bi = 1; bi < 2; bi = bi + 1) bp_sr[bi] <= bp_sr[bi-1];
    end
end

always @(posedge clk) begin
    if (!rst_n) out_data <= 8'd0;
    else        out_data <= (epf == 2'd2) ? q_c : bpx;
end

//--------------------------------------------------------------------------
// 输出时序/坐标: 与 out_data(A+22) 同拍 = 窗2 输出(A+19) 延迟 3 拍
//--------------------------------------------------------------------------
wire        o_vs, o_hs, o_de;
wire [11:0] o_x;
wire [12:0] o_y;

alg_stream_delay #(.DW(1), .D(3)) u_lb2 (
    .clk(clk), .rst_n(rst_n),
    .in_vs(w2_vs), .in_hs(w2_hs), .in_de(w2_de),
    .in_x(w2_x), .in_y(w2_y), .in_data(1'b0),
    .out_vs(o_vs), .out_hs(o_hs), .out_de(o_de),
    .out_x(o_x), .out_y(o_y), .out_data()
);

assign out_vs      = o_vs;
assign out_hs      = o_hs;
assign out_de_full = o_de;
assign out_de      = o_de & (o_y < H);
assign out_x       = o_x;
assign out_y       = o_y;

endmodule

//=============================================================================
// alg_median3.v -- 赛题4 高阶① 3x3 中值滤波(19 比较器并行排序网络)
//
//  算法来源: FPGA-Python/edge_pipeline.py :: median3x3() 的硬件等价网络
//    第 1 级: 3 行各自 sort3                     (9 个比较器)
//    第 2 级: lo = max(3 个"行最小")             (2)
//            hi = min(3 个"行最大")             (2)
//            md = med3(3 个"行中位")            (3)
//    第 3 级: median = med3(lo, md, hi)          (3)
//  合计 19 个 2 输入比较器; 纯组合 + 1 级输出寄存, 无除法器/乘法器。
//
//  en = 0 时输出窗口中心像素(旁路), 但流水线延迟保持 4 拍不变,
//  这样运行时切换 MEDIAN 开关不会让画面位置跳动。
//
//  流水线延迟: 输入 -> out_de / out_data = 4 拍 (窗口 3 + 寄存 1)
//=============================================================================

module alg_median3 #(
    parameter integer W    = 1280,
    parameter integer VEXT = 16,
    parameter integer H    = 720
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,          // 1 = 中值滤波, 0 = 旁路(窗中心)
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,
    input  wire [11:0] in_x,
    input  wire [12:0] in_y,
    input  wire [7:0]  in_data,
    output wire        out_vs,
    output wire        out_hs,
    output wire        out_de_full, // 扩展光栅流有效(送下一级)
    output wire        out_de,      // 显示/统计用(已按 y<H 门控)
    output wire [11:0] out_x,
    output wire [12:0] out_y,
    output reg  [7:0]  out_data
);

wire        w_vs, w_hs, w_de;
wire [11:0] w_x;
wire [12:0] w_y;
wire [71:0] win;

// EDGE 边界(复制边缘), 与 Python np.pad(mode="edge") 一致
alg_win #(
    .DW(8), .W(W), .VEXT(VEXT), .H(H), .N(3), .PAD_EDGE(1)
) u_win (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_x(in_x), .in_y(in_y), .in_data(in_data),
    .out_vs(w_vs), .out_hs(w_hs), .out_de(w_de),
    .out_x(w_x), .out_y(w_y), .win(win)
);

// win[(i*N+j)*8] : i=0 最上行, j=0 最左列
wire [7:0] p00 = win[7:0];
wire [7:0] p01 = win[15:8];
wire [7:0] p02 = win[23:16];
wire [7:0] p10 = win[31:24];
wire [7:0] p11 = win[39:32];
wire [7:0] p12 = win[47:40];
wire [7:0] p20 = win[55:48];
wire [7:0] p21 = win[63:56];
wire [7:0] p22 = win[71:64];

function [23:0] sort3;          // -> {max, mid, min}
    input [7:0] a, b, c;
    reg   [7:0] lo, hi, mn, mx, md;
    begin
        lo = (a < b) ? a : b;
        hi = (a < b) ? b : a;
        mn = (lo < c) ? lo : c;
        mx = (hi > c) ? hi : c;
        md = (hi > c) ? ((lo > c) ? lo : c) : hi;
        sort3 = {mx, md, mn};
    end
endfunction

function [7:0] med3;            // 3 个数的中位
    input [7:0] a, b, c;
    reg   [23:0] s;
    begin
        s = sort3(a, b, c);
        med3 = s[15:8];
    end
endfunction

function [7:0] max3;
    input [7:0] a, b, c;
    begin
        max3 = (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c);
    end
endfunction

function [7:0] min3;
    input [7:0] a, b, c;
    begin
        min3 = (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c);
    end
endfunction

wire [23:0] r0 = sort3(p00, p01, p02);
wire [23:0] r1 = sort3(p10, p11, p12);
wire [23:0] r2 = sort3(p20, p21, p22);

wire [7:0] lo = max3(r0[7:0],   r1[7:0],   r2[7:0]);     // max of mins
wire [7:0] hi = min3(r0[23:16], r1[23:16], r2[23:16]);   // min of maxes
wire [7:0] md = med3(r0[15:8],  r1[15:8],  r2[15:8]);    // med of meds
wire [7:0] med = med3(lo, md, hi);

always @(posedge clk) begin
    if (!rst_n) out_data <= 8'd0;
    else        out_data <= en ? med : p11;
end

// 时序/坐标与 out_data(4 拍) 必须同拍: 窗口 3 拍 + 输出寄存 1 拍
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

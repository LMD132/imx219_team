//=============================================================================
// alg_gauss3.v -- 赛题4 EPF=1: 3x3 整数高斯 [1,2,1;2,4,2;1,2,1]/16
//
//  算法来源: FPGA-Python/edge_pipeline.py :: gaussian3x3()
//            (cv2.filter2D 用浮点核 [1,2,1]^2/16, 再 .astype(uint8) 截断;
//             非负值截断 == 右移向下取整, 所以整数等价 = sum >> 4)
//  live_tune.py 的 EPF 滑条: 0=关 1=本模块 2=导向滤波(alg_gf.v)
//
//  硬件: 系数 1/2/4 全是移位加法, 无乘法器/除法器。
//  流水线延迟: 输入 -> out_de / out_data = 5 拍 (窗口 3 + 行加权 1 + 输出寄存 1)
//  en = 0 时输出窗口中心像素(旁路), 延迟仍为 5 拍(与 alg_gauss5 同一约定)。
//=============================================================================

module alg_gauss3 #(
    parameter integer W    = 1280,
    parameter integer VEXT = 16,
    parameter integer H    = 720
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
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

wire        w_vs, w_hs, w_de;
wire [11:0] w_x;
wire [12:0] w_y;
wire [71:0] win;

alg_win #(
    .DW(8), .W(W), .VEXT(VEXT), .H(H), .N(3), .PAD_EDGE(1)
) u_win (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_x(in_x), .in_y(in_y), .in_data(in_data),
    .out_vs(w_vs), .out_hs(w_hs), .out_de(w_de),
    .out_x(w_x), .out_y(w_y), .win(win)
);

function [7:0] pix;             // win[(i*3+j)*8 +: 8]
    input [71:0] w;
    input integer i;
    input integer j;
    begin
        pix = w[(i*3 + j)*8 +: 8];
    end
endfunction

// 行加权: [1 2 1] * 行  (<= 255*4 = 1020, 10bit)
wire [9:0] rs0 = {2'b0, pix(win,0,0)} + {1'b0, pix(win,0,1), 1'b0} + {2'b0, pix(win,0,2)};
wire [9:0] rs1 = {2'b0, pix(win,1,0)} + {1'b0, pix(win,1,1), 1'b0} + {2'b0, pix(win,1,2)};
wire [9:0] rs2 = {2'b0, pix(win,2,0)} + {1'b0, pix(win,2,1), 1'b0} + {2'b0, pix(win,2,2)};

reg [9:0] r0, r1, r2;
reg [7:0] cen1;
always @(posedge clk) begin
    if (!rst_n) begin
        r0 <= 10'd0; r1 <= 10'd0; r2 <= 10'd0; cen1 <= 8'd0;
    end else begin
        r0 <= rs0; r1 <= rs1; r2 <= rs2;
        cen1 <= pix(win,1,1);
    end
end

// 列加权 [1 2 1] -> 总和 <= 255*16 = 4080 (12bit), out = sum >> 4
wire [11:0] tot = {2'b0, r0} + {1'b0, r1, 1'b0} + {2'b0, r2};
wire [7:0]  g3  = tot[11:4];

always @(posedge clk) begin
    if (!rst_n) begin
        out_data <= 8'd0;
    end else begin
        out_data <= en ? g3 : cen1;
    end
end

// 时序/坐标与 out_data(5 拍) 必须同拍: 窗口 3 + 行加权 1 + 输出寄存 1
wire        c_vs, c_hs, c_de;
wire [11:0] c_x;
wire [12:0] c_y;
alg_stream_delay #(.DW(1), .D(2)) u_cdly (
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

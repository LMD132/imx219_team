//=============================================================================
// alg_sobel3.v -- 赛题4 基础③ 3x3 Sobel 梯度(全量程) + 方向量化
//
//  Gx = (p02 + 2p12 + p22) - (p00 + 2p10 + p20)
//  Gy = (p20 + 2p21 + p22) - (p00 + 2p01 + p02)
//  mag = |Gx| + |Gy|            // 0..2040, 11bit 全量程, NMS 前不截 255
//
//  方向量化(整数交叉相乘, 与 Python dir_class() 逐位一致):
//      q0  : |Gy|*4096 <= |Gx|*1697     -> 0   (左右比较)
//      q90 : |Gx|*4096 <= |Gy|*1697     -> 90  (上下比较)
//      其余: sign(Gx)==sign(Gy) -> 45, 否则 135
//  RTL 用 2bit 编码: 0->0, 90->1, 45->2, 135->3
//
//  流水线延迟: 输入 -> out_de = 4 拍 (窗口 3 + 寄存 1)
//=============================================================================

module alg_sobel3 #(
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
    input  wire [7:0]  in_data,
    output reg         out_vs,
    output reg         out_hs,
    output reg         out_de_full,
    output wire        out_de,
    output reg  [11:0] out_x,
    output reg  [12:0] out_y,
    output reg  [10:0] out_mag,
    output reg  [1:0]  out_dir,
    output reg  signed [11:0] out_gx,
    output reg  signed [11:0] out_gy
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

wire [7:0] p00 = win[7:0];
wire [7:0] p01 = win[15:8];
wire [7:0] p02 = win[23:16];
wire [7:0] p10 = win[31:24];
wire [7:0] p11 = win[39:32];
wire [7:0] p12 = win[47:40];
wire [7:0] p20 = win[55:48];
wire [7:0] p21 = win[63:56];
wire [7:0] p22 = win[71:64];

wire [10:0] gxp = {3'b0, p02} + {2'b0, p12, 1'b0} + {3'b0, p22};
wire [10:0] gxn = {3'b0, p00} + {2'b0, p10, 1'b0} + {3'b0, p20};
wire [10:0] gyp = {3'b0, p20} + {2'b0, p21, 1'b0} + {3'b0, p22};
wire [10:0] gyn = {3'b0, p00} + {2'b0, p01, 1'b0} + {3'b0, p02};

wire [10:0] ax = (gxp >= gxn) ? (gxp - gxn) : (gxn - gxp);
wire [10:0] ay = (gyp >= gyn) ? (gyp - gyn) : (gyn - gyp);
wire        sx = (gxn > gxp);      // 1 -> Gx < 0
wire        sy = (gyn > gyp);      // 1 -> Gy < 0
wire [10:0] mag = ax + ay;         // <= 2040

// |Gy|<<12 与 |Gx|*1697  (1697 = 1024+512+128+32+1)
wire [22:0] ax1697 = ({12'b0, ax} << 10) + ({12'b0, ax} << 9)
                   + ({12'b0, ax} << 7)  + ({12'b0, ax} << 5) + {12'b0, ax};
wire [22:0] ay1697 = ({12'b0, ay} << 10) + ({12'b0, ay} << 9)
                   + ({12'b0, ay} << 7)  + ({12'b0, ay} << 5) + {12'b0, ay};
wire [22:0] ax4096 = {ax, 12'b0};
wire [22:0] ay4096 = {ay, 12'b0};

wire        q0  = (ay4096 <= ax1697);
wire        q90 = (ax4096 <= ay1697);
wire        same = (sx == sy);
wire [1:0]  dir = q0 ? 2'd0 : (q90 ? 2'd1 : (same ? 2'd2 : 2'd3));

wire signed [11:0] gx_s = {1'b0, gxp} - {1'b0, gxn};
wire signed [11:0] gy_s = {1'b0, gyp} - {1'b0, gyn};

always @(posedge clk) begin
    if (!rst_n) begin
        out_vs <= 1'b0; out_hs <= 1'b0; out_de_full <= 1'b0;
        out_x <= 12'd0; out_y <= 13'd0;
        out_mag <= 11'd0; out_dir <= 2'd0;
        out_gx <= 12'sd0; out_gy <= 12'sd0;
    end else begin
        out_vs <= w_vs; out_hs <= w_hs; out_de_full <= w_de;
        out_x <= w_x; out_y <= w_y;
        out_mag <= mag; out_dir <= dir;
        out_gx <= gx_s; out_gy <= gy_s;
    end
end

assign out_de = out_de_full & (out_y < H);

endmodule

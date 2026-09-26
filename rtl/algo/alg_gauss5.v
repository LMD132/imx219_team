//=============================================================================
// alg_gauss5.v -- 赛题4 高阶④ Canny 前置 5x5 整数高斯
//
//  内核(来自 FPGA-Python/edge_pipeline.py :: GAUSS5X5_K, 总和 1010):
//      32  38  40  38  32
//      38  45  47  45  38
//      40  47  50  47  40
//      38  45  47  45  38
//      32  38  40  38  32
//  输出: out = (sum >> 10) + ((sum >> 9) & 1)      // 四舍五入
//
//  硬件: 系数乘 = 移位加法(无乘法器/除法器)
//        第 1 级: 5 条行加权和 (<= 255*180 = 45900, 16bit) 打拍
//        第 2 级: 5 行相加 (<= 255*1010 = 257550, 18bit) + 移位舍入 打拍
//
//  en = 0 时输出窗口中心像素(旁路), 延迟仍为 5 拍。
//  流水线延迟: 输入 -> out_de / out_data = 5 拍 (窗口 3 + 乘加 1 + 舍入 1)
//=============================================================================

module alg_gauss5 #(
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

wire         w_vs, w_hs, w_de;
wire [11:0]  w_x;
wire [12:0]  w_y;
wire [199:0] win;

alg_win #(
    .DW(8), .W(W), .VEXT(VEXT), .H(H), .N(5), .PAD_EDGE(1)
) u_win (
    .clk(clk), .rst_n(rst_n),
    .in_vs(in_vs), .in_hs(in_hs), .in_de(in_de),
    .in_x(in_x), .in_y(in_y), .in_data(in_data),
    .out_vs(w_vs), .out_hs(w_hs), .out_de(w_de),
    .out_x(w_x), .out_y(w_y), .win(win)
);

function [7:0] pix;             // win[(i*5+j)*8 +: 8]
    input [199:0] w;
    input integer i;
    input integer j;
    begin
        pix = w[(i*5 + j)*8 +: 8];
    end
endfunction

function [15:0] kmul;           // 系数: 0->32 1->38 2->40 3->45 4->47 5->50
    input [7:0] x;
    input [2:0] sel;
    reg   [15:0] y;
    begin
        case (sel)
            3'd0:    y = (x << 5);
            3'd1:    y = (x << 5) + (x << 2) + (x << 1);
            3'd2:    y = (x << 5) + (x << 3);
            3'd3:    y = (x << 5) + (x << 3) + (x << 2) + x;
            3'd4:    y = (x << 5) + (x << 3) + (x << 2) + (x << 1) + x;
            default: y = (x << 5) + (x << 4) + (x << 1);
        endcase
        kmul = y;
    end
endfunction

wire [15:0] rs0 = kmul(pix(win,0,0),3'd0) + kmul(pix(win,0,1),3'd1)
                + kmul(pix(win,0,2),3'd2) + kmul(pix(win,0,3),3'd1)
                + kmul(pix(win,0,4),3'd0);
wire [15:0] rs1 = kmul(pix(win,1,0),3'd1) + kmul(pix(win,1,1),3'd3)
                + kmul(pix(win,1,2),3'd4) + kmul(pix(win,1,3),3'd3)
                + kmul(pix(win,1,4),3'd1);
wire [15:0] rs2 = kmul(pix(win,2,0),3'd2) + kmul(pix(win,2,1),3'd4)
                + kmul(pix(win,2,2),3'd5) + kmul(pix(win,2,3),3'd4)
                + kmul(pix(win,2,4),3'd2);
wire [15:0] rs3 = kmul(pix(win,3,0),3'd1) + kmul(pix(win,3,1),3'd3)
                + kmul(pix(win,3,2),3'd4) + kmul(pix(win,3,3),3'd3)
                + kmul(pix(win,3,4),3'd1);
wire [15:0] rs4 = kmul(pix(win,4,0),3'd0) + kmul(pix(win,4,1),3'd1)
                + kmul(pix(win,4,2),3'd2) + kmul(pix(win,4,3),3'd1)
                + kmul(pix(win,4,4),3'd0);

reg [15:0] r0, r1, r2, r3, r4;
reg [7:0]  cen1;
always @(posedge clk) begin
    if (!rst_n) begin
        r0 <= 0; r1 <= 0; r2 <= 0; r3 <= 0; r4 <= 0; cen1 <= 8'd0;
    end else begin
        r0 <= rs0; r1 <= rs1; r2 <= rs2; r3 <= rs3; r4 <= rs4;
        cen1 <= pix(win,2,2);
    end
end

wire [17:0] tot = {2'b0, r0} + {2'b0, r1} + {2'b0, r2}
                + {2'b0, r3} + {2'b0, r4};
wire [7:0]  g5  = tot[17:10] + {7'b0, tot[9]};

always @(posedge clk) begin
    if (!rst_n) begin
        out_data <= 8'd0;
    end else begin
        out_data <= en ? g5 : cen1;
    end
end

// 时序/坐标与 out_data(5 拍) 必须同拍: 窗口 3 + 乘加 1 + 舍入 1
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

//=============================================================================
// alg_disp.v -- 赛题4 基础④ 显示合成(分屏 / 彩色叠加)
//
//  mode=0 (默认, 同视野左右分屏):
//      屏幕左半 = 原始灰度, 右半 = 边缘结果, 两边都是"同一视野"。
//      做法: 把当前行按 2:1 水平抽取后写进两块行缓存(ping-pong),
//            屏幕左半读 [0,HALF) 显示灰度、右半读 [0,HALF) 显示边缘。
//            ==> 每一半都能看到完整画面(水平压缩 2:1)，左右严格同视野。
//  mode=1 (彩色叠加): 彩色原图(或灰度) + 红边叠加
//  mode=2 (半视野分区): 左半屏显示画面左半灰度, 右半屏显示画面右半边缘
//  mode=3 (纯边缘): 全屏二值边缘
//
//  三个输入 gray/edge/rgb 在"内容"上已经是同一个源像素(见 alg_top 的对齐),
//  本模块只做屏幕位置的重新组织。
//
//  行缓存用 simple_dual_port_ram(EFX_RAM10, 640x8bit=5120bit),
//  读写地址按 xc 直接给出, 数据 2 拍后有效 ==> 显示延迟固定 3 拍。
//=============================================================================

module alg_disp #(
    parameter integer W    = 1280,
    parameter integer HALF = 640,
    parameter integer AW   = 10          // $clog2(HALF)
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,
    input  wire [7:0]  in_gray,
    input  wire [7:0]  in_edge,
    input  wire [23:0] in_rgb,        // {R,G,B}
    input  wire [1:0]  mode,
    input  wire        ov_color,
    output reg         out_vs,
    output reg         out_hs,
    output reg         out_de,
    output reg  [7:0]  out_r,
    output reg  [7:0]  out_g,
    output reg  [7:0]  out_b
);

localparam integer XW = 12;

//--------------------------------------------------------------------------
// 1) 行内像素计数 + 行缓存 bank 乒乓(行尾翻转, 保证整行读写 bank 稳定)
//--------------------------------------------------------------------------
reg  [XW-1:0] xc;
reg           wr_bank;

always @(posedge clk) begin
    if (!rst_n) begin
        xc <= {XW{1'b0}};
        wr_bank <= 1'b0;
    end else begin
        if (!in_de) xc <= {XW{1'b0}};
        else        xc <= (xc == (W-1)) ? {XW{1'b0}} : (xc + 1'b1);
        if (in_de && (xc == (W-1))) wr_bank <= ~wr_bank;
    end
end

wire          we     = in_de & ~xc[0] & (xc < W);
wire [AW-1:0] waddr  = xc[AW:1];
wire [XW-1:0] rdiff  = xc - HALF;
wire [AW-1:0] raddr  = (xc < HALF) ? xc[AW-1:0] : rdiff[AW-1:0];
wire          r_full = (xc < HALF);

//--------------------------------------------------------------------------
// 2) 行缓存: 灰度 2 块 + 边缘 2 块
//--------------------------------------------------------------------------
wire [7:0] gr_b0, gr_b1, er_b0, er_b1;

simple_dual_port_ram #(
    .DATA_WIDTH(8), .ADDR_WIDTH(AW), .OUTPUT_REG("TRUE"), .RAM_INIT_FILE("")
) u_g0 (
    .wdata(in_gray), .waddr(waddr), .we(we & ~wr_bank), .wclk(clk),
    .raddr(raddr), .re(in_de &  wr_bank), .rclk(clk), .rdata(gr_b0)
);
simple_dual_port_ram #(
    .DATA_WIDTH(8), .ADDR_WIDTH(AW), .OUTPUT_REG("TRUE"), .RAM_INIT_FILE("")
) u_g1 (
    .wdata(in_gray), .waddr(waddr), .we(we &  wr_bank), .wclk(clk),
    .raddr(raddr), .re(in_de & ~wr_bank), .rclk(clk), .rdata(gr_b1)
);
simple_dual_port_ram #(
    .DATA_WIDTH(8), .ADDR_WIDTH(AW), .OUTPUT_REG("TRUE"), .RAM_INIT_FILE("")
) u_e0 (
    .wdata(in_edge), .waddr(waddr), .we(we & ~wr_bank), .wclk(clk),
    .raddr(raddr), .re(in_de &  wr_bank), .rclk(clk), .rdata(er_b0)
);
simple_dual_port_ram #(
    .DATA_WIDTH(8), .ADDR_WIDTH(AW), .OUTPUT_REG("TRUE"), .RAM_INIT_FILE("")
) u_e1 (
    .wdata(in_edge), .waddr(waddr), .we(we &  wr_bank), .wclk(clk),
    .raddr(raddr), .re(in_de & ~wr_bank), .rclk(clk), .rdata(er_b1)
);

// 读 bank = ~wr_bank (上一行写的那块)
wire [7:0] gray_rd = wr_bank ? gr_b0 : gr_b1;
wire [7:0] edge_rd = wr_bank ? er_b0 : er_b1;

//--------------------------------------------------------------------------
// 3) 2 拍对齐寄存器(RAM 读延迟 2 拍)
//--------------------------------------------------------------------------
reg          s1_de, s1_vs, s1_hs, s1_full;
reg [XW-1:0] s1_x;
reg [7:0]    s1_g, s1_e;
reg [23:0]   s1_rgb;

reg          s2_de, s2_vs, s2_hs, s2_full;
reg [XW-1:0] s2_x;
reg [7:0]    s2_g, s2_e;
reg [23:0]   s2_rgb;

always @(posedge clk) begin
    if (!rst_n) begin
        s1_de <= 0; s1_vs <= 0; s1_hs <= 0; s1_full <= 0; s1_x <= 0;
        s1_g <= 0; s1_e <= 0; s1_rgb <= 24'd0;
        s2_de <= 0; s2_vs <= 0; s2_hs <= 0; s2_full <= 0; s2_x <= 0;
        s2_g <= 0; s2_e <= 0; s2_rgb <= 24'd0;
    end else begin
        s1_de <= in_de; s1_vs <= in_vs; s1_hs <= in_hs;
        s1_full <= r_full; s1_x <= xc;
        s1_g <= in_gray; s1_e <= in_edge; s1_rgb <= in_rgb;

        s2_de <= s1_de; s2_vs <= s1_vs; s2_hs <= s1_hs;
        s2_full <= s1_full; s2_x <= s1_x;
        s2_g <= s1_g; s2_e <= s1_e; s2_rgb <= s1_rgb;
    end
end

//--------------------------------------------------------------------------
// 4) 输出的 1 拍: 像素合成
//--------------------------------------------------------------------------
wire [7:0] g_full = s2_g;          // 全屏 1:1 灰度(与 s2_x 对齐)
wire [7:0] e_full = s2_e;          // 全屏 1:1 边缘
wire [7:0] g_half = s2_full ? s2_g : s2_e;   // 半视野分区

wire [7:0] m0_r = s2_full ? edge_rd : gray_rd;   // 同视野分屏
wire [7:0] m0_g = s2_full ? edge_rd : gray_rd;
wire [7:0] m0_b = s2_full ? edge_rd : gray_rd;

wire [7:0] ov_base_r = ov_color ? s2_rgb[23:16] : g_full;
wire [7:0] ov_base_g = ov_color ? s2_rgb[15:8]  : g_full;
wire [7:0] ov_base_b = ov_color ? s2_rgb[7:0]   : g_full;

wire [7:0] m1_r = (e_full != 8'd0) ? 8'hFF : ov_base_r;
wire [7:0] m1_g = (e_full != 8'd0) ? 8'h00 : ov_base_g;
wire [7:0] m1_b = (e_full != 8'd0) ? 8'h00 : ov_base_b;

always @(posedge clk) begin
    if (!rst_n) begin
        out_vs <= 1'b0; out_hs <= 1'b0; out_de <= 1'b0;
        out_r <= 8'd0; out_g <= 8'd0; out_b <= 8'd0;
    end else begin
        out_vs <= s2_vs;
        out_hs <= s2_hs;
        out_de <= s2_de;
        case (mode)
            2'd0: begin out_r <= m0_r;        out_g <= m0_g;        out_b <= m0_b;        end
            2'd1: begin out_r <= m1_r;        out_g <= m1_g;        out_b <= m1_b;        end
            2'd2: begin out_r <= g_half;      out_g <= g_half;      out_b <= g_half;      end
            default: begin
                out_r <= e_full; out_g <= e_full; out_b <= e_full;
            end
        endcase
    end
end

endmodule

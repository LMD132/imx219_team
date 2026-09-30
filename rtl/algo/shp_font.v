//=============================================================================
// shp_font.v -- 赛题4 形状识别: 16x16 中文点阵字库 ROM(1 块 BRAM)
//
// 内容由 tools/gen_font.py 生成到工程根目录 shp_font.mem (256 字 x 16bit):
//   字序号 0..8 = 圆 形 矩 三 角 十 字 未 知, 9..15 填 0000(补满 256 行)
//   地址 = 字序号*16 + 行号(行序从上到下); 数据 bit15 = 最左像素, 1 = 笔画
//   标签组合(每标签 2 个字): 圆形[0,1] 矩形[2,1] 三角[3,4] 十字[5,6] 未知[7,8]
//
// 读延迟 = 1 拍(OUTPUT_REG="FALSE": 地址在第 k 拍给出, 第 k+1 拍 dout 有效)。
// 这个"1 拍"已经算进 shp_overlay 的流水里(见其头注释), 不要随便改。
//=============================================================================

module shp_font (
    input  wire        clk,
    input  wire [7:0]  addr,     // 字序号*16 + 行号
    output wire [15:0] dout      // 该行 16 个像素, MSB = 最左
);

    simple_dual_port_ram #(
        .DATA_WIDTH(16), .ADDR_WIDTH(8), .OUTPUT_REG("FALSE"),
        .RAM_INIT_FILE("shp_font.mem"), .RAM_INIT_RADIX("HEX")
    ) u_rom (
        .wdata(16'd0), .waddr(8'd0), .we(1'b0), .wclk(clk),
        .raddr(addr),  .re(1'b1),   .rclk(clk), .rdata(dout)
    );

endmodule

///////////////////////////////////////////////////////////////////////////////
// line_buffer.v — 行缓存(简单双口 BRAM: 一个写口 + 一个独立读口)
// 输入像素流(we 使能), 输出"上一行同一列"像素, 与输入同拍有效。
// 原理: 环形深度 DEPTH, 上一行同列 = 同一地址的写入前旧值;
//       读地址提前一拍(raddr_q <= next_waddr), 抵消 BRAM 一拍读延迟,
//       故 din 写入 P(r,c) 的当拍, dout = P(r-1,c)。
// 多级串联: 两级 = 延迟 2 行。we 仅在有效行像素期间为高。
///////////////////////////////////////////////////////////////////////////////
module tip_line_buffer #(
    parameter W     = 8,
    parameter DEPTH = 1280
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             we,          // 写入使能(=像素有效)
    input  wire [W-1:0]     din,
    output wire [W-1:0]     dout         // 上一行同列(与 din 同拍)
);
    // 地址位宽(三元链, 覆盖常见行宽)
    localparam AW =
        (DEPTH <=    2) ? 1  :
        (DEPTH <=    4) ? 2  :
        (DEPTH <=    8) ? 3  :
        (DEPTH <=   16) ? 4  :
        (DEPTH <=   32) ? 5  :
        (DEPTH <=   64) ? 6  :
        (DEPTH <=  128) ? 7  :
        (DEPTH <=  256) ? 8  :
        (DEPTH <=  512) ? 9  :
        (DEPTH <= 1024) ? 10 :
        (DEPTH <= 2048) ? 11 : 12;

    reg [W-1:0]  mem [0:DEPTH-1];
    reg [AW-1:0] waddr;
    reg [AW-1:0] raddr_q;

    wire [AW-1:0] next_w = (waddr == DEPTH-1) ? {AW{1'b0}} : waddr + 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            waddr   <= {AW{1'b0}};
            raddr_q <= (DEPTH >= 2) ? {{(AW-1){1'b0}}, 1'b1} : {AW{1'b0}};
        end else if (we) begin
            mem[waddr] <= din;     // 写口
            waddr      <= next_w;
            raddr_q    <= next_w;  // 读地址提前一拍 -> 当拍读出上一行同列旧值
        end
    end

    assign dout = mem[raddr_q];    // 读口(独立)
endmodule

///////////////////////////////////////////////////////////////////////////////
// line_delay_n.v — 行级延迟(BRAM 实现), 替代"长 delay_n 移位链"
// 把 N 拍延迟拆成: NLINES = N/DEPTH 个整行(用 tip_line_buffer 级联, 进 BRAM)
//                 + NREM   = N%DEPTH 拍零头(用 delay_n, 仅几拍, 不爆 SRL)。
// we: 像素有效使能(=该路径 de), 仅有效像素推进行缓存, 消隐期不写。
// 例: N=7*1280+7 -> 7 级行缓存 + 7 拍; N=1281 -> 1 级 + 1 拍。
///////////////////////////////////////////////////////////////////////////////
module line_delay_n #(
    parameter WIDTH = 8,
    parameter DEPTH = 1280,
    parameter N     = 1281
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             we,
    input  wire [WIDTH-1:0] din,
    output wire [WIDTH-1:0] dout
);
    localparam NLINES = N / DEPTH;
    localparam NREM   = N - NLINES*DEPTH;

    // 各级抽头: tap[0]=din, tap[k]=延迟 k 整行
    wire [WIDTH-1:0] tap [0:NLINES];
    assign tap[0] = din;

    genvar i;
    generate
        for (i = 0; i < NLINES; i = i + 1) begin : g_line
            tip_line_buffer #(.W(WIDTH), .DEPTH(DEPTH)) u_lb (
                .clk(clk), .rst_n(rst_n), .we(we),
                .din(tap[i]), .dout(tap[i+1]));
        end
    endgenerate

    // 零头(列方向几拍)
    delay_n #(.N(NREM), .W(WIDTH)) u_rem (
        .clk(clk), .din(tap[NLINES]), .dout(dout));
endmodule

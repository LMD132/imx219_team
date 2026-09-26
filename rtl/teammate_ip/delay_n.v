///////////////////////////////////////////////////////////////////////////////
// delay_n.v — 通用打拍器(移位寄存器链)
// 用于把 de/hs/vs 和旁路数据对齐到流水线某一级的延迟。
// N=0 时直通。Verilog-2001 可综合。
///////////////////////////////////////////////////////////////////////////////
module delay_n #(
    parameter N = 4,   // 打拍数
    parameter W = 1    // 位宽
)(
    input  wire             clk,
    input  wire [W-1:0]     din,
    output wire [W-1:0]     dout
);
    generate
        if (N == 0) begin : bypass
            assign dout = din;
        end else begin : chain
            reg [W-1:0] sr [0:N-1];
            integer i;
            always @(posedge clk) begin
                sr[0] <= din;
                for (i = 1; i < N; i = i + 1)
                    sr[i] <= sr[i-1];
            end
            assign dout = sr[N-1];
        end
    endgenerate
endmodule

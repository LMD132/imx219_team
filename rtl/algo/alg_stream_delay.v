//=============================================================================
// alg_stream_delay.v -- 赛题4  视频流对齐延迟(D 拍)
//
//  把整条像素流 {vs,hs,de,x,y,data} 延迟 D 个时钟。
//  用途:
//    把不需要的分支(非 CANNY 档的 mag)延迟到与 NMS 输出同拍, 便于用 mux 换档。
//      当前例化: u_magdly, DW=11, D=4。
//  注: 显示支路的对齐已改由 alg_vdisp 的行缓存方案承担(见 alg_vdisp.v);
//      用本模块整体延迟彩色支路并不能修正 dsp 标签与屏幕坐标的 7 像素偏移。
//
//  纯移位寄存器, 无 BRAM; 每拍无条件移位, 因此行/场时序随数据一起搬移,
//  不会累积相位误差。
//=============================================================================

module alg_stream_delay #(
    parameter integer DW = 8,
    parameter integer D  = 1
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          in_vs,
    input  wire          in_hs,
    input  wire          in_de,
    input  wire [11:0]   in_x,
    input  wire [12:0]   in_y,
    input  wire [DW-1:0] in_data,
    output wire          out_vs,
    output wire          out_hs,
    output wire          out_de,
    output wire [11:0]   out_x,
    output wire [12:0]   out_y,
    output wire [DW-1:0] out_data
);

localparam integer PW = DW + 28;   // {vs,hs,de,x[12],y[13],data}

wire [PW-1:0] din = {in_vs, in_hs, in_de, in_x, in_y, in_data};

reg [PW-1:0] sr [0:D-1];
integer i;
always @(posedge clk) begin
    if (!rst_n) begin
        for (i = 0; i < D; i = i + 1)
            sr[i] <= {PW{1'b0}};
    end else begin
        sr[0] <= din;
        for (i = 1; i < D; i = i + 1)
            sr[i] <= sr[i-1];
    end
end

assign out_vs   = sr[D-1][DW+27];
assign out_hs   = sr[D-1][DW+26];
assign out_de   = sr[D-1][DW+25];
assign out_x    = sr[D-1][DW+24 -: 12];
assign out_y    = sr[D-1][DW+12 -: 13];
assign out_data = sr[D-1][DW-1:0];

endmodule

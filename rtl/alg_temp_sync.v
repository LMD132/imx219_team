////////////////////////////////////////////////////////////////////////////
//
// alg_temp_sync.v
//
// TEMP(时域降噪强度)这一路的跨时钟域: CLK_25M 的 UART 寄存器组 -> vid_clk_dvi2。
//
// 为什么还要单独一套: 其它运行期参数由 alg_cfg_sync.v 送到 hdmi_tx_slow_clk
// (alg_top 所在的像素时钟域), 而时域融合发生在 DDR 读出侧、o_clk =
// vid_clk_dvi2 的 frame_buffer 里(见 docs/时序降噪_移植说明.md), 是第三个时钟域。
// 与其把整个 53bit 参数总线再搬一遍, 这里只搬 7bit 的 TEMP。
//
// 用法与 alg_cfg_sync.v 完全一样(数据稳定 + toggle):
//   源侧在 i_commit 那一拍把 i_temp 存进快照并翻 tog, 目的侧两级同步 tog,
//   看到变化后把快照抄进 o_temp。到那时快照已经稳定 >= 2 个目的时钟,
//   所以抄到的永远是定值, 不会抄到半个命令。
//
// 丢失条件: 两次命令间隔小于约 3 个目的时钟(~80ns)。115200 波特下一行 ~90us,
// 调参台的两次下发之间还有 60ms 节流, 不可能撞上。
//
// 这是一个"准静态"寄存器: 拖动滑条时它才变, 而且下游只拿它算 alpha —— 就算
// 慢了一帧, 也就是那一帧用了旧强度, 不会破坏数据通路的对齐。
//
////////////////////////////////////////////////////////////////////////////

module alg_temp_sync #(
    parameter [6:0] TEMP_INIT = 7'd0
) (
    input  wire       clk_a,      // 源: CLK_25M (UART 寄存器组)
    input  wire       rst_a_n,
    input  wire       i_commit,   // 主机改完值的那一拍脉冲
    input  wire [6:0] i_temp,

    input  wire       clk_b,      // 目的: vid_clk_dvi2 (DDR 读出 / 融合)
    input  wire       rst_b_n,
    output reg  [6:0] o_temp
);

    reg [6:0] snap;
    reg       tog;

    always @(posedge clk_a or negedge rst_a_n) begin
        if (!rst_a_n) begin
            snap <= TEMP_INIT;
            tog  <= 1'b0;
        end else if (i_commit) begin
            snap <= i_temp;
            tog  <= ~tog;
        end
    end

    reg [2:0] tog_sync;
    wire      take = tog_sync[2] ^ tog_sync[1];

    always @(posedge clk_b or negedge rst_b_n) begin
        if (!rst_b_n) begin
            tog_sync <= 3'b000;
            o_temp   <= TEMP_INIT;
        end else begin
            tog_sync <= {tog_sync[1:0], tog};
            if (take) o_temp <= snap;
        end
    end

endmodule

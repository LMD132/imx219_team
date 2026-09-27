//=============================================================================
// alg_gf_div.v -- 导向滤波(EPF=2)那一处除法的全流水定点实现
//
//  算法来源(唯一权威): FPGA-Python/edge_pipeline.py :: guided_filter()
//      a = var / (var + eps)        (radius=6, eps=400)
//  定点化(见 sim/algo/model/rtl_model.py::guided_filter_int, 逐位一致):
//      V   = 36*S2 - S1^2 = 1296*var         (<= 21067776, 25bit)
//      K   = 1296*eps                        (运行期, 默认 400)
//      num = V<<8  (<= 2^33)      d = V + K  (<= 2^25)
//      a_q8 = min(255, floor(num/d) + (2*r >= d))     r = num - floor(num/d)*d
//  因为 V>0 时 num/d = 256V/(V+K) <= 256, 商只要 9 位 -> 9 步贪心长除就够:
//      rem = num; dd = d<<8; q = 0
//      for i = 8..0: if (rem >= dd) begin rem -= dd; q |= 1<<i; end  dd >>= 1
//      q += (2*rem >= d);  out = min(q, 255)
//  每一级 = 1 个 34bit 比较器 + 1 个 34bit 减法器 + 1 个右移寄存器, 没有 DSP,
//  没有变量移位, 输入 1 pixel/clk。
//
//  延迟: in_num/in_d 当拍 -> out_a 共 11 拍 (9 级 + 舍入 1 + 输出寄存 1)
//  退化点 d==0 (V==0 且 eps==0): 每级 0>=0 全真 -> q=511 -> 舍入 +1 -> 夹到 255,
//  与 rtl_model.guided_filter_int 的 d==0 分支逐位一致。
//=============================================================================

module alg_gf_div #(
    parameter integer NUMW = 34,     // num = V<<8
    parameter integer DENW = 25,     // d = V+K
    parameter integer NQ   = 9       // 商位数(q_int <= 256)
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire [NUMW-1:0] in_num,   // V << 8
    input  wire [DENW-1:0] in_d,     // V + K
    output reg  [7:0]      out_a     // a_q8 = 256*a (0..255)
);

    // 级 0 的组合输入: rem = num, dd = d<<8, q = 0
    wire [NUMW-1:0] dd_in = {{(NUMW-DENW-8){1'b0}}, in_d, 8'b0};

    reg [NUMW-1:0] rem_r [0:NQ-1];
    reg [NUMW-1:0] dd_r  [0:NQ-1];
    reg [NQ-1:0]   q_r   [0:NQ-1];
    reg [DENW-1:0] dp_r  [0:NQ-1];   // d 随流水一起搬, 给最后的舍入比较用

    genvar gi;
    generate
    for (gi = 0; gi < NQ; gi = gi + 1) begin : g_st
        // 用 generate-if 分开写(不要用 ?: ), 否则 iverilog 会对 rem_r[-1] 之类报越界警告
        wire [NUMW-1:0] rin;
        wire [NUMW-1:0] din;
        wire [DENW-1:0] pin;
        if (gi == 0) begin : g_in0
            assign rin = in_num;
            assign din = dd_in;
            assign pin = in_d;
        end else begin : g_inn
            assign rin = rem_r[gi-1];
            assign din = dd_r [gi-1];
            assign pin = dp_r [gi-1];
        end
        wire            gt  = (rin >= din);
        always @(posedge clk) begin
            if (!rst_n) begin
                rem_r[gi] <= {NUMW{1'b0}};
                dd_r [gi] <= {NUMW{1'b0}};
                dp_r [gi] <= {DENW{1'b0}};
            end else begin
                rem_r[gi] <= gt ? (rin - din) : rin;
                dd_r [gi] <= din >> 1;
                dp_r [gi] <= pin;
            end
        end
        if (gi == 0) begin : g_q0
            always @(posedge clk) begin
                if (!rst_n) q_r[0]  <= {NQ{1'b0}};
                else        q_r[0]  <= {{(NQ-1){1'b0}}, gt};
            end
        end else begin : g_qn
            always @(posedge clk) begin
                if (!rst_n) q_r[gi] <= {NQ{1'b0}};
                else        q_r[gi] <= {q_r[gi-1][NQ-2:0], gt};
            end
        end
    end
    endgenerate

    // 舍入: q += (2*rem >= d); 再夹到 255
    wire [NUMW:0]   rem2 = {rem_r[NQ-1], 1'b0};
    wire [NUMW-1:0] dorm = {{(NUMW-DENW){1'b0}}, dp_r[NQ-1]};
    wire            rup  = (rem2 >= {1'b0, dorm});

    reg [NQ:0] qsum;
    always @(posedge clk) begin
        if (!rst_n) qsum <= {(NQ+1){1'b0}};
        else        qsum <= {1'b0, q_r[NQ-1]} + {{NQ{1'b0}}, rup};
    end

    always @(posedge clk) begin
        if (!rst_n) out_a <= 8'd0;
        else        out_a <= (qsum > 9'd255) ? 8'd255 : qsum[7:0];
    end

endmodule

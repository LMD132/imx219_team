//=============================================================================
// alg_blend_bytes.v -- 赛题4  时间域帧间融合 (temporal_blend) 的"整字并行"版
//
//  算法来源(唯一权威, 与 alg_blend.v 同一份, 不允许自行发挥)
//    FPGA-Python-main/edge_pipeline.py:338
//        def temporal_blend(prev, cur, alpha):
//            if prev is None or alpha <= 0:
//                return cur
//            return np.clip(alpha * cur.astype(np.float32)
//                           + (1 - alpha) * prev.astype(np.float32), 0, 255).astype(np.uint8)
//
//    FPGA-Python-main/live_tune.py:166-168  (GUI 滑条 TEMP -> alpha)
//        alpha = 1.0 - temp_val / 100.0 if temp_val > 0 else 0.0
//        gray_t = temporal_blend(prev_gray_n, gray_n, alpha)
//
//  与 alg_blend.v 的关系
//    同一个 LUT、同一套 Q8 定点、同一句算式, 唯一区别是把 NBYTE 个 8bit 像素
//    并成一条 DDR 读出字(NBYTE=16 时是 128bit)一次算完 —— 所以两份 RTL 对同
//    一组 (temp, cur, prev) 的输出必须逐位相同, 单测也是拿同一个金标准跑的
//    (sim/algo/tb_alg_blend_bytes.v 直接复用 blend_golden.txt)。
//
//  为什么融合发生在 Bayer 域(而不是参考代码的灰度域)
//    DDR 里存的是 8bit Bayer, 板上只有一路 debayer, 再开一路要 ~10 块 Memory。
//    debayer 与灰度化都是线性加权, 所以"先融合再 debayer"与"先 debayer 再融合"
//    等价(只差 demosaic 内部的截位, <=1 LSB); 这是 ISP 里时域降噪的常规位置。
//    偏离登记见 docs/时序降噪_移植说明.md 与 docs/ALGO_RTL.md。
//
//  接口: 纯组合逻辑, 无时钟、无延迟。调用方保证 in_cur/in_prev 是同一像素位置,
//        且 in_de = 0 时字里是 0 也无所谓(融合结果同样送 0)。
//        TEMP = 0 (或超出 0..90) 时 out_data 逐位等于 in_cur。
//
//  ⚠️ 上游现状(2026-09-28 记录): `ddr_rd_buffer` 喂进来的 in_prev 是 **DDR 里
//     上一帧的原始像素**(FIR), 而参考 live_tune.py 是 `prev_gray_n = gray_t`
//     的**递归(IIR)**。两者在 TEMP<=40 区间降噪能力只差 1%~10%, 但 TEMP>=50
//     起本实现明显偏弱(TEMP=90 时几乎不降噪)。要复现参考的强降噪档, 需要把
//     融合结果写回 DDR 当下一帧的 prev。详见 docs/时序降噪_移植说明.md 3.2 节。
//=============================================================================

module alg_blend_bytes #(
    parameter NBYTE = 16            // 一条字里有几个 8bit 像素(128bit 字 -> 16)
) (
    // 配置: TEMP 0..90 (0 = 关)。超出 0..90 按"关"处理, 与 Python 的
    // "alpha <= 0 就返回当前帧" 同义。
    input  wire [6:0]         i_temp,

    input  wire [NBYTE*8-1:0] in_cur,
    input  wire [NBYTE*8-1:0] in_prev,

    output wire [NBYTE*8-1:0] out_data,
    output wire [7:0]         o_alpha_q8   // 回观测用(调参台可以显示当前 alpha)
);

//--------------------------------------------------------------------------
// 1) TEMP -> alpha(Q8)。这张表与 rtl/algo/alg_blend.v 逐项相同, 由
//    sim/algo/model/gen_blend_golden.py 生成, 改表要先改脚本。
//    写成 function 的理由同 alg_blend.v: 只用 always @* 在仿真里开机不跑,
//    alpha_q8 停在 X 会让"X != 0"这种判断假装通过。
//--------------------------------------------------------------------------
function [7:0] temp_to_alpha;
    input [6:0] t;
    begin
        case (t)
                7'd 0: temp_to_alpha = 8'd  0; 7'd 1: temp_to_alpha = 8'd253; 7'd 2: temp_to_alpha = 8'd251; 7'd 3: temp_to_alpha = 8'd248; 7'd 4: temp_to_alpha = 8'd246;
                7'd 5: temp_to_alpha = 8'd243; 7'd 6: temp_to_alpha = 8'd241; 7'd 7: temp_to_alpha = 8'd238; 7'd 8: temp_to_alpha = 8'd236; 7'd 9: temp_to_alpha = 8'd233;
                7'd10: temp_to_alpha = 8'd230; 7'd11: temp_to_alpha = 8'd228; 7'd12: temp_to_alpha = 8'd225; 7'd13: temp_to_alpha = 8'd223; 7'd14: temp_to_alpha = 8'd220;
                7'd15: temp_to_alpha = 8'd218; 7'd16: temp_to_alpha = 8'd215; 7'd17: temp_to_alpha = 8'd212; 7'd18: temp_to_alpha = 8'd210; 7'd19: temp_to_alpha = 8'd207;
                7'd20: temp_to_alpha = 8'd205; 7'd21: temp_to_alpha = 8'd202; 7'd22: temp_to_alpha = 8'd200; 7'd23: temp_to_alpha = 8'd197; 7'd24: temp_to_alpha = 8'd195;
                7'd25: temp_to_alpha = 8'd192; 7'd26: temp_to_alpha = 8'd189; 7'd27: temp_to_alpha = 8'd187; 7'd28: temp_to_alpha = 8'd184; 7'd29: temp_to_alpha = 8'd182;
                7'd30: temp_to_alpha = 8'd179; 7'd31: temp_to_alpha = 8'd177; 7'd32: temp_to_alpha = 8'd174; 7'd33: temp_to_alpha = 8'd172; 7'd34: temp_to_alpha = 8'd169;
                7'd35: temp_to_alpha = 8'd166; 7'd36: temp_to_alpha = 8'd164; 7'd37: temp_to_alpha = 8'd161; 7'd38: temp_to_alpha = 8'd159; 7'd39: temp_to_alpha = 8'd156;
                7'd40: temp_to_alpha = 8'd154; 7'd41: temp_to_alpha = 8'd151; 7'd42: temp_to_alpha = 8'd148; 7'd43: temp_to_alpha = 8'd146; 7'd44: temp_to_alpha = 8'd143;
                7'd45: temp_to_alpha = 8'd141; 7'd46: temp_to_alpha = 8'd138; 7'd47: temp_to_alpha = 8'd136; 7'd48: temp_to_alpha = 8'd133; 7'd49: temp_to_alpha = 8'd131;
                7'd50: temp_to_alpha = 8'd128; 7'd51: temp_to_alpha = 8'd125; 7'd52: temp_to_alpha = 8'd123; 7'd53: temp_to_alpha = 8'd120; 7'd54: temp_to_alpha = 8'd118;
                7'd55: temp_to_alpha = 8'd115; 7'd56: temp_to_alpha = 8'd113; 7'd57: temp_to_alpha = 8'd110; 7'd58: temp_to_alpha = 8'd108; 7'd59: temp_to_alpha = 8'd105;
                7'd60: temp_to_alpha = 8'd102; 7'd61: temp_to_alpha = 8'd100; 7'd62: temp_to_alpha = 8'd 97; 7'd63: temp_to_alpha = 8'd 95; 7'd64: temp_to_alpha = 8'd 92;
                7'd65: temp_to_alpha = 8'd 90; 7'd66: temp_to_alpha = 8'd 87; 7'd67: temp_to_alpha = 8'd 84; 7'd68: temp_to_alpha = 8'd 82; 7'd69: temp_to_alpha = 8'd 79;
                7'd70: temp_to_alpha = 8'd 77; 7'd71: temp_to_alpha = 8'd 74; 7'd72: temp_to_alpha = 8'd 72; 7'd73: temp_to_alpha = 8'd 69; 7'd74: temp_to_alpha = 8'd 67;
                7'd75: temp_to_alpha = 8'd 64; 7'd76: temp_to_alpha = 8'd 61; 7'd77: temp_to_alpha = 8'd 59; 7'd78: temp_to_alpha = 8'd 56; 7'd79: temp_to_alpha = 8'd 54;
                7'd80: temp_to_alpha = 8'd 51; 7'd81: temp_to_alpha = 8'd 49; 7'd82: temp_to_alpha = 8'd 46; 7'd83: temp_to_alpha = 8'd 44; 7'd84: temp_to_alpha = 8'd 41;
                7'd85: temp_to_alpha = 8'd 38; 7'd86: temp_to_alpha = 8'd 36; 7'd87: temp_to_alpha = 8'd 33; 7'd88: temp_to_alpha = 8'd 31; 7'd89: temp_to_alpha = 8'd 28;
                7'd90: temp_to_alpha = 8'd 26;
            default: temp_to_alpha = 8'd0;  // 超出滑条范围 = 关, 对应 Python 的 alpha <= 0
        endcase
    end
endfunction

wire [7:0] alpha_q8   = temp_to_alpha(i_temp);
wire [8:0] alpha_comp = 9'd256 - {1'b0, alpha_q8};

assign o_alpha_q8 = alpha_q8;

//--------------------------------------------------------------------------
// 2) 逐字节融合: out = (alpha*cur + (256-alpha)*prev) >> 8
//    alpha + (256-alpha) = 256, 所以和 <= 256*255 = 65280, 16bit 装得下;
//    ">>8 是截断不是四舍五入", 与 Python 的 .astype(np.uint8) 对齐(见 alg_blend.v)。
//    alpha_q8 == 0 时 Python 直接返回当前帧, 所以走直通, 不能用公式。
//--------------------------------------------------------------------------
generate
    genvar b;
    for (b = 0; b < NBYTE; b = b + 1) begin : gen_byte
        wire [7:0]  cur_b     = in_cur [b*8 +: 8];
        wire [7:0]  prev_b    = in_prev[b*8 +: 8];
        wire [16:0] p_cur     = {9'd0, alpha_q8} * {9'd0, cur_b};
        wire [16:0] p_prev    = alpha_comp        * {9'd0, prev_b};
        wire [17:0] blend_sum = {1'b0, p_cur} + {1'b0, p_prev};
        wire [7:0]  blend_val = blend_sum[15:8];

        assign out_data[b*8 +: 8] = (alpha_q8 == 8'd0) ? cur_b : blend_val;
    end
endgenerate

endmodule

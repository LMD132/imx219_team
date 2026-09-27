//=============================================================================
// alg_blend.v  --  赛题4  时间域帧间融合 (temporal_blend 的 RTL 移植)
//
//  算法来源(唯一权威, 不允许自行发挥)
//    FPGA-Python-main/edge_pipeline.py:338
//        def temporal_blend(prev, cur, alpha):
//            if prev is None or alpha <= 0:
//                return cur
//            return np.clip(alpha * cur.astype(np.float32)
//                           + (1 - alpha) * prev.astype(np.float32), 0, 255).astype(np.uint8)
//
//    FPGA-Python-main/live_tune.py:166-168  (GUI 滑条 -> alpha 的真实映射)
//        # 时间域滤波: TEMP>0 时 alpha=1-temp/100 (temp=30 -> alpha=0.7 保留70%当前帧)
//        alpha = 1.0 - temp_val / 100.0 if temp_val > 0 else 0.0
//        gray_t = temporal_blend(prev_gray_n, gray_n, alpha)
//
//  定点化
//    alpha 用 Q8: alpha_q8 = round((100-TEMP)*256/100), TEMP=0 -> 0 (=关, 直接输出当前帧)。
//    输出 = (alpha_q8*cur + (256-alpha_q8)*prev) >> 8   <-- 右移是"截断", 不是四舍五入。
//    Python 的 .astype(np.uint8) 也是截断(向零取整), 所以这里对上了; 若写成
//    "(sum + 128) >> 8" 反而会和 Python 差 1, 那不是移植。
//
//  与 Python 的吻合度(见 sim/algo/model/gen_blend_golden.py 的穷举结论)
//    * 0..90 全部 TEMP、全部 256x256 个 (cur,prev) 组合: |RTL - Python| <= 1 LSB
//    * TEMP = 0 / 25 / 50 / 75 时逐位完全相同(0 误差), 因为这几个 alpha 恰好是
//      1/1, 3/4, 1/2, 1/4, 在 Q8 里表示得下。
//
//  水流接口
//    in_prev 必须是与 in_cur **同一像素位置**的上一帧像素。本模块只做融合,
//    不含帧缓存; 上一帧的来路见 docs/时序降噪_移植说明.md。
//
//  流水线延迟: 输入 in_de -> 输出 out_de 共 1 拍(乘加是组合的, 只有输出寄存器)
//  复位: rst_n 低有效, 同步复位
//=============================================================================

module alg_blend (
    input  wire        clk,
    input  wire        rst_n,

    // 配置: TEMP 0..90 (0 = 关)。超出 0..90 按"关"处理, 与 Python 的
    // "alpha <= 0 就返回当前帧" 同义。
    input  wire [6:0]  i_temp,

    // 像素流(1 pixel / clk)
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,
    input  wire [7:0]  in_cur,      // 当前帧灰度
    input  wire [7:0]  in_prev,     // 上一帧同位置灰度

    output reg         out_vs,
    output reg         out_hs,
    output reg         out_de,
    output reg  [7:0]  out_data,

    output wire [7:0]  o_alpha_q8   // 回观测用(调参台可以显示当前 alpha)
);

//--------------------------------------------------------------------------
// 1) TEMP -> alpha(Q8)。这张表由 sim/algo/model/gen_blend_golden.py 生成,
//    与 Python 的 round((100-TEMP)*256/100) 逐项相同, 改表要先改脚本。
//
//    写成 function 而不是 always @* + case: 一个只由输入决定的查表, 用
//    "always @*" 在仿真里有个坑 —— @* 是等"敏感信号变化"才跑, 如果 i_temp
//    开机就是 0 而一直不变, 块体一次都不执行, alpha_q8 就停在 X, 于是
//    TEMP=0(也就是关)那一档全输出 X, 而"X != 0"是假, 测试台还会误判成通过。
//    function 没有这个问题: 用到就算, 也符合本工程的写法(见 alg_cfg_uart.v)。
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

wire [7:0] alpha_q8 = temp_to_alpha(i_temp);

assign o_alpha_q8 = alpha_q8;

//--------------------------------------------------------------------------
// 2) 融合: out = (alpha*cur + (256-alpha)*prev) >> 8
//    alpha + (256-alpha) = 256, 所以 sum <= 256*255 = 65280, 16 bit 装得下;
//    这里多留几位纯属防御, 代价为零。
//--------------------------------------------------------------------------
wire [8:0]  alpha_comp = 9'd256 - {1'b0, alpha_q8};
wire [16:0] p_cur      = {9'd0, alpha_q8} * {9'd0, in_cur};
wire [16:0] p_prev     = alpha_comp        * {9'd0, in_prev};
wire [17:0] blend_sum  = {1'b0, p_cur} + {1'b0, p_prev};
wire [7:0]  blend_val  = blend_sum[15:8];

// alpha_q8 == 0 时 Python 直接返回当前帧, 不能顺手用公式(那会变成纯上一帧)
wire [7:0]  mix_now    = (alpha_q8 == 8'd0) ? in_cur : blend_val;

//--------------------------------------------------------------------------
// 3) 输出时序: 与 alg_gray / alg_median3 一致, 整链 1 拍延迟
//--------------------------------------------------------------------------
always @(posedge clk) begin
    if (!rst_n) begin
        out_vs   <= 1'b0;
        out_hs   <= 1'b0;
        out_de   <= 1'b0;
        out_data <= 8'd0;
    end else begin
        out_vs   <= in_vs;
        out_hs   <= in_hs;
        out_de   <= in_de;
        out_data <= in_de ? mix_now : 8'd0;
    end
end

endmodule

//=============================================================================
// shp_overlay.v -- 赛题4 形状识别: 在显示流上画 bbox 框 + 中文标签
//
//  输入: alg_vdisp 输出级的"显示坐标"(x_q/y_q, 与 col_q 同拍) + shp_detect 的框表;
//  输出: ov_hit/ov_rgb -- 与"背景第 3 级(orr_b)"同拍, 由 alg_vdisp 在最后一级寄存合入。
//
//  像素级流水(记当前像素为 P, k0 = x/y 给出 P 的那一拍):
//    k0   : 组合算 P 的重叠结果:
//             * 边框命中: 在框内且贴 1px 边(源像素坐标空间)
//             * 标签命中: 32x16 区域(每标签 2 个 16x16 汉字), 框上方 2px;
//                         顶部放不下就摆到框下方
//           标签区最多一个像素只读一次字库 -> 多框重叠时下标小的赢(优先级);
//           字库地址 = 字序号*16 + 行号, 当拍给 shp_font。
//    k0+1 : 字库数据有效(1 拍读延迟) -> font_bit = dout[15-col]
//    k0+2 : ov_hit/ov_rgb 寄存输出;   同拍 alg_vdisp 的 orr_b(第 3 级)也是 P
//    k0+3 : alg_vdisp 第 4 级寄存输出 -> out_r/g/b(所以 out_* 整体比原来晚 2 拍)
//
//  坐标空间:
//    mode 0(同视野左右分屏)两端都做了 2:1 水平抽取 -> 判边框时把屏幕列还原成
//    源像素列(左半 2x, 右半 2(x-640)); 标签画在半幅屏幕空间(不跟着横向压缩);
//    其余模式(mode 1/2/3)是 1:1, 屏幕列 = 源列, 直接用。
//
//  颜色: 圆=黄 矩=青 三角=品红 未知=白(框线和文字同色)。
//
//  资源: 字库 ROM 1 块 BRAM(shp_font), 其余全寄存器逻辑, 无乘法器。
//  时序: 关键路径 = 框表寄存器 -> 比较/优先级 -> 字库地址(约 2~3ns @74.25MHz);
//        最终合入在 alg_vdisp 输出寄存器的 D 端(ROM 数据 -> 16:1 选位 -> 2:1 mux)。
//=============================================================================

module shp_overlay #(
    parameter integer W    = 1280,   // 有效宽度
    parameter integer H    = 720,    // 有效行数
    parameter integer NBX  = 6,      // 框数上限(与 shp_detect 的 NBX 一致)
    parameter integer HALF = 640     // W/2
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        en,           // 形状识别总开关(0 = 什么都不画)
    input  wire        de,           // 显示 de(与 x/y 同拍 = alg_vdisp 的 de_q)
    input  wire [11:0] x,            // 屏幕列(0..W-1)
    input  wire [12:0] y,            // 屏幕行(0..H-1)
    input  wire [1:0]  mode,         // 显示模式(0 = 2:1 抽取, 需坐标还原)

    // 框表(shp_detect 输出, 打包成向量)
    input  wire [NBX*12-1:0] bx0,
    input  wire [NBX*12-1:0] bx1,
    input  wire [NBX*13-1:0] by0,
    input  wire [NBX*13-1:0] by1,
    input  wire [NBX*3-1:0]  bcls,   // 1=圆 2=矩 3=三角 0=未知; 4..7不显示
    input  wire [NBX-1:0]    bval,

    output reg         ov_hit,       // 1 = 本像素用 ov_rgb 覆盖
    output reg  [23:0] ov_rgb        // {R,G,B}
);

    //--------------------------------------------------------------- 解包
    wire [11:0] b_x0 [0:NBX-1];
    wire [11:0] b_x1 [0:NBX-1];
    wire [12:0] b_y0 [0:NBX-1];
    wire [12:0] b_y1 [0:NBX-1];
    wire [2:0]  b_cl [0:NBX-1];
    wire        b_vl [0:NBX-1];

    genvar gi;
    generate
        for (gi = 0; gi < NBX; gi = gi + 1) begin : g_unp
            assign b_x0[gi] = bx0[gi*12 +: 12];
            assign b_x1[gi] = bx1[gi*12 +: 12];
            assign b_y0[gi] = by0[gi*13 +: 13];
            assign b_y1[gi] = by1[gi*13 +: 13];
            assign b_cl[gi] = bcls[gi*3 +: 3];
            assign b_vl[gi] = bval[gi];
        end
    endgenerate

    //------------------------------------------------ 坐标还原(mode 0)
    wire [12:0] x2s  = {1'b0, x} << 1;                    // 2x
    wire        lft  = (x < HALF);
    wire [12:0] xsrc = (mode == 2'd0) ? (lft ? x2s : (x2s - 13'd1280))
                                      : {1'b0, x};        // 源像素列(判边框)
    wire [12:0] hbo  = (mode == 2'd0) ? (lft ? 13'd0 : 13'd640) : 13'd0;
    wire [12:0] xh   = {1'b0, x} - hbo;                   // 半幅内屏幕列(摆标签)
    wire [11:0] lxw  = (mode == 2'd0) ? 12'd608 : 12'd1248;  // 标签左端限位

    //------------------------------------------------ 类别 -> 颜色
    function [23:0] cls_rgb;
        input [2:0] c;
        begin
            case (c)
                3'd1:    cls_rgb = 24'hFFFF00;    // 圆: 黄
                3'd2:    cls_rgb = 24'h00FFFF;    // 矩: 青
                3'd3:    cls_rgb = 24'hFF00FF;    // 三角: 品红
                default: cls_rgb = 24'hFFFFFF;    // 未知: 白
            endcase
        end
    endfunction

    //-------------------------------------- k0 组合: 边框/标签命中 + 字库地址
    integer      m;
    reg  [NBX-1:0] bd_hit, lb_hit;
    reg            bd_any, lb_any;
    reg  [2:0]     bd_cls, lb_cls;
    reg  [11:0]    lb_col;              // 标签内列 0..31
    reg  [7:0]     fa;                  // 字库地址
    reg  [12:0]    ly0;                 // 临时: 标签顶行
    reg  [12:0]    lrow;                // 临时: 标签内行 0..15
    reg  [11:0]    lx0;                 // 临时: 标签左端(半幅内)
    reg  [3:0]     gl, ch;              // 临时: 第几个字 / 字序号

    always @* begin
        bd_hit = {NBX{1'b0}};
        lb_hit = {NBX{1'b0}};
        bd_any = 1'b0;  lb_any = 1'b0;
        bd_cls = 3'd0;  lb_cls = 3'd0;
        lb_col = 12'd0; fa = 8'd0;
        for (m = 0; m < NBX; m = m + 1) begin
            // ---- 边框: 框内 && 贴 1px 边(源像素坐标空间) ----
            bd_hit[m] = b_vl[m] & en & de & (b_cl[m] <= 3'd3)
                      & (xsrc >= {1'b0, b_x0[m]}) & (xsrc <= {1'b0, b_x1[m]})
                      & (y    >= b_y0[m])         & (y    <= b_y1[m])
                      & ((xsrc == {1'b0, b_x0[m]}) | (xsrc == {1'b0, b_x1[m]}) |
                         (y    == b_y0[m])         | (y    == b_y1[m]));
            // ---- 标签区: 32x16, 框上方 2px(顶部放不下则框下方 2px) ----
            ly0 = (b_y0[m] >= 13'd20) ? (b_y0[m] - 13'd18) : (b_y1[m] + 13'd2);
            lx0 = (mode == 2'd0) ? {1'b0, b_x0[m][11:1]} : b_x0[m];
            if (lx0 > lxw) lx0 = lxw;                    // 右缘限位
            lb_hit[m] = b_vl[m] & en & de & (b_cl[m] <= 3'd3)
                      & (xh >= {1'b0, lx0}) & (xh <= ({1'b0, lx0} + 13'd31))
                      & (y  >= ly0)         & (y  <= (ly0 + 13'd15));
            // ---- 优先级: 下标小的框赢 ----
            if (bd_hit[m] && ~bd_any) begin
                bd_any = 1'b1;  bd_cls = b_cl[m];
            end
            if (lb_hit[m] && ~lb_any) begin
                lb_any = 1'b1;  lb_cls = b_cl[m];
                lb_col = xh[11:0] - lx0;                 // 0..31
                lrow   = y - ly0;                        // 0..15(命中条件保证)
                // 字库地址 = 字序号*16 + 行号
                gl = lb_col[4];                          // 0 = 第 1 字, 1 = 第 2 字
                ch = (b_cl[m] == 3'd1) ? (gl ? 4'd1 : 4'd0) :   // 圆形
                     (b_cl[m] == 3'd2) ? (gl ? 4'd1 : 4'd2) :   // 矩形
                     (b_cl[m] == 3'd3) ? (gl ? 4'd4 : 4'd3) :   // 三角
                                         (gl ? 4'd8 : 4'd7);    // 未知
                fa = {ch, 4'd0} + {4'd0, lrow[3:0]};
            end
        end
    end

    //------------------------------------------------------------ 字库 ROM
    wire [15:0] fdat;                    // k0+1 有效

    shp_font u_font (
        .clk(clk), .addr(fa), .dout(fdat)
    );

    //------------------------------------------ k0+1: 寄存命中/颜色/列号
    reg        bd_any_q, lb_any_q;
    reg [2:0]  bd_cls_q, lb_cls_q;
    reg [11:0] lb_col_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bd_any_q <= 1'b0; lb_any_q <= 1'b0;
            bd_cls_q <= 3'd0; lb_cls_q <= 3'd0; lb_col_q <= 12'd0;
        end else begin
            bd_any_q <= bd_any;  lb_any_q <= lb_any;
            bd_cls_q <= bd_cls;  lb_cls_q <= lb_cls;
            lb_col_q <= lb_col;
        end
    end

    //------------------------------------------ k0+2: 合成 + 输出寄存
    wire [3:0]  fidx   = 4'd15 - lb_col_q[3:0];
    wire        fbit   = fdat[fidx];                    // 16:1 选位
    wire        draw_b = bd_any_q;
    wire        draw_l = lb_any_q & fbit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ov_hit <= 1'b0;  ov_rgb <= 24'd0;
        end else begin
            ov_hit <= draw_b | draw_l;
            ov_rgb <= draw_b ? cls_rgb(bd_cls_q) : cls_rgb(lb_cls_q);
        end
    end

endmodule

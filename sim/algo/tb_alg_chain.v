//=============================================================================
// tb_alg_chain.v -- 赛题4 全链路单元测试(直接测 alg_top 整机)
//
//  * 小尺寸参数 W=17, VEXT=9, H=9, REXT=8, 行间消隐 GAP=40
//    (GAP 必须 > L+LINE-W, 否则扩展光栅流的行尾会挤到下一行)
//  * 每帧之间留 12 行垂直消隐, 让 alg_gray 的帧尾 REXT 行回放跑完
//  * 逐级 dump(带全局 tick) + 显示输出 dump, 由 check_chain.py 与金标准对拍:
//      - 各级在"真实图像区域"(x<W,y<H) 的值逐位比对 rtl_model.py
//      - 用 tick 实测彩色/边缘的值对齐延迟是否等于 DLY_RGB
//      - 显示输出逐像素比对(分屏/叠加/半视野/纯边缘)
//  * 全部输入用非阻塞赋值驱动(避免与 DUT 同拍竞争)
//=============================================================================
`timescale 1ns/1ps

module tb_alg_chain;
    parameter integer W     = 17;
    parameter integer VEXT  = 9;
    parameter integer H     = 9;
    parameter integer REXT  = 8;
    parameter integer LINE  = W + VEXT;
    parameter integer NPIX  = W * H;
    parameter integer NFRM  = 2;
    parameter integer GAP   = 40;      // 行间水平消隐
    parameter integer VBLK  = 12;      // 帧间垂直消隐行数
    parameter integer HALF  = 8;       // W/2
    parameter integer AW    = 4;       // clog2(HALF)
    parameter integer HTOTAL = W + GAP;     // 输入光栅行周期(含消隐)
    parameter integer TDLY  = 8 * HTOTAL;   // alg_vdisp 显示整体延迟

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg        vs = 0, hs = 0, de = 0;
    reg [23:0] pdata = 24'h0;
    reg [11:0] px = 0;
    reg [12:0] py = 0;
    reg [23:0] img [0:NPIX-1];

    reg [1:0]  cfg_mode      = 2'd2;
    reg [10:0] cfg_t         = 11'd24;
    reg [10:0] cfg_lo        = 11'd21;
    reg [10:0] cfg_hi        = 11'd58;
    reg        cfg_median_en = 1'b1;
    reg        cfg_gauss_en  = 1'b0;
    reg        cfg_isol_en   = 1'b1;
    reg [1:0]  cfg_disp_mode = 2'd1;
    reg        cfg_ov_color  = 1'b1;

    integer m_arg, d_arg;
    initial begin
        if (!$value$plusargs("MODE=%d", m_arg)) m_arg = 2;
        if (!$value$plusargs("DISP=%d", d_arg)) d_arg = 1;
        cfg_mode      = m_arg[1:0];
        cfg_disp_mode = d_arg[1:0];
    end

    wire        o_vs, o_hs, o_de;
    wire [11:0] o_x;
    wire [12:0] o_y;
    wire [7:0]  o_r, o_g, o_b;

    // DLY_RGB/DLY_GRAY 用模块默认值(26/25), 即被测的最终配置
    alg_top #(
        .W(W), .VEXT(VEXT), .H(H), .REXT(REXT), .HTOTAL(HTOTAL),
        .HALF(HALF), .ROWD(7)
    ) u_top (
        .clk(clk), .rst_n(rst_n),
        .in_vs(vs), .in_hs(hs), .in_de(de),
        .in_r(pdata[23:16]), .in_g(pdata[15:8]), .in_b(pdata[7:0]),
        .cfg_mode(cfg_mode), .cfg_t(cfg_t), .cfg_lo(cfg_lo), .cfg_hi(cfg_hi),
        .cfg_median_en(cfg_median_en), .cfg_gauss_en(cfg_gauss_en),
        .cfg_isol_en(cfg_isol_en), .cfg_disp_mode(cfg_disp_mode),
        .cfg_ov_color(cfg_ov_color),
        .out_vs(o_vs), .out_hs(o_hs), .out_de(o_de),
        .out_x(o_x), .out_y(o_y),
        .out_r(o_r), .out_g(o_g), .out_b(o_b)
    );

    always #5 clk = ~clk;

    integer fgray, fmed, fgau, fsob, fnms, fthr, fdsp, fdisp, fin, fvs;
    integer frame = 0;
    reg vs_d = 0, o_vs_d = 0;
    reg [31:0] tick = 0;

    initial begin
        fgray = $fopen("c_gray.txt", "w");
        fmed  = $fopen("c_med.txt",  "w");
        fgau  = $fopen("c_gau.txt",  "w");
        fsob  = $fopen("c_sob.txt",  "w");
        fnms  = $fopen("c_nms.txt",  "w");
        fthr  = $fopen("c_thr.txt",  "w");
        fdsp  = $fopen("c_dsp.txt",  "w");
        fdisp = $fopen("c_disp.txt", "w");
        fin   = $fopen("c_in.txt",   "w");
        fvs   = $fopen("c_vs.txt",   "w");
        $readmemh("in_rgb.hex", img);
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n) tick <= tick + 32'd1;
        vs_d <= vs;
        if (vs & ~vs_d) frame <= frame + 1;

        if (de)
            $fwrite(fin, "%0d %0d %0d %0d %02x%02x%02x\n",
                    frame, tick, px, py, pdata[23:16], pdata[15:8], pdata[7:0]);

        if (u_top.g_de)
            $fwrite(fgray, "%0d %0d %0d %0d %02x\n", frame, tick, u_top.g_x, u_top.g_y, u_top.g_d);
        if (u_top.med_def)
            $fwrite(fmed, "%0d %0d %0d %0d %02x\n", frame, tick, u_top.med_x, u_top.med_y, u_top.med_d);
        if (u_top.gau_def)
            $fwrite(fgau, "%0d %0d %0d %0d %02x\n", frame, tick, u_top.gau_x, u_top.gau_y, u_top.gau_d);
        if (u_top.sob_def)
            $fwrite(fsob, "%0d %0d %0d %0d %03x %0d\n", frame, tick, u_top.sob_x, u_top.sob_y, u_top.sob_mag, u_top.sob_dir);
        if (u_top.nms_def)
            $fwrite(fnms, "%0d %0d %0d %0d %02x\n", frame, tick, u_top.nms_x, u_top.nms_y, u_top.nms_d);
        if (u_top.thr_def)
            $fwrite(fthr, "%0d %0d %0d %0d %02x\n", frame, tick, u_top.thr_xo, u_top.thr_yo, u_top.thr_d);
        if (u_top.dsp_def)
            $fwrite(fdsp, "%0d %0d %0d %0d %02x\n", frame, tick, u_top.dsp_x, u_top.dsp_y, u_top.dsp_d);

        o_vs_d <= o_vs;
        if (o_vs & ~o_vs_d)
            $fwrite(fvs, "%0d\n", tick);
        if (o_de)
            $fwrite(fdisp, "%0d %0d %0d %02x%02x%02x\n", tick, o_x, o_y, o_r, o_g, o_b);
    end

    //------------------------------------------------------------------
    // 时钟化驱动器(全部非阻塞赋值)
    //   st: 0=等待 1=vs脉冲 2=逐行 3=行间消隐 4=帧间垂直消隐 5=结束
    //------------------------------------------------------------------
    localparam integer S_IDLE = 0, S_VS = 1, S_ROW = 2,
                       S_GAP = 3, S_WAIT = 4, S_END = 5;
    reg [2:0]  st = S_IDLE;
    reg [31:0] cc = 0, pc = 0;
    reg [11:0] rc = 0, fc = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; cc <= 0; pc <= 0; rc <= 0; fc <= 0;
            vs <= 0; hs <= 0; de <= 0; pdata <= 24'h0; px <= 0; py <= 0;
        end else begin
            case (st)
                S_IDLE: begin
                    vs <= 0; hs <= 0; de <= 0;
                    st <= S_VS; cc <= 0; rc <= 0;
                end
                S_VS: begin
                    vs <= 1'b1; de <= 1'b0;
                    if (cc == 4) begin vs <= 1'b0; st <= S_ROW; pc <= 0; cc <= 0; end
                    else cc <= cc + 1'b1;
                end
                S_ROW: begin
                    hs  <= (pc == 0);
                    de  <= 1'b1;
                    pdata <= img[rc*W + pc];
                    px  <= pc[11:0];
                    py  <= rc;
                    if (pc == (W-1)) begin pc <= 0; st <= S_GAP; cc <= 0; end
                    else pc <= pc + 1'b1;
                end
                S_GAP: begin
                    de <= 1'b0; hs <= 1'b0;
                    if (cc == GAP-1) begin
                        cc <= 0;
                        if (rc == (H-1)) st <= S_WAIT;
                        else begin rc <= rc + 1'b1; st <= S_ROW; end
                    end else cc <= cc + 1'b1;
                end
                S_WAIT: begin
                    de <= 1'b0;
                    if (cc == (VBLK * (W + GAP))) begin
                        cc <= 0;
                        if (fc == (NFRM-1)) st <= S_END;
                        else begin fc <= fc + 1'b1; rc <= 0; st <= S_VS; end
                    end else cc <= cc + 1'b1;
                end
                default: begin
                    de <= 1'b0;
                    if (cc == (TDLY + 4 * (W + GAP))) begin
                        $fclose(fgray); $fclose(fmed); $fclose(fgau);
                        $fclose(fsob); $fclose(fnms); $fclose(fthr);
                        $fclose(fdsp); $fclose(fdisp); $fclose(fin); $fclose(fvs);
                        $display("TB CHAIN DONE mode=%0d disp=%0d", cfg_mode, cfg_disp_mode);
                        $finish;
                    end else cc <= cc + 1'b1;
                end
            endcase
        end
    end

endmodule
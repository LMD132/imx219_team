//=============================================================================
// tb_alg_gf.v -- 赛题4 前置滤波(EPF)单元测试: alg_gray -> alg_gf
//
//  * 输入小尺寸随机彩色图(同 tb_alg_chain 的 17x9), 由 alg_gray 生成扩展光栅流
//  * dump alg_gf 输出(带 tick/x/y) 到 c_gf.txt, 由 check_gf.py 与 rtl_model 对拍:
//        EPF=0 -> 直通(luma)   EPF=1 -> gauss3x3_int   EPF=2 -> guided_filter_int
//    只比真实图像区域(x<W, y<H), 要求逐位相符(mismatch=0)
//  * +EPF=<0|1|2>  +GFEPS=<n>   (默认 EPF=2, GFEPS=400 = 参考 Python 参数)
//=============================================================================
`timescale 1ns/1ps

module tb_alg_gf;
    parameter integer W      = 17;
    parameter integer VEXT   = 9;
    parameter integer H      = 9;
    parameter integer REXT   = 8;
    parameter integer NPIX   = W * H;
    parameter integer NFRM   = 2;
    parameter integer GAP    = 40;      // 行间水平消隐
    parameter integer VBLK   = 12;      // 帧间垂直消隐行数
    parameter integer HTOTAL = W + GAP;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg        vs = 0, hs = 0, de = 0;
    reg [23:0] pdata = 24'h0;
    reg [11:0] px = 0;
    reg [12:0] py = 0;
    reg [23:0] img [0:NPIX-1];

    reg [1:0]  cfg_epf   = 2'd2;
    reg [10:0] cfg_gfeps = 11'd400;

    integer e_arg, f_arg;
    initial begin
        if (!$value$plusargs("EPF=%d",   e_arg)) e_arg = 2;
        if (!$value$plusargs("GFEPS=%d", f_arg)) f_arg = 400;
        cfg_epf   = e_arg[1:0];
        cfg_gfeps = f_arg[10:0];
    end

    // ---- alg_gray: RGB -> 灰度 + 扩展光栅流 ----
    wire        g_vs, g_hs, g_de;
    wire [11:0] g_x;
    wire [12:0] g_y;
    wire [7:0]  g_d;

    alg_gray #(
        .W(W), .VEXT(VEXT), .H(H), .REXT(REXT), .PAD_EDGE(1)
    ) u_gray (
        .clk(clk), .rst_n(rst_n),
        .in_vs(vs), .in_hs(hs), .in_de(de),
        .in_r(pdata[23:16]), .in_g(pdata[15:8]), .in_b(pdata[7:0]),
        .out_vs(g_vs), .out_hs(g_hs), .out_de(g_de),
        .out_x(g_x), .out_y(g_y), .out_data(g_d)
    );

    // ---- 被测: 前置滤波(EPF) ----
    wire        o_vs, o_hs, o_de;
    wire [11:0] o_x;
    wire [12:0] o_y;
    wire [7:0]  o_d;

    alg_gf #(
        .W(W), .VEXT(VEXT), .H(H)
    ) u_gf (
        .clk(clk), .rst_n(rst_n),
        .epf(cfg_epf), .gf_eps(cfg_gfeps),
        .in_vs(g_vs), .in_hs(g_hs), .in_de(g_de),
        .in_x(g_x), .in_y(g_y), .in_data(g_d),
        .out_vs(o_vs), .out_hs(o_hs),
        .out_de_full(), .out_de(o_de),
        .out_x(o_x), .out_y(o_y), .out_data(o_d)
    );

    always #5 clk = ~clk;

    integer fgf, fgray;
    integer frame = 0;
    reg vs_d = 0;
    reg [31:0] tick = 0;

    initial begin
        fgf   = $fopen("c_gf.txt",   "w");
        fgray = $fopen("c_gray.txt", "w");
        $readmemh("in_rgb.hex", img);
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n) tick <= tick + 32'd1;
        vs_d <= vs;
        if (vs & ~vs_d) frame <= frame + 1;

        if (g_de)
            $fwrite(fgray, "%0d %0d %0d %0d %02x\n", frame, tick, g_x, g_y, g_d);
        if (o_de)
            $fwrite(fgf, "%0d %0d %0d %0d %02x\n", frame, tick, o_x, o_y, o_d);
    end

    //------------------------------------------------------------------
    // 时钟化驱动器(全部非阻塞赋值), 与 tb_alg_chain 相同
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
                    if (cc == (4 * (W + GAP))) begin
                        $fclose(fgf); $fclose(fgray);
                        $display("TB GF DONE epf=%0d gfeps=%0d", cfg_epf, cfg_gfeps);
                        $finish;
                    end else cc <= cc + 1'b1;
                end
            endcase
        end
    end

endmodule

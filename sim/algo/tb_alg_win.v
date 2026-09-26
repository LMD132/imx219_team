//=============================================================================
// tb_alg_win.v -- alg_gray + alg_win(N=3 / N=5, PAD_EDGE=0/1) 单元测试
//   * 小尺寸参数(W=17,VEXT=5,H=9,REXT=3), 由 Python 生成 in_rgb.hex
//   * 输入行之间故意插入空白间隔, 验证计数只靠 de 驱动
//   * 输出以文本形式落盘, 由 Python 与金标准模型逐位比对
//=============================================================================
`timescale 1ns/1ps

module tb_alg_win;
    parameter integer W     = 17;
    parameter integer VEXT  = 5;
    parameter integer H     = 9;
    parameter integer REXT  = 3;
    parameter integer LINE  = W + VEXT;
    parameter integer NPIX  = W * H;
    parameter integer NFRM  = 2;
    parameter integer GAP   = VEXT + 4;         // 行间水平消隐

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg        vs = 0, hs = 0, de = 0;
    reg [23:0] pdata = 24'h0;
    wire [7:0] pr = pdata[23:16];
    wire [7:0] pg = pdata[15:8];
    wire [7:0] pb = pdata[7:0];

    reg [23:0] img [0:NPIX-1];

    wire        g_vs, g_hs, g_de;
    wire [11:0] g_x;
    wire [12:0] g_y;
    wire [7:0]  g_d;

    alg_gray #(
        .W(W), .VEXT(VEXT), .H(H), .REXT(REXT), .PAD_EDGE(1)
    ) u_gray (
        .clk(clk), .rst_n(rst_n),
        .in_vs(vs), .in_hs(hs), .in_de(de),
        .in_r(pr), .in_g(pg), .in_b(pb),
        .out_vs(g_vs), .out_hs(g_hs), .out_de(g_de),
        .out_x(g_x), .out_y(g_y), .out_data(g_d)
    );

    wire        w3_vs, w3_hs, w3_de;
    wire [11:0] w3_x;
    wire [12:0] w3_y;
    wire [71:0] w3_win;

    alg_win #(
        .DW(8), .W(W), .VEXT(VEXT), .H(H), .N(3), .PAD_EDGE(1)
    ) u_w3 (
        .clk(clk), .rst_n(rst_n),
        .in_vs(g_vs), .in_hs(g_hs), .in_de(g_de),
        .in_x(g_x), .in_y(g_y), .in_data(g_d),
        .out_vs(w3_vs), .out_hs(w3_hs), .out_de(w3_de),
        .out_x(w3_x), .out_y(w3_y), .win(w3_win)
    );

    wire        w5_vs, w5_hs, w5_de;
    wire [11:0] w5_x;
    wire [12:0] w5_y;
    wire [199:0] w5_win;

    alg_win #(
        .DW(8), .W(W), .VEXT(VEXT), .H(H), .N(5), .PAD_EDGE(1)
    ) u_w5 (
        .clk(clk), .rst_n(rst_n),
        .in_vs(g_vs), .in_hs(g_hs), .in_de(g_de),
        .in_x(g_x), .in_y(g_y), .in_data(g_d),
        .out_vs(w5_vs), .out_hs(w5_hs), .out_de(w5_de),
        .out_x(w5_x), .out_y(w5_y), .win(w5_win)
    );

    wire        z3_vs, z3_hs, z3_de;
    wire [11:0] z3_x;
    wire [12:0] z3_y;
    wire [71:0] z3_win;

    alg_win #(
        .DW(8), .W(W), .VEXT(VEXT), .H(H), .N(3), .PAD_EDGE(0)
    ) u_w3z (
        .clk(clk), .rst_n(rst_n),
        .in_vs(g_vs), .in_hs(g_hs), .in_de(g_de),
        .in_x(g_x), .in_y(g_y), .in_data(g_d),
        .out_vs(z3_vs), .out_hs(z3_hs), .out_de(z3_de),
        .out_x(z3_x), .out_y(z3_y), .win(z3_win)
    );

    always #5 clk = ~clk;

    integer fg, f3, f5, fz;
    integer frame = 0;
    reg vs_d = 0;

    initial begin
        fg = $fopen("out_gray.txt", "w");
        f3 = $fopen("out_w3.txt",   "w");
        f5 = $fopen("out_w5.txt",   "w");
        fz = $fopen("out_w3z.txt",  "w");
        $readmemh("in_rgb.hex", img);
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        vs_d <= vs;
        if (vs & ~vs_d) frame <= frame + 1;
        if (g_de) $fwrite(fg, "%0d %0d %0d %02x\n", frame, g_x, g_y, g_d);
        if (w3_de) $fwrite(f3, "%0d %0d %0d %h\n", frame, w3_x, w3_y, w3_win);
        if (w5_de) $fwrite(f5, "%0d %0d %0d %h\n", frame, w5_x, w5_y, w5_win);
        if (z3_de) $fwrite(fz, "%0d %0d %0d %h\n", frame, z3_x, z3_y, z3_win);
    end

    //------------------------------------------------------------------
    // 时钟化驱动器(全部非阻塞赋值, 无竞争): 每行严格 W 拍 de=1
    //   st: 0=等待 1=vs脉冲 2=逐行 3=行间消隐 4=等帧尾回放 5=结束
    //------------------------------------------------------------------
    localparam integer S_IDLE = 0, S_VS = 1, S_ROW = 2,
                       S_GAP = 3, S_WAIT = 4, S_END = 5;
    reg [2:0]  st = S_IDLE;
    reg [31:0] cc = 0, pc = 0;
    reg [11:0] rc = 0, fc = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; cc <= 0; pc <= 0; rc <= 0; fc <= 0;
            vs <= 0; hs <= 0; de <= 0; pdata <= 24'h0;
        end else begin
            case (st)
                S_IDLE: begin
                    vs <= 0; hs <= 0; de <= 0;
                    if (rst_n) begin st <= S_VS; cc <= 0; rc <= 0; end
                end
                S_VS: begin
                    vs <= 1'b1; de <= 1'b0;
                    if (cc == 4) begin vs <= 1'b0; st <= S_ROW; pc <= 0; cc <= 0; end
                    else cc <= cc + 1'b1;
                end
                S_ROW: begin
                    hs <= (pc == 0);
                    de <= 1'b1;
                    pdata <= img[rc*W + pc];
                    if (pc == (W-1)) begin pc <= 0; st <= S_GAP; cc <= 0; end
                    else pc <= pc + 1'b1;
                end
                S_GAP: begin
                    de <= 1'b0; hs <= 1'b0;
                    if (cc == GAP) begin
                        cc <= 0;
                        if (rc == (H-1)) begin st <= S_WAIT; end
                        else begin rc <= rc + 1'b1; st <= S_ROW; end
                    end else cc <= cc + 1'b1;
                end
                S_WAIT: begin
                    de <= 1'b0;
                    if (cc == (REXT * (LINE + 4) + 20)) begin
                        cc <= 0;
                        if (fc == (NFRM-1)) st <= S_END;
                        else begin fc <= fc + 1'b1; rc <= 0; st <= S_VS; end
                    end else cc <= cc + 1'b1;
                end
                default: begin
                    de <= 1'b0;
                    if (cc == 50) begin
                        $fclose(fg); $fclose(f3); $fclose(f5); $fclose(fz);
                        $display("TB DONE");
                        $finish;
                    end else cc <= cc + 1'b1;
                end
            endcase
        end
    end

endmodule

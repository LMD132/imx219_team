//=============================================================================
// tb_alg_ebridge.v -- alg_ebridge(边缘断线桥接) 单元测试
//
//  小尺寸 W=17, VEXT=12, H=9, REXT=4(帧尾 0 行, 与真实链路 PAD_EDGE=0 一致),
//  行间消隐 GAP=40。每帧喂 H 行真数据 + REXT 行 0, 共 NFRM 帧。
//  输入 in_edge.hex (W*H 个 00/FF), dump:
//      e_in.txt  : (frame tick x y val)  输入流(仅 de 拍)
//      e_out.txt : (frame tick x y val)  输出(仅 out_de_full 拍, 带标签)
//  +K=<n> 覆盖 cfg_k (默认 2); +MODE=<n> 覆盖 cfg_mode (默认 2)。
//  比对由 check_ebridge.py 用 rtl_model.bridge_rtl() 完成。
//=============================================================================
`timescale 1ns/1ps

module tb_alg_ebridge;
    parameter integer W    = 17;
    parameter integer VEXT = 12;
    parameter integer H    = 9;
    parameter integer REXT = 4;
    parameter integer LINE = W + VEXT;
    parameter integer NPIX = W * H;
    parameter integer NFRM = 3;
    parameter integer GAP  = 40;
    parameter integer HEXT = H + REXT;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg        vs = 0, hs = 0, de = 0;
    reg [7:0]  pdata = 8'h0;
    reg [11:0] px = 0;
    reg [12:0] py = 0;
    reg [7:0]  img [0:NPIX-1];

    reg [1:0] cfg_k    = 2'd2;
    reg [1:0] cfg_mode = 2'd2;

    integer k_arg, m_arg;
    initial begin
        if (!$value$plusargs("K=%d", k_arg)) k_arg = 2;
        if (!$value$plusargs("MODE=%d", m_arg)) m_arg = 2;
        cfg_k    = k_arg[1:0];
        cfg_mode = m_arg[1:0];
    end

    wire        o_def, o_de;
    wire [11:0] o_x;
    wire [12:0] o_y;
    wire [7:0]  o_d;

    alg_ebridge #(.W(W), .VEXT(VEXT), .H(H)) u_brg (
        .clk(clk), .rst_n(rst_n),
        .in_vs(vs), .in_hs(hs), .in_de(de),
        .in_x(px), .in_y(py), .in_data(pdata),
        .cfg_k(cfg_k), .cfg_mode(cfg_mode),
        .out_vs(), .out_hs(),
        .out_de_full(o_def), .out_de(o_de),
        .out_x(o_x), .out_y(o_y), .out_data(o_d)
    );

    always #5 clk = ~clk;

    integer fin_, fout_;
    integer frame = -1;         // 第一个 vs 上升沿后变 0
    reg vs_d = 0;
    reg [31:0] tick = 0;

    initial begin
        fin_  = $fopen("e_in.txt",  "w");
        fout_ = $fopen("e_out.txt", "w");
        $readmemh("in_edge.hex", img);
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n) tick <= tick + 32'd1;
        vs_d <= vs;
        if (vs & ~vs_d) frame <= frame + 1;
        if (de)
            $fwrite(fin_, "%0d %0d %0d %0d %02x\n", frame, tick, px, py, pdata);
        if (o_def)
            $fwrite(fout_, "%0d %0d %0d %0d %02x\n", frame, tick, o_x, o_y, o_d);
    end

    //------------------------------------------------------------------
    // 时钟化驱动器(参考 tb_alg_chain.v): 0=idle 1=vs 2=行 3=行间消隐
    //   4=帧间垂直消隐 5=结束
    //   帧内行号 rc: 0..H-1 真数据; H..HEXT-1 填 0 (帧尾复制行, 见 alg_gray)
    //------------------------------------------------------------------
    localparam integer S_IDLE = 0, S_VS = 1, S_ROW = 2,
                       S_GAP = 3, S_WAIT = 4, S_END = 5;
    reg [2:0]  st = S_IDLE;
    reg [31:0] cc = 0, pc = 0;
    reg [11:0] rc = 0, fc = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; cc <= 0; pc <= 0; rc <= 0; fc <= 0;
            vs <= 0; hs <= 0; de <= 0; pdata <= 8'h0; px <= 0; py <= 0;
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
                    // x = 0..W-1 真数据; x = W..LINE-1 行尾扩展列(上级 PAD_EDGE=0 输出 0)
                    pdata <= ((rc < H) && (pc < W)) ? img[rc*W + pc] : 8'h00;
                    px  <= pc[11:0];
                    py  <= rc;
                    if (pc == (LINE-1)) begin pc <= 0; st <= S_GAP; cc <= 0; end
                    else pc <= pc + 1'b1;
                end
                S_GAP: begin
                    de <= 1'b0; hs <= 1'b0;
                    if (cc == GAP-1) begin
                        cc <= 0;
                        if (rc == (HEXT-1)) st <= S_WAIT;
                        else begin rc <= rc + 1'b1; st <= S_ROW; end
                    end else cc <= cc + 1'b1;
                end
                S_WAIT: begin
                    de <= 1'b0;
                    // 帧间垂直消隐: 够窗口把最后几行的 out 走完
                    if (cc == ((REXT + 6) * (LINE + GAP))) begin
                        cc <= 0;
                        if (fc == (NFRM-1)) st <= S_END;
                        else begin fc <= fc + 1'b1; rc <= 0; st <= S_VS; end
                    end else cc <= cc + 1'b1;
                end
                default: begin
                    de <= 1'b0;
                    if (cc == (8 * (LINE + GAP))) begin
                        $fclose(fin_); $fclose(fout_);
                        $display("DONE");
                        $finish;
                    end else cc <= cc + 1'b1;
                end
            endcase
        end
    end
endmodule

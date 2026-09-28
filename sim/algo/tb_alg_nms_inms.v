//=============================================================================
// tb_alg_nms_inms.v -- alg_nms 单元测试(含新增的 cfg_inms 插值路径 + cfg_eps 容差)
//
//   同一路随机梯度流同时喂给 4 个 DUT:
//       u_ref  (cfg_inms=0, eps=0)  -> out_ref.txt   参考实现 4 方向量化
//       u_ref3 (cfg_inms=0, eps=3)  -> out_ref3.txt  + 容差
//       u_new  (cfg_inms=1, eps=0)  -> out_new.txt   插值
//       u_new3 (cfg_inms=1, eps=3)  -> out_new3.txt  插值 + 容差
//   输入由 Python 生成 in_nms.hex(每行 10 个 hex 字符):
//       {3'b0, dir[1:0], gx[11:0], gy[11:0], mag[10:0]}
//    注意 dir 的 2bit 编码是 0->0°, 90->1, 45->2, 135->3 (与 alg_sobel3 一致)。
//    喂 H+2 行: 最后两行复制第 H-1 行, 让窗口中心 y=H-1 也有完整窗口(等价模型
//    pad_edge 的下边界), 否则最下一行永远无从对拍。
//   输出文本: frame x y data, 由 Python 与 rtl_model 的金标准逐位比对。
//
//   跑法(见 check_inms_rtl.py, 由它自动调用):
//       iverilog -g2012 -o tb_nms.vvp tb_alg_nms_inms.v ../rtl/... && vvp tb_nms.vvp
//=============================================================================
`timescale 1ns/1ps

module tb_alg_nms_inms;
    parameter integer W    = 32;
    parameter integer VEXT = 8;
    parameter integer H    = 12;
    parameter integer LINE = W + VEXT;
    parameter integer NPIX = W * (H + 2);
    parameter integer GAP  = VEXT + 4;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg        vs = 0, hs = 0, de = 0;
    reg [11:0] px = 0;
    reg [12:0] py = 0;
    reg [39:0] wsel = 40'h0;

    reg [39:0] vin [0:NPIX-1];

    wire        r_vs, r_hs, r_de;
    wire [11:0] r_x;
    wire [12:0] r_y;
    wire [7:0]  r_d;
    wire        r3_vs, r3_hs, r3_de;
    wire [11:0] r3_x;
    wire [12:0] r3_y;
    wire [7:0]  r3_d;
    wire        n_vs, n_hs, n_de;
    wire [11:0] n_x;
    wire [12:0] n_y;
    wire [7:0]  n_d;
    wire        n3_vs, n3_hs, n3_de;
    wire [11:0] n3_x;
    wire [12:0] n3_y;
    wire [7:0]  n3_d;

    wire [1:0]  i_dir = wsel[36:35];
    wire [11:0] i_gx  = wsel[34:23];
    wire [11:0] i_gy  = wsel[22:11];
    wire [10:0] i_mag = wsel[10:0];

    alg_nms #(.W(W), .VEXT(VEXT), .H(H)) u_ref (
        .clk(clk), .rst_n(rst_n),
        .in_vs(vs), .in_hs(hs), .in_de(de), .in_x(px), .in_y(py),
        .in_mag(i_mag), .in_dir(i_dir), .in_gx(i_gx), .in_gy(i_gy),
        .cfg_eps(4'd0), .cfg_inms(1'b0),
        .out_vs(r_vs), .out_hs(r_hs), .out_de_full(), .out_de(r_de),
        .out_x(r_x), .out_y(r_y), .out_data(r_d)
    );

    alg_nms #(.W(W), .VEXT(VEXT), .H(H)) u_ref3 (
        .clk(clk), .rst_n(rst_n),
        .in_vs(vs), .in_hs(hs), .in_de(de), .in_x(px), .in_y(py),
        .in_mag(i_mag), .in_dir(i_dir), .in_gx(i_gx), .in_gy(i_gy),
        .cfg_eps(4'd3), .cfg_inms(1'b0),
        .out_vs(r3_vs), .out_hs(r3_hs), .out_de_full(), .out_de(r3_de),
        .out_x(r3_x), .out_y(r3_y), .out_data(r3_d)
    );

    alg_nms #(.W(W), .VEXT(VEXT), .H(H)) u_new (
        .clk(clk), .rst_n(rst_n),
        .in_vs(vs), .in_hs(hs), .in_de(de), .in_x(px), .in_y(py),
        .in_mag(i_mag), .in_dir(i_dir), .in_gx(i_gx), .in_gy(i_gy),
        .cfg_eps(4'd0), .cfg_inms(1'b1),
        .out_vs(n_vs), .out_hs(n_hs), .out_de_full(), .out_de(n_de),
        .out_x(n_x), .out_y(n_y), .out_data(n_d)
    );

    alg_nms #(.W(W), .VEXT(VEXT), .H(H)) u_new3 (
        .clk(clk), .rst_n(rst_n),
        .in_vs(vs), .in_hs(hs), .in_de(de), .in_x(px), .in_y(py),
        .in_mag(i_mag), .in_dir(i_dir), .in_gx(i_gx), .in_gy(i_gy),
        .cfg_eps(4'd3), .cfg_inms(1'b1),
        .out_vs(n3_vs), .out_hs(n3_hs), .out_de_full(), .out_de(n3_de),
        .out_x(n3_x), .out_y(n3_y), .out_data(n3_d)
    );

    always #5 clk = ~clk;

    integer f_ref, f_ref3, f_new, f_new3, f_win;
    integer frame = 0;
    reg vs_d = 0;

    initial begin
        f_ref  = $fopen("out_ref.txt",  "w");
        f_ref3 = $fopen("out_ref3.txt", "w");
        f_new  = $fopen("out_new.txt",  "w");
        f_new3 = $fopen("out_new3.txt", "w");
        f_win  = $fopen("out_win.txt",  "w");
        $readmemh("in_nms.hex", vin);
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        vs_d <= vs;
        if (vs & ~vs_d) frame <= frame + 1;
        if (r_de)  $fwrite(f_ref,  "%0d %0d %0d %02x\n", frame, r_x,  r_y,  r_d);
        if (r_de)  $fwrite(f_win,  "%0d %0d %h\n", r_x, r_y, u_ref.win);
        if (r3_de) $fwrite(f_ref3, "%0d %0d %0d %02x\n", frame, r3_x, r3_y, r3_d);
        if (n_de)  $fwrite(f_new,  "%0d %0d %0d %02x\n", frame, n_x,  n_y,  n_d);
        if (n3_de) $fwrite(f_new3, "%0d %0d %0d %02x\n", frame, n3_x, n3_y, n3_d);
    end

    //------------------------------------------------------------------
    // 驱动器: 单帧, 每行严格 W 拍 de=1, 行间插消隐(与 tb_alg_win.v 同风格)
    //------------------------------------------------------------------
    localparam integer S_IDLE = 0, S_VS = 1, S_ROW = 2,
                       S_GAP = 3, S_WAIT = 4, S_END = 5;
    reg [2:0]  st = S_IDLE;
    reg [31:0] cc = 0;
    reg [11:0] rc = 0, pc = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; cc <= 0; pc <= 0; rc <= 0;
            vs <= 0; hs <= 0; de <= 0; px <= 0; py <= 0; wsel <= 40'h0;
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
                    px <= pc;
                    py <= rc;
                    // 喂整行 LINE = W + VEXT 列(真实流水口径): 窗口中心 x = px-1,
                    // 多出来的列用最后一列复制(alg_win 的 clamp_col 也是这个口径)。
                    wsel <= vin[rc * W + ((pc < W) ? pc : (W - 1))];
                    if (pc == (LINE-1)) begin pc <= 0; st <= S_GAP; cc <= 0; end
                    else pc <= pc + 1'b1;
                end
                S_GAP: begin
                    de <= 1'b0; hs <= 1'b0;
                    if (cc == GAP) begin
                        cc <= 0;
                        if (rc == (H+1)) st <= S_WAIT;
                        else begin rc <= rc + 1'b1; st <= S_ROW; end
                    end else cc <= cc + 1'b1;
                end
                S_WAIT: begin
                    de <= 1'b0;
                    if (cc == 200) begin cc <= 0; st <= S_END; end
                    else cc <= cc + 1'b1;
                end
                default: begin
                    de <= 1'b0;
                    if (cc == 20) begin
                        $fclose(f_ref); $fclose(f_ref3);
                        $fclose(f_new); $fclose(f_new3);
                        $display("TB NMS DONE");
                        $finish;
                    end else cc <= cc + 1'b1;
                end
            endcase
        end
    end

endmodule

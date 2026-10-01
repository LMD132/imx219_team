`timescale 1ns/1ps
//=============================================================================
// tb_alg_tel_shp.v -- 形状识别调参链路自检 (S/Y/Z/W/A 命令 -> 108字节状态行)
//
// 验证两件事:
//   1) alg_cfg_uart 对 S/Y/Z/W/A 的解析与限幅(8..255 / 800..990 / 1..6 / 5..100);
//   2) 108 字节 telemetry 行里 SHP/SZ/FL/BX/AR 五个新字段的 BCD 数字
//      (含 255/990/100 这类三位的进位情况), 用独立采样器解码 o_txd.
//
// 跑法(工程根目录):
//   C:\iverilog\bin\iverilog.exe -g2005 -o sim\algo\run\tb_tel_shp.vvp sim\algo\tb_alg_tel_shp.v rtl\uart_rx.v rtl\uart_tx.v rtl\alg_cfg_uart.v rtl\alg_cfg_telemetry.v
//   C:\iverilog\bin\vvp.exe sim\algo\run\tb_tel_shp.vvp
//=============================================================================
`timescale 1ns/1ps

module tb_alg_tel_shp;

    localparam integer BIT_NS = 8680;         // 115200 baud (25MHz 下 217 拍)
    localparam integer LEN    = 108;

    integer errors = 0;
    integer checks = 0;

    reg clk25 = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk25 = ~clk25;                // 25 MHz

    //--------------------------------------------------------------- DUT 接线
    reg        rx_line = 1'b1;
    wire [7:0] ubyte;
    wire       uvalid;

    wire [1:0]  c_mode, c_disp;
    wire [10:0] c_t, c_lo, c_hi, c_gf_eps;
    wire        c_med, c_gau, c_iso, c_ovc, c_commit;
    wire [3:0]  c_eps;
    wire [1:0]  c_epf, c_brg;
    wire        c_shp_en;
    wire [7:0]  c_shp_min;
    wire [9:0]  c_shp_fill;
    wire [2:0]  c_shp_nbox;
    wire [6:0]  c_shp_area;
    wire [9:0]  c_cam_grp;
    wire        c_cam_rd;
    wire        txd;

    uart_rx #(.CLK_HZ(25000000), .BAUD(115200)) u_rx (
        .clk(clk25), .rst_n(rst_n), .i_rxd(rx_line),
        .o_data(ubyte), .o_valid(uvalid)
    );

    alg_cfg_uart #(
        .MODE_INIT(2'd2), .T_INIT(11'd24), .LO_INIT(11'd21), .HI_INIT(11'd58),
        .EPS_INIT(4'd0), .EPF_INIT(2'd2), .GFEPS_INIT(11'd400), .BRG_INIT(2'd2),
        .MEDIAN_INIT(1'b1), .GAUSS_INIT(1'b0), .ISOL_INIT(1'b1),
        .DISP_INIT(2'd0), .OVC_INIT(1'b1),
        .SHP_INIT(1'b1), .SHP_MIN_INIT(8'd24), .SHP_FIL_INIT(10'd875),
        .SHP_NBX_INIT(3'd4), .SHP_ARE_INIT(7'd50)
    ) u_cfg (
        .clk(clk25), .rst_n(rst_n), .i_data(ubyte), .i_valid(uvalid),
        .o_mode(c_mode), .o_t(c_t), .o_lo(c_lo), .o_hi(c_hi),
        .o_eps(c_eps), .o_epf(c_epf), .o_gf_eps(c_gf_eps), .o_brg(c_brg),
        .o_median_en(c_med), .o_gauss_en(c_gau), .o_isol_en(c_iso),
        .o_disp_mode(c_disp), .o_ov_color(c_ovc),
        .o_shp_en(c_shp_en), .o_shp_min(c_shp_min), .o_shp_fill(c_shp_fill),
        .o_shp_nbox(c_shp_nbox), .o_shp_area(c_shp_area),
        .o_commit(c_commit), .o_cam_grp(c_cam_grp), .o_cam_rd(c_cam_rd)
    );

    alg_cfg_telemetry #(.CLK_HZ(25000000), .BAUD(115200), .PERIOD_MS(5)) u_tel (
        .clk(clk25), .rst_n(rst_n),
        .i_mode(c_mode), .i_t(c_t), .i_lo(c_lo), .i_hi(c_hi),
        .i_eps(c_eps), .i_epf(c_epf), .i_gf_eps(c_gf_eps), .i_brg(c_brg),
        .i_median(c_med), .i_gauss(c_gau), .i_isol(c_iso),
        .i_disp(c_disp), .i_ovc(c_ovc),
        .i_shp_en(c_shp_en), .i_shp_min(c_shp_min), .i_shp_fill(c_shp_fill),
        .i_shp_nbox(c_shp_nbox), .i_shp_area(c_shp_area),
        .i_cam_grp(c_cam_grp), .i_cam_val(8'hFF),
        .i_update(c_commit), .o_txd(txd)
    );

    //--------------------------------------------------------------- 激励
    task send_char; input [7:0] c; integer k;
        begin
            rx_line = 1'b0; #(BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin rx_line = c[k]; #(BIT_NS); end
            rx_line = 1'b1; #(BIT_NS);
        end
    endtask

    task send_str; input [8*20-1:0] s; integer k; reg found;
        begin
            found = 1'b0;
            for (k = 19; k >= 0; k = k - 1) begin
                if (s[8*k +: 8] != 8'h00) found = 1'b1;
                if (found) send_char(s[8*k +: 8]);
            end
            send_char(8'h0A);
        end
    endtask

    // 独立采样器: 每比特中点采样, 不复用 DUT 的 uart_rx
    task uart_get_byte; output [7:0] c; integer k;
        begin
            @(negedge txd);
            #(BIT_NS/2);
            for (k = 0; k < 8; k = k + 1) begin #(BIT_NS); c[k] = txd; end
            #(BIT_NS);
        end
    endtask

    //--------------------------------------------------------------- 检查
    task chk12; input [8*16-1:0] name; input [11:0] got, exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: got %0d want %0d", name, got, exp);
            end else $display("  ok  %0s = %0d", name, got);
        end
    endtask

    // 按行扫描: 每收到 LF 就把最近 108 字节和期望整行比对, 最多 6 行
    reg [7:0] win [0:LEN-1];
    integer kk, nbyt, nline;
    reg [7:0] cc;
    reg matched;
    task expect_line; input [8*LEN-1:0] exp;
        begin
            matched = 1'b0;
            nbyt = 0; nline = 0;
            while (!matched && (nline < 6)) begin
                uart_get_byte(cc);
                for (kk = 0; kk < LEN-1; kk = kk + 1) win[kk] = win[kk+1];
                win[LEN-1] = cc;
                nbyt = nbyt + 1;
                if (cc == 8'h0A) begin
                    nline = nline + 1;
                    matched = 1'b1;
                    for (kk = 0; kk < LEN; kk = kk + 1)
                        if (win[kk] !== exp[8*(LEN-1-kk) +: 8]) matched = 1'b0;
                end
            end
            checks = checks + 1;
            if (!matched) begin
                errors = errors + 1;
                $display("FAIL 状态行未匹配 (%0d 行, %0d 字节)", nline, nbyt);
                $write("  got: ");
                for (kk = 0; kk < LEN; kk = kk + 1) $write("%c", win[kk]);
                $write("\n  hex: ");
                for (kk = 0; kk < LEN; kk = kk + 1) $write("%02x ", win[kk]);
                $write("\n");
            end else begin
                $display("  ok  状态行匹配 (第 %0d 行): ", nline);
                $write("      ");
                for (kk = 0; kk < LEN-1; kk = kk + 1) $write("%c", win[kk]);
                $write("\n");
            end
        end
    endtask

    reg [8*LEN-1:0] exp_default, exp_final;

    initial begin
        // 上电默认值整行 (含 5 个形状字段的默认 24/875/4/50)
        exp_default = {"M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 GF0400 BRG2 CAM0000=FF",
                       " SHP1 SZ024 FL875 BX4 AR050", 8'h0A};
        // 极端值整行: SZ255 FL990 BX6 AR100 (BCD 进位的情况)
        exp_final   = {"M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 GF0400 BRG2 CAM0000=FF",
                       " SHP1 SZ255 FL990 BX6 AR100", 8'h0A};

        for (kk = 0; kk < LEN; kk = kk + 1) win[kk] = 8'h00;

        rst_n = 1'b0;
        repeat (20) @(posedge clk25);
        rst_n = 1'b1;
        repeat (10) @(posedge clk25);

        $display("--- 1. 上电默认值 + 第一行状态");
        chk12("shp_en_def",   {11'b0, c_shp_en},   12'd1);
        chk12("shp_min_def",  {4'b0,  c_shp_min},  12'd24);
        chk12("shp_fill_def", {2'b0,  c_shp_fill}, 12'd875);
        chk12("shp_nbox_def", {9'b0,  c_shp_nbox}, 12'd4);
        chk12("shp_area_def", {5'b0,  c_shp_area}, 12'd50);
        expect_line(exp_default);

        $display("--- 2. 开关 S0 / S1");
        send_str("S0"); repeat (200) @(posedge clk25);
        chk12("shp_en_after_S0", {11'b0, c_shp_en}, 12'd0);
        send_str("S1"); repeat (200) @(posedge clk25);
        chk12("shp_en_after_S1", {11'b0, c_shp_en}, 12'd1);

        $display("--- 3. 下限限幅 Y0->8 Z700->800 W0->1 A2->5");
        send_str("Y0 Z700 W0 A2"); repeat (400) @(posedge clk25);
        chk12("sz_clamp_lo",   {4'b0, c_shp_min},  12'd8);
        chk12("fl_clamp_lo",   {2'b0, c_shp_fill}, 12'd800);
        chk12("bx_clamp_lo",   {9'b0, c_shp_nbox}, 12'd1);
        chk12("ar_clamp_lo",   {5'b0, c_shp_area}, 12'd5);

        $display("--- 4. 上限值 Y255 Z990 W6 A100 + 状态行回读");
        send_str("Y255 Z990 W6 A100"); repeat (400) @(posedge clk25);
        chk12("sz_max",  {4'b0, c_shp_min},  12'd255);
        chk12("fl_max",  {2'b0, c_shp_fill}, 12'd990);
        chk12("bx_max",  {9'b0, c_shp_nbox}, 12'd6);
        chk12("ar_max",  {5'b0, c_shp_area}, 12'd100);
        expect_line(exp_final);

        if (errors != 0) $fatal(1,"FAIL shape telemetry: %0d errors / %0d checks", errors, checks);
        $display("SHAPE_TEST_PASS tb_alg_tel_shp %0d checks", checks);
        $finish_and_return(0);
    end

endmodule

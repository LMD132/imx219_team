//=============================================================================
// tb_alg_cfg_uart.v -- 赛题4 运行期调参通道自检
//
// 测的是"参数怎么进去、怎么被确认"这条链路, 与算法无关:
//   PC 串口(115200) -> uart_rx -> alg_cfg_uart(命令解析 + 寄存器组)
//        +-> alg_cfg_telemetry (ASCII 状态行, 逐字节独立解码后比对)
//        +-> alg_cfg_sync      (跨到 HDMI 像素时钟域)
//
// 两个刻意的选择:
//   1. 解码 o_txd 用本文件独立写的采样任务 uart_get_byte, 不复用 DUT 的
//      uart_rx, 否则收发同源错误会互相抵消, 测试就成了自言自语。
//      uart_rx 本身另有一段直接喂线的用例(第 2 节起都是走真实串口时序的)。
//   2. 状态行用现行 148 字节滑窗匹配(含EPF/GF/BRG/SHP/CAM/CNT/OV/F/R/S/Q),
//      不需要刻意对齐到行首。协议以单个 LF 结尾。
//=============================================================================
`timescale 1ns/1ps

module tb_alg_cfg_uart;

    localparam integer BIT_NS = 8680;   // 115200 baud = 217 x 40 ns
    localparam integer NB = 148;        // 当前完整状态行(见 alg_cfg_telemetry.v)

    integer errors = 0;
    integer checks = 0;

    reg clk25 = 1'b0;
    reg clkpx = 1'b0;
    reg rst_n = 1'b0;

    always #20 clk25 = ~clk25;          // 25 MHz  (CLK_25M)
    always #23 clkpx = ~clkpx;          // ~21.7 MHz (hdmi_tx_slow_clk 的替身)

    //--------------------------------------------------------------- DUT 接线
    reg        rx_line = 1'b1;          // PC -> FPGA
    wire [7:0] ubyte;
    wire       uvalid;
    wire [1:0] c_mode, c_disp;
    wire [10:0] c_t, c_lo, c_hi;
    wire       c_med, c_gau, c_iso, c_ovc, c_commit;
    wire [3:0] c_eps;
    wire [1:0] c_epf,c_brg;
    wire [10:0] c_gf_eps;
    wire c_shp_en;
    wire [7:0] c_shp_min;
    wire [9:0] c_shp_fill;
    wire [2:0] c_shp_nbox;
    wire [6:0] c_shp_area;
    wire [9:0] c_cam_grp;
    wire       c_cam_rd;
    reg  [7:0] cam_val = 8'hFF;   // 冒充 piv2_config 读回来的那个字节
    reg        cam_upd = 1'b0;    // 一拍的读回完成脉冲
    integer    cam_rd_cnt = 0;    // X 命令产生的请求脉冲个数

    always @(posedge clk25) if (c_cam_rd) cam_rd_cnt = cam_rd_cnt + 1;
    wire       txd;                     // FPGA -> PC
    wire [1:0] p_mode, p_disp;
    wire [10:0] p_t, p_lo, p_hi;
    wire       p_med, p_gau, p_iso, p_ovc;
    wire [3:0] p_eps;

    uart_rx #(
        .CLK_HZ (25000000),
        .BAUD   (115200)
    ) u_rx (
        .clk     (clk25),
        .rst_n   (rst_n),
        .i_rxd   (rx_line),
        .o_data  (ubyte),
        .o_valid (uvalid)
    );

    alg_cfg_uart #(
        .MODE_INIT   (2'd2),
        .T_INIT      (11'd24),
        .LO_INIT     (11'd21),
        .HI_INIT     (11'd58),
        .EPS_INIT    (4'd0),
        .MEDIAN_INIT (1'b1),
        .GAUSS_INIT  (1'b0),
        .ISOL_INIT   (1'b1),
        .DISP_INIT   (2'd0),
        .OVC_INIT    (1'b1)
    ) u_cfg (
        .clk         (clk25),
        .rst_n       (rst_n),
        .i_data      (ubyte),
        .i_valid     (uvalid),
        .o_mode      (c_mode),
        .o_t         (c_t),
        .o_lo        (c_lo),
        .o_hi        (c_hi),
        .o_eps       (c_eps),
        .o_epf       (c_epf),
        .o_gf_eps    (c_gf_eps),
        .o_brg       (c_brg),
        .o_median_en (c_med),
        .o_gauss_en  (c_gau),
        .o_isol_en   (c_iso),
        .o_disp_mode (c_disp),
        .o_ov_color  (c_ovc),
        .o_shp_en    (c_shp_en),
        .o_shp_min   (c_shp_min),
        .o_shp_fill  (c_shp_fill),
        .o_shp_nbox  (c_shp_nbox),
        .o_shp_area  (c_shp_area),
        .o_commit    (c_commit),
        .o_cam_grp   (c_cam_grp),
        .o_cam_rd    (c_cam_rd)
    );

    // PERIOD_MS=5 让整段仿真不至于太久, 同时仍然远大于一次命令的往返,
    // 所以"收到命令后立刻回一行"这件事是被真正验证过的, 不是被周期行掩盖的。
    alg_cfg_telemetry #(
        .CLK_HZ    (25000000),
        .BAUD      (115200),
        .PERIOD_MS (5)
    ) u_tel (
        .clk      (clk25),
        .rst_n    (rst_n),
        .i_mode   (c_mode),
        .i_t      (c_t),
        .i_lo     (c_lo),
        .i_hi     (c_hi),
        .i_eps    (c_eps),
        .i_epf    (c_epf),
        .i_gf_eps (c_gf_eps),
        .i_brg    (c_brg),
        .i_median (c_med),
        .i_gauss  (c_gau),
        .i_isol   (c_iso),
        .i_disp   (c_disp),
        .i_ovc    (c_ovc),
        .i_shp_en (c_shp_en),
        .i_shp_min(c_shp_min),
        .i_shp_fill(c_shp_fill),
        .i_shp_nbox(c_shp_nbox),
        .i_shp_area(c_shp_area),
        .i_cam_grp(c_cam_grp),
        .i_cam_val(cam_val),
        .i_update (c_commit | cam_upd),
        .i_diag_cnt(10'd5),
        .i_diag_ovf(16'h000A),
        .i_diag_fault(1'b0),
        .i_diag_reason(4'h0),
        .i_diag_slot_drop_total(32'd0),
        .i_diag_fifo_full_total(32'd0),
        .i_diag_frame_valid(1'b1),
        .i_diag_sample_valid(1'b1),
        .i_diag_busy(1'b0),
        .o_diag_req(),
        .o_txd    (txd)
    );

    alg_cfg_sync #(
        .MODE_INIT   (2'd2),
        .T_INIT      (11'd24),
        .LO_INIT     (11'd21),
        .HI_INIT     (11'd58),
        .EPS_INIT    (4'd0),
        .MEDIAN_INIT (1'b1),
        .GAUSS_INIT  (1'b0),
        .ISOL_INIT   (1'b1),
        .DISP_INIT   (2'd0),
        .OVC_INIT    (1'b1)
    ) u_sync (
        .clk_a    (clk25),
        .rst_a_n  (rst_n),
        .i_commit (c_commit),
        .i_mode   (c_mode),
        .i_t      (c_t),
        .i_lo     (c_lo),
        .i_hi     (c_hi),
        .i_eps    (c_eps),
        .i_median (c_med),
        .i_gauss  (c_gau),
        .i_isol   (c_iso),
        .i_disp   (c_disp),
        .i_ovc    (c_ovc),
        .clk_b    (clkpx),
        .rst_b_n  (rst_n),
        .o_mode   (p_mode),
        .o_t      (p_t),
        .o_lo     (p_lo),
        .o_hi     (p_hi),
        .o_eps    (p_eps),
        .o_median (p_med),
        .o_gauss  (p_gau),
        .o_isol   (p_iso),
        .o_disp   (p_disp),
        .o_ovc    (p_ovc)
    );

    //----------------------------------------------------------------- 检查器
    task chk11;
        input [8*16-1:0] name;
        input [10:0]     got;
        input [10:0]     exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: got %0d want %0d", name, got, exp);
            end
        end
    endtask

    task chk2;
        input [8*16-1:0] name;
        input [1:0]      got;
        input [1:0]      exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: got %0d want %0d", name, got, exp);
            end
        end
    endtask

    task chk1;
        input [8*16-1:0] name;
        input            got;
        input            exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: got %0d want %0d", name, got, exp);
            end
        end
    endtask

    //--------------------------------------------------------------- 激励任务
    // 8N1, LSB first, exactly one bit time per bit.
    task send_char;
        input [7:0] c;
        integer k;
        begin
            rx_line = 1'b0;
            #(BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin
                rx_line = c[k];
                #(BIT_NS);
            end
            rx_line = 1'b1;
            #(BIT_NS);
        end
    endtask

    // 字符串字面量在这个位宽里是右对齐的(高位补 0), 前导 0 只是填充。
    // 跳过前导 0 后发送文字, 最后补一个 LF 作为命令结束符。
    task send_str;
        input [8*15-1:0] s;
        integer k;
        reg found;
        begin
            found = 1'b0;
            for (k = 14; k >= 0; k = k - 1) begin
                if (s[8*k +: 8] != 8'h00) found = 1'b1;
                if (found) send_char(s[8*k +: 8]);
            end
            send_char(8'h0A);
        end
    endtask

    // 独立解码器: 采样每一位的中间。刻意不用 DUT 的 uart_rx。
    task uart_get_byte;
        output [7:0] c;
        integer k;
        begin
            @(negedge txd);
            #(BIT_NS/2);
            for (k = 0; k < 8; k = k + 1) begin
                #(BIT_NS);
                c[k] = txd;
            end
            #(BIT_NS);
        end
    endtask

    reg [7:0] win [0:NB-1];
    task expect_line;
        input [8*NB-1:0] exp;
        integer k, n;
        reg [7:0] c;
        reg matched;
        begin
            matched = 1'b0;
            n = 0;
            // A command can arrive halfway through a 148-byte transfer.
            // Allow that old partial line plus the next complete snapshot.
            while (!matched && (n < 3*NB)) begin
                uart_get_byte(c);
                for (k = 0; k < NB-1; k = k + 1) win[k] = win[k+1];
                win[NB-1] = c;
                n = n + 1;
                if (n >= NB) begin
                    matched = 1'b1;
                    for (k = 0; k < NB; k = k + 1)
                        if (win[k] !== exp[8*(NB-1-k) +: 8]) matched = 1'b0;
                end
            end
            checks = checks + 1;
            if (!matched) begin
                errors = errors + 1;
                $display("FAIL telemetry line never matched (%0d bytes read)", n);
                $write("  got: ");
                for (k = 0; k < NB; k = k + 1) $write("%c", win[k]);
                $write("\n");
                $write("  hex: ");
                for (k = 0; k < NB; k = k + 1) $write("%02x ", win[k]);
                $write("\n");
            end else begin
                $display("  ok  telemetry line matched after %0d bytes @%0t", n, $time);
            end
        end
    endtask

    //------------------------------------------------------------------- 主流程
    reg [8*NB-1:0] exp_default;
    reg [8*NB-1:0] exp_after;
    reg [8*NB-1:0] exp_cam;

    initial begin
        exp_default = {"M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 GF0400 BRG2 CAM0000=FF",
                       " SHP1 SZ024 FL875 BX4 AR050 CNT005 OV000A F0 R0 S00000000 Q00000000", 8'h0A};
        exp_after   = {"M2 T0100 LO0005 HI0900 MED1 GAU1 ISO0 DSP2 OVC0 EPS2 EPF2 GF0400 BRG2 CAM0000=FF",
                       " SHP1 SZ024 FL875 BX4 AR050 CNT005 OV000A F0 R0 S00000000 Q00000000", 8'h0A};

        rst_n = 1'b0;
        repeat (20) @(posedge clk25);
        rst_n = 1'b1;
        repeat (10) @(posedge clk25);

        $display("--- 1. power-on values + the immediate status line");
        chk2 ("mode", c_mode, 2'd2);
        chk11("t",    c_t,    11'd24);
        chk11("lo",   c_lo,   11'd21);
        chk11("hi",   c_hi,   11'd58);
        chk1 ("median", c_med, 1'b1);
        chk1 ("gauss",  c_gau, 1'b0);
        chk1 ("isol",   c_iso, 1'b1);
        chk2 ("disp",   c_disp, 2'd0);
        chk1 ("ovc",    c_ovc, 1'b1);
        chk11("eps",    {8'b0, c_eps}, 11'd0);
        chk2 ("px_mode_reset", p_mode, 2'd2);
        chk11("px_t_reset",    p_t,    11'd24);
        chk11("px_lo_reset",   p_lo,   11'd21);
        chk11("px_hi_reset",   p_hi,   11'd58);
        expect_line(exp_default);

        $display("--- 2. single commands");
        send_str("M1");
        chk2 ("mode_M1", c_mode, 2'd1);
        send_str("T100");
        chk11("t_T100", c_t, 11'd100);
        send_str("L5");
        chk11("lo_L5", c_lo, 11'd5);
        send_str("H900");
        chk11("hi_H900", c_hi, 11'd900);
        send_str("N0");
        chk1 ("median_N0", c_med, 1'b0);
        send_str("N7");
        chk1 ("median_N7_one", c_med, 1'b1);
        send_str("G1");
        chk1 ("gauss_G1", c_gau, 1'b1);
        send_str("I0");
        chk1 ("isol_I0", c_iso, 1'b0);
        send_str("D2");
        chk2 ("disp_D2", c_disp, 2'd2);
        send_str("C0");
        chk1 ("ovc_C0", c_ovc, 1'b0);
        send_str("E3");
        chk11("eps_E3", {8'b0, c_eps}, 11'd3);
        send_str("E99");                  // 上限 8: 再大只会把线糊粗, 直接夹住
        chk11("eps_clamp8", {8'b0, c_eps}, 11'd8);
        send_str("e2");                   // 小写 e 同样识别
        chk11("eps_lower_e2", {8'b0, c_eps}, 11'd2);

        $display("--- 3. separators, lower case, clamps, saturation");
        send_str("t=42");
        chk11("t_eq_42", c_t, 11'd42);
        send_str("t 43");
        chk11("t_sp_43", c_t, 11'd43);
        send_str("m9");
        chk2 ("mode_clamp2", c_mode, 2'd2);
        send_str("T9999");
        chk11("t_saturate", c_t, 11'd2047);
        send_str("L3000");
        chk11("lo_saturate", c_lo, 11'd2047);
        send_str("H00000000012");
        chk11("hi_leading_zeros", c_hi, 11'd12);
        send_str("Q99");
        chk11("t_after_Q99", c_t, 11'd2047);
        send_str("2416");
        chk11("t_after_bare_number", c_t, 11'd2047);

        $display("--- 4. several commands on one line");
        send_str("T7 L8 H9");
        chk11("t_multi",  c_t,  11'd7);
        chk11("lo_multi", c_lo, 11'd8);
        chk11("hi_multi", c_hi, 11'd9);

        $display("--- 5. R returns every default");
        send_str("R");
        chk2 ("mode_R", c_mode, 2'd2);
        chk11("t_R",    c_t,    11'd24);
        chk11("lo_R",   c_lo,   11'd21);
        chk11("hi_R",   c_hi,   11'd58);
        chk1 ("median_R", c_med, 1'b1);
        chk1 ("gauss_R",  c_gau, 1'b0);
        chk1 ("isol_R",   c_iso, 1'b1);
        chk2 ("disp_R",   c_disp, 2'd0);
        chk1 ("ovc_R",    c_ovc, 1'b1);
        chk11("eps_R",    {8'b0, c_eps}, 11'd0);

        $display("--- 6. the pixel-clock domain copy follows");
        send_str("T100");
        send_str("L5");
        send_str("H900");
        send_str("G1");
        send_str("I0");
        send_str("D2");
        send_str("C0");
        send_str("E2");
        repeat (40) @(posedge clkpx);
        chk2 ("px_mode", p_mode, 2'd2);
        chk11("px_t",    p_t,    11'd100);
        chk11("px_lo",   p_lo,   11'd5);
        chk11("px_hi",   p_hi,   11'd900);
        chk1 ("px_median", p_med, 1'b1);
        chk1 ("px_gauss",  p_gau, 1'b1);
        chk1 ("px_isol",   p_iso, 1'b0);
        chk2 ("px_disp",   p_disp, 2'd2);
        chk1 ("px_ovc",    p_ovc, 1'b0);
        chk11("px_eps",    {8'b0, p_eps}, 11'd2);

        $display("--- 7. status line reflects the new values");
        expect_line(exp_after);

        $display("--- 8. a second change also crosses");
        send_str("M0");
        repeat (40) @(posedge clkpx);
        chk2("px_mode_after_M0", p_mode, 2'd0);

        $display("--- 9. X<grp> 摄像头寄存器读回命令 (CAM 字段)");
        cam_rd_cnt = 0;
        send_str("X77");
        chk11("cam_grp_X77", {1'b0, c_cam_grp}, 11'd77);
        chk11("cam_rd_pulses", cam_rd_cnt[10:0], 11'd1);
        cam_val = 8'hC0;                  // 相当于 piv2_config 把那一个字节读回来了
        @(posedge clk25); cam_upd = 1'b1; @(posedge clk25); cam_upd = 1'b0;
        exp_cam = {"M0 T0100 LO0005 HI0900 MED1 GAU1 ISO0 DSP2 OVC0 EPS2 EPF2 GF0400 BRG2 CAM0077=C0",
                   " SHP1 SZ024 FL875 BX4 AR050 CNT005 OV000A F0 R0 S00000000 Q00000000", 8'h0A};
        expect_line(exp_cam);

        send_str("X999");                 // 越界要夹到最后一个真实组合 (78)
        chk11("cam_grp_clamp", {1'b0, c_cam_grp}, 11'd78);
        send_str("x5");                   // 小写 x 同样识别
        chk11("cam_grp_lower_x", {1'b0, c_cam_grp}, 11'd5);
        chk11("cam_rd_pulses3", cam_rd_cnt[10:0], 11'd3);
        cam_val = 8'h04;                  // 曝光高字节 0x04
        @(posedge clk25); cam_upd = 1'b1; @(posedge clk25); cam_upd = 1'b0;
        exp_cam = {"M0 T0100 LO0005 HI0900 MED1 GAU1 ISO0 DSP2 OVC0 EPS2 EPF2 GF0400 BRG2 CAM0005=04",
                   " SHP1 SZ024 FL875 BX4 AR050 CNT005 OV000A F0 R0 S00000000 Q00000000", 8'h0A};
        expect_line(exp_cam);

        if (errors != 0) $fatal(1,"FAIL cfg_uart: %0d errors in %0d checks", errors, checks);
        $display("SHAPE_TEST_PASS tb_alg_cfg_uart %0d checks", checks);
        $finish_and_return(0);
    end

endmodule

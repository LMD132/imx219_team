`timescale 1ns/1ps
//=============================================================================
// tb_shp_detect.v -- 形状识别 shp_detect 单模块仿真(赛题4 创意拓展⑥)
//
// 输入是"边缘图"像素流(0 或 0xFF, 和 alg_despeckle 输出 dsp_d 同一形态),
// 本 tb 直接合成 4 个图形的边缘像素, 推完一帧后发 in_vs 让状态机收官,
// 再检查 4 个框的 bbox + 分类:
//
//   图形        中心        尺寸            期望分类   期望 bbox(约)
//   空心圆环    (200,200)   R=80 环厚 4     1 = 圆     (118,118)-(282,282)
//   方框        (700,200)   140x140 框宽 4  2 = 矩形   (630,130)-(770,270)
//   三角        (200,500)   底 160 高 100   3 = 三角   (120,500)-(280,600)
//   十字        (700,550)   长 160 臂宽 40  4 = 十字   (620,470)-(780,630)
//
// 空心圆环这一条是重点: 游程按"每行最小/最大 x"合并, 所以空心和实心
// 得到同一组外轮廓跨度 -> 填充率 ≈ 785 千分比, 落在 [600, fill_th) 判圆。
//
// 跑法:  iverilog -g2005 -o sim\algo\run\tb_shp.vvp sim\algo\tb_shp_detect.v rtl\algo\shp_detect.v
//        vvp sim\algo\run\tb_shp.vvp
//=============================================================================

module tb_shp_detect;

    localparam integer W = 1280;
    localparam integer H = 720;

    integer errors = 0;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;          // 50 MHz 仿真时钟

    reg         in_vs = 1'b0;
    reg         in_de = 1'b0;
    reg  [11:0] in_x  = 12'd0;
    reg  [12:0] in_y  = 13'd0;
    reg  [7:0]  in_d  = 8'd0;

    wire [6*12-1:0] b_x0, b_x1;
    wire [6*13-1:0] b_y0, b_y1;
    wire [6*3-1:0]  b_cls;
    wire [5:0]      b_val;
    wire [9:0]      b_cnt;
    wire [15:0]     b_ovf;

    shp_detect #(
        .W(W), .H(H), .NB(8), .NBX(6)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_en(1'b1), .cfg_min_size(8'd24), .cfg_max_boxes(3'd4),
        .cfg_fill_th(10'd875), .cfg_max_area(7'd50),
        .in_vs(in_vs), .in_de(in_de), .in_x(in_x), .in_y(in_y), .in_d(in_d),
        .o_bx0(b_x0), .o_bx1(b_x1), .o_by0(b_y0), .o_by1(b_y1),
        .o_bcls(b_cls), .o_bval(b_val), .o_cnt(b_cnt), .o_ovf(b_ovf)
    );

    //----------------------------------------------------------- 图形合成
    function integer absi(input integer v);
        begin absi = (v < 0) ? -v : v; end
    endfunction

    function is_edge(input integer x, input integer y);
        integer dx, dy, d2, lx, rx;
        begin
            is_edge = 0;
            // 1) 空心圆环: 中心 (200,200), 半径 78..82 (环厚 4)
            dx = x - 200; dy = y - 200; d2 = dx*dx + dy*dy;
            if ((d2 <= 82*82) && (d2 >= 78*78)) is_edge = 1;
            // 2) 方框: 中心 (700,200), 半宽 70, 边框 4
            dx = absi(x - 700); dy = absi(y - 200);
            if ((dx <= 70) && (dy <= 70) && ((dx >= 67) || (dy >= 67))) is_edge = 1;
            // 3) 三角: 顶点 (200,500), 底 y=600, 半底 80
            if ((y >= 500) && (y <= 600)) begin
                lx = 200 - ((y - 500) * 80) / 100;
                rx = 200 + ((y - 500) * 80) / 100;
                if (absi(x - lx) <= 2) is_edge = 1;
                if (absi(x - rx) <= 2) is_edge = 1;
                if ((y >= 598) && (absi(x - 200) <= 80)) is_edge = 1;
            end
            // 4) 十字: 中心 (700,550), 臂半长 80, 臂半宽 20
            dx = absi(x - 700); dy = absi(y - 550);
            if ((dx <= 80) && (dy <= 20)) is_edge = 1;
            if ((dx <= 20) && (dy <= 80)) is_edge = 1;
        end
    endfunction

    //----------------------------------------------------------- 检查
    integer i, nvalid, seen_c, seen_r, seen_t, seen_x, cnt_chk;
    reg [2:0] cls;

    task expect_class(input integer cls_got, input integer want, input [8*20-1:0] nm);
        begin
            if (cls_got == want) begin
                $display("  ok   %0s: cls=%0d", nm, cls_got);
            end else begin
                $display("  FAIL %0s: cls=%0d want=%0d", nm, cls_got, want);
                errors = errors + 1;
            end
        end
    endtask

    integer x, y;

    // 诊断: S_COMMIT 次数 / 状态机停在哪 / FIFO 残留
    integer ncommit = 0;
    always @(posedge clk) if (dut.state == 5'd13) ncommit = ncommit + 1;
    integer nedge = 0, npix = 0, nspan = 0, nwrite = 0;
    always @(posedge clk) begin
        if (in_de && (in_d != 8'd0)) nedge = nedge + 1;
        if (dut.pix)                 npix  = npix  + 1;
        if (dut.span_end)            nspan = nspan + 1;
        if (dut.span_end && !dut.f_full) nwrite = nwrite + 1;
    end
    integer nsp_dbg = 0, nret_dbg = 0;
    always @(posedge clk) if ((dut.state >= 5'd5) && (dut.state <= 5'd8) && dut.m_busy && (dut.m_cnt == 5'd0))
        $display("    MUL%0d 起 a=%0d b=%0d", dut.state - 5'd5, dut.m_a, dut.m_b);
    always @(posedge clk) if (dut.mul_done_p)
        $display("    MUL 完 res=%0d (state=%0d)", dut.m_res, dut.state);
    always @(posedge clk) if (dut.f_pop) begin
        if (nsp_dbg < 30) $display("  span y=%0d x=%0d..%0d", dut.s_y, dut.s_x0, dut.s_x1);
        nsp_dbg = nsp_dbg + 1;
    end
    always @(posedge clk) if (dut.state == 5'd9) begin
        if (nret_dbg < 40)
            $display("  retire w=%0d h=%0d fill=%0d f1000=%0d a_th=%0d cls=%0d qual=%0d",
                     dut.ret_w, dut.ret_h, dut.ret_fill, dut.fill1000, dut.r_a_th,
                     dut.cls_now, dut.qualified);
        nret_dbg = nret_dbg + 1;
    end

    initial begin
        $dumpfile("sim/algo/run/tb_shp.vcd");
        $dumpvars(0, tb_shp_detect);

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // 一帧 1280x720 边缘流(图形外的像素 d=0)
        for (y = 0; y < H; y = y + 1) begin
            for (x = 0; x < W; x = x + 1) begin
                @(negedge clk);
                in_de <= 1'b1;
                in_x  <= x[11:0];
                in_y  <= y[12:0];
                in_d  <= is_edge(x, y) ? 8'hFF : 8'h00;
            end
        end
        // 行尾空几拍 + in_vs 上升沿(= 帧结束, 设计里 fend_req 就是这个沿)
        @(negedge clk);
        in_de <= 1'b0;
        in_d  <= 8'h00;
        repeat (50) @(posedge clk);
        @(negedge clk); in_vs <= 1'b1;
        @(negedge clk); in_vs <= 1'b0;

        // 等 FSM 把 FIFO 排空 + 逐槽退休 + S_COMMIT 提交
        repeat (8000) @(posedge clk);

        $display("--- 形状识别结果 ---");
        nvalid = 0; seen_c = 0; seen_r = 0; seen_t = 0; seen_x = 0;
        for (i = 0; i < 6; i = i + 1) begin
            if (b_val[i]) begin
                nvalid = nvalid + 1;
                cls = b_cls[i*3 +: 3];
                $display("  box%0d cls=%0d bbox=(%0d,%0d)-(%0d,%0d) w=%0d h=%0d",
                         i, cls,
                         b_x0[i*12 +: 12], b_y0[i*13 +: 13],
                         b_x1[i*12 +: 12], b_y1[i*13 +: 13],
                         b_x1[i*12 +: 12] - b_x0[i*12 +: 12] + 1,
                         b_y1[i*13 +: 13] - b_y0[i*13 +: 13] + 1);
                case (cls)
                    3'd1: seen_c = seen_c + 1;
                    3'd2: seen_r = seen_r + 1;
                    3'd3: seen_t = seen_t + 1;
                    3'd4: seen_x = seen_x + 1;
                    default: ;
                endcase
            end
        end
        $display("  提交数量 o_cnt=%0d  有效框数=%0d  FIFO溢出=%0d", b_cnt, nvalid, b_ovf);
        $display("  诊断: state=%0d f_cnt=%0d f_wp=%0d ncommit=%0d act0=%b act1=%b sum0=%0d lv0=%b",
                 dut.state, dut.f_cnt, dut.f_wp, ncommit,
                 dut.b_act[0], dut.b_act[1], dut.b_sum[0], dut.l_val[0]);
        $display("  诊断: 边缘像素=%0d pix拍=%0d 游程=%0d 入队=%0d", nedge, npix, nspan, nwrite);

        if (nvalid != 4) begin
            $display("  FAIL 有效框数=%0d, 期望 4", nvalid);
            errors = errors + 1;
        end else begin
            $display("  ok   有效框数 = 4");
        end
        expect_class(seen_c, 1, "circle(hollow ring)");
        expect_class(seen_r, 1, "rect(square frame)");
        expect_class(seen_t, 1, "triangle");
        expect_class(seen_x, 1, "cross");

        if (errors == 0) $display("PASSED");
        else             $display("FAILED  (%0d errors)", errors);
        $finish;
    end

endmodule

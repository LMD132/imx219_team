`timescale 1ns/1ps
//=============================================================================
// tb_shp_ring.v -- 空心/实心圆 细轮廓回归测试 (赛题4 形状识别)
//
// 背景: tb_shp_detect.v 用的是"实心色块/实心环带"画法; 真实相机+Canny
// 给形状识别喂的是 ~2px 细轮廓线。空心圆环在细轮廓下每行有 4 段游程
// (外左/内左/内右/外右), 必须验证它们还能并成 1 个 blob, 填充率仍≈785‰.
//
// 帧1: 4 个空心圆环 R=82, 线宽 T=4/9/16/24 (细轮廓 2px)，
//      同一高度并排，验证每种线宽、并发游程吞吐与多目标连接。
// 帧2: (200,520) 实心圆 2px线   (560,520) 实心圆 4px线
//      (920,520) 实心环带(旧画法回归)  (1100,650) 空心方框 100x100 线宽4
//      + 斜线负样本(150..350) -> 必须被丢弃
//
// 期望: 帧1 = 4 个 cls=1; 帧2 = 3 个 cls=1 + 1 个 cls=2; 斜线不出框; ovf=0.
//
// 跑法(工程根目录):
//   C:\iverilog\bin\iverilog.exe -g2005 -o sim\algo\run\tb_ring.vvp sim\algo\tb_shp_ring.v rtl\algo\shp_detect.v
//   C:\iverilog\bin\vvp.exe sim\algo\run\tb_ring.vvp
//=============================================================================

module tb_shp_ring;

    localparam integer W = 1280;
    localparam integer H = 720;
    localparam integer HTOTAL = 1650;

    integer errors = 0;
    integer frame  = 0;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;              // 50 MHz

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
    reg [4:0] last_geom_state = 0;
    always @(posedge clk) begin
        last_geom_state <= dut.geometry.state;
        if (dut.geometry.state == 19 && last_geom_state != 19)
            $display("  reject slot=%0d bbox=(%0d,%0d)-(%0d,%0d) from_state=%0d hn=%0d pn=%0d idx=%0d sum_bad=%0d recent_bad=%0d",
                     dut.ret_slot, dut.b_x0[dut.ret_slot], dut.b_y0[dut.ret_slot],
                     dut.b_x1[dut.ret_slot], dut.b_y1[dut.ret_slot],
                     last_geom_state, dut.geometry.hn, dut.geometry.pn,
                     dut.geometry.idx, dut.summary_bad[dut.ret_slot], dut.recent_bad[dut.ret_slot]);
    end

    shp_detect #(.W(W), .H(H), .NB(8), .NBX(6)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_en(1'b1), .cfg_min_size(8'd24), .cfg_max_boxes(3'd6),
        .cfg_fill_th(10'd875), .cfg_max_area(7'd50),
        .in_vs(in_vs), .in_de(in_de), .in_x(in_x), .in_y(in_y), .in_d(in_d),
        .o_bx0(b_x0), .o_bx1(b_x1), .o_by0(b_y0), .o_by1(b_y1),
        .o_bcls(b_cls), .o_bval(b_val), .o_cnt(b_cnt), .o_ovf(b_ovf)
    );

    //------------------------ 画图工具函数 ------------------------
    function integer sqi(input integer v); begin sqi = v*v; end endfunction
    function integer abi(input integer v); begin abi = (v<0)? -v : v; end endfunction

    // 空心圆环(细轮廓): 外半径 R, 线宽 T, 每条轮廓画成 (r±1) 的 2px 环带
    function ring_hit(input integer x, input integer y,
                      input integer cx, input integer cy,
                      input integer R, input integer T);
        integer d2, ri;
        begin
            d2 = sqi(x-cx) + sqi(y-cy);
            ring_hit = 0;
            if ((d2 >= (R-1)*(R-1)) && (d2 <= (R+1)*(R+1))) ring_hit = 1;
            if (T >= 3) begin
                ri = R - T;
                if ((d2 >= (ri-1)*(ri-1)) && (d2 <= (ri+1)*(ri+1))) ring_hit = 1;
            end
        end
    endfunction

    // 实心圆(细轮廓): 只有外轮廓线, 半宽 HW
    function disk_hit(input integer x, input integer y,
                      input integer cx, input integer cy,
                      input integer R, input integer HW);
        integer d2;
        begin
            d2 = sqi(x-cx) + sqi(y-cy);
            disk_hit = (d2 >= (R-HW)*(R-HW)) && (d2 <= (R+HW)*(R+HW));
        end
    endfunction

    // 实心环带(旧 tb 画法, 回归对比)
    function band_hit(input integer x, input integer y,
                      input integer cx, input integer cy,
                      input integer R, input integer T);
        integer d2;
        begin
            d2 = sqi(x-cx) + sqi(y-cy);
            band_hit = (d2 <= R*R) && (d2 >= (R-T)*(R-T));
        end
    endfunction

    // 空心方框(细轮廓): 半边长 H2, 线宽 T, 切比雪夫距离 max(|dx|,|dy|)
    function sqframe_hit(input integer x, input integer y,
                         input integer cx, input integer cy,
                         input integer H2, input integer T);
        integer ax, ay, m;
        begin
            ax = abi(x-cx); ay = abi(y-cy);
            m = (ax > ay) ? ax : ay;
            sqframe_hit = 0;
            if ((m >= H2-1) && (m <= H2+1)) sqframe_hit = 1;
            if (T >= 3) begin
                if ((m >= H2-T-1) && (m <= H2-T+1)) sqframe_hit = 1;
            end
        end
    endfunction

    // 斜线负样本 (斜率 1/5, 3px 宽)
    function line_hit(input integer x, input integer y);
        begin
            line_hit = 0;
            if ((x >= 150) && (x <= 350)) begin
                if (abi(y - (650 + (x-150)/5)) <= 1) line_hit = 1;
            end
        end
    endfunction

    function is_edge(input integer x, input integer y);
        begin
            is_edge = 0;
            if (frame == 0) begin
                if ((x >= 70) && (x <= 250) && (y >= 310) && (y <= 490)
                    && ring_hit(x,y, 160,400, 82, 4))  is_edge = 1;
                else if ((x >= 390) && (x <= 570) && (y >= 310) && (y <= 490)
                    && ring_hit(x,y, 480,400, 82, 9))  is_edge = 1;
                else if ((x >= 710) && (x <= 890) && (y >= 310) && (y <= 490)
                    && ring_hit(x,y, 800,400, 82, 16)) is_edge = 1;
                else if ((x >= 1030) && (x <= 1210) && (y >= 310) && (y <= 490)
                    && ring_hit(x,y, 1120,400, 82, 24)) is_edge = 1;
            end else begin
                if ((x >= 110) && (x <= 290) && (y >= 430) && (y <= 610)
                    && disk_hit(x,y, 200,520, 82, 1)) is_edge = 1;
                else if ((x >= 470) && (x <= 650) && (y >= 430) && (y <= 610)
                    && disk_hit(x,y, 560,520, 82, 2)) is_edge = 1;
                else if ((x >= 830) && (x <= 1010) && (y >= 430) && (y <= 610)
                    && band_hit(x,y, 920,520, 82, 4)) is_edge = 1;
                else if ((x >= 1040) && (x <= 1160) && (y >= 590) && (y <= 710)
                    && sqframe_hit(x,y, 1100,650, 50, 4)) is_edge = 1;
                else if ((x >= 145) && (x <= 355) && (y >= 640) && (y <= 700)
                    && line_hit(x,y)) is_edge = 1;
            end
        end
    endfunction

    //------------------------ 流一帧 + 收尾 ------------------------
    integer yy, xx;
    task stream_frame;
        begin
            for (yy = 0; yy < H; yy = yy + 1) begin
                for (xx = 0; xx < HTOTAL; xx = xx + 1) begin
                    @(negedge clk);
                    in_de <= (xx < W);
                    in_x  <= (xx < W) ? xx[11:0] : 12'd0;
                    in_y  <= yy[12:0];
                    in_d  <= (xx < W && is_edge(xx, yy)) ? 8'hFF : 8'h00;
                end
            end
            @(negedge clk);
            in_de <= 1'b0;
            in_d  <= 8'h00;
            repeat (50) @(posedge clk);
            @(negedge clk); in_vs <= 1'b1;
            @(negedge clk); in_vs <= 1'b0;
            repeat (50000) @(posedge clk);
        end
    endtask

    //------------------------ 结果检查 ------------------------
    integer i, nv, nc1, nc2;
    task check_frame(input integer fno, input integer want_total,
                     input integer want_c1, input integer want_c2);
        integer w, h;
        begin
            nv = 0; nc1 = 0; nc2 = 0;
            $display("--- 帧 %0d 结果 ---", fno);
            for (i = 0; i < 6; i = i + 1) begin
                if (b_val[i]) begin
                    nv = nv + 1;
                    if (b_cls[i*3 +: 3] == 3'd1) nc1 = nc1 + 1;
                    if (b_cls[i*3 +: 3] == 3'd2) nc2 = nc2 + 1;
                    w = b_x1[i*12 +: 12] - b_x0[i*12 +: 12] + 1;
                    h = b_y1[i*13 +: 13] - b_y0[i*13 +: 13] + 1;
                    $display("  box%0d cls=%0d bbox=(%0d,%0d)-(%0d,%0d) w=%0d h=%0d",
                             i, b_cls[i*3 +: 3],
                             b_x0[i*12 +: 12], b_y0[i*13 +: 13],
                             b_x1[i*12 +: 12], b_y1[i*13 +: 13], w, h);
                    if ((fno == 1) && ((w < 155) || (w > 178) || (h < 155) || (h > 178))) begin
                        $display("  FAIL box%0d 尺寸异常 w=%0d h=%0d (期望约 160~172)", i, w, h);
                        errors = errors + 1;
                    end
                end
            end
            $display("  o_cnt=%0d 有效框=%0d 圆形=%0d 矩形=%0d FIFO溢出=%0d state=%0d fend=%0d",
                     b_cnt, nv, nc1, nc2, b_ovf, dut.state, dut.fend_mode);
            if (nv != want_total) begin
                $display("  FAIL 有效框数=%0d 期望=%0d", nv, want_total);
                errors = errors + 1;
            end else $display("  ok 有效框数 = %0d", want_total);
            if (nc1 != want_c1) begin
                $display("  FAIL 圆形数=%0d 期望=%0d (有空心圆被拆成多块?)", nc1, want_c1);
                errors = errors + 1;
            end else $display("  ok 圆形 = %0d", want_c1);
            if (nc2 != want_c2) begin
                $display("  FAIL 矩形数=%0d 期望=%0d", nc2, want_c2);
                errors = errors + 1;
            end else $display("  ok 矩形 = %0d", want_c2);
        end
    endtask

    //------------------------ 主流程 ------------------------
    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        frame = 0;                      // 帧1: 4 个空心圆环(不同线宽)
        stream_frame();
        check_frame(1, 4, 4, 0);

        frame = 1;                      // 帧2: 实心圆x2 + 环带 + 空心方框 + 斜线
        stream_frame();
        check_frame(2, 4, 3, 1);

        if (b_ovf != 16'd0) begin
            $display("  FAIL FIFO 溢出 = %0d", b_ovf);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("SHAPE_TEST_PASS tb_shp_ring");
            $finish_and_return(0);
        end else begin
            $display("FAIL tb_shp_ring: %0d errors", errors);
            $finish_and_return(1);
        end
    end

endmodule

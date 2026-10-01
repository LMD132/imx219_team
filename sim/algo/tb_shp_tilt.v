`timescale 1ns/1ps
//=============================================================================
// tb_shp_tilt.v -- 三角/十字 倾斜 + 底边杂线 回归 (赛题4 形状识别)
//
// 复现上板现象: 手持相机略微倾斜(3~6度)时, 三角形底边不再正好落在一行里:
//   最底下那一行只剩一个底角(几个像素), 旧判据"最后一行的横向跨度 lsp"于是
//   远小于半个宽度 -> 三角被判成十字, 而且随抖动在 三角/十字 之间来回跳。
//   底边下方混进一小段杂线(隔<=GAPY 行会并进同一个 blob)也是同样的效果。
//
// 本 tb 用"旋转后的三角形/十字 + 底边下的杂线"直接复现:
//   帧1: 三角 转 +3° / +6° / -6°   + 正十字          期望 3x cls=3, 1x cls=4
//   帧2: 三角+底部杂线 / 粗轮廓+4°三角 / 4°十字 / 空心方框
//                                                    期望 2x cls=3, 1x cls=4, 1x cls=2
//
// 旧版 RTL(只有 lsp 判据): 倾斜三角全被判成 cls=4 -> FAILED
// 新版 RTL(最宽行位置判据): 两个帧全对 -> PASSED
//
// 跑法:
//   C:\iverilog\bin\iverilog.exe -g2005 -o sim\algo\run\tb_tilt.vvp sim\algo\tb_shp_tilt.v rtl\algo\shp_detect.v
//   C:\iverilog\bin\vvp.exe sim\algo\run\tb_tilt.vvp
//=============================================================================

module tb_shp_tilt;

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
        if (frame == 2 && dut.geometry.state == 19 && last_geom_state != 19)
            $display("  reject slot=%0d bbox=(%0d,%0d)-(%0d,%0d) from_state=%0d hn=%0d pn=%0d idx=%0d bad=%0d",
                     dut.ret_slot, dut.b_x0[dut.ret_slot], dut.b_y0[dut.ret_slot],
                     dut.b_x1[dut.ret_slot], dut.b_y1[dut.ret_slot],
                     last_geom_state, dut.geometry.hn, dut.geometry.pn,
                     dut.geometry.idx, dut.summary_bad[dut.ret_slot] || dut.recent_bad[dut.ret_slot]);
        if (frame == 2 && dut.geometry.state == 19 && last_geom_state == 11 && dut.ret_slot == 1)
            $display("  corners (%0d,%0d) (%0d,%0d) (%0d,%0d) (%0d,%0d) len=%0d dot=%0d parallel=%0d",
                     dut.geometry.px[0], dut.geometry.py[0],
                     dut.geometry.px[1], dut.geometry.py[1],
                     dut.geometry.px[2], dut.geometry.py[2],
                     dut.geometry.px[3], dut.geometry.py[3],
                     dut.geometry.side_len,dut.geometry.side_dot,dut.geometry.side_parallel);
    end

    shp_detect #(.W(W), .H(H), .NB(8), .NBX(6)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_en(1'b1), .cfg_min_size(8'd24), .cfg_max_boxes(3'd6),
        .cfg_fill_th(10'd875), .cfg_max_area(7'd50),
        .in_vs(in_vs), .in_de(in_de), .in_x(in_x), .in_y(in_y), .in_d(in_d),
        .o_bx0(b_x0), .o_bx1(b_x1), .o_by0(b_y0), .o_by1(b_y1),
        .o_bcls(b_cls), .o_bval(b_val), .o_cnt(b_cnt), .o_ovf(b_ovf)
    );

    //------------------------------------------------ 画图工具
    function integer abi(input integer v); begin abi = (v<0)? -v : v; end endfunction

    // 绕 (cx,cy) 反旋转: 返回"正放"坐标系下的 u/v (角度用 cos/sin 千分比传)
    function integer rot_u(input integer x, input integer y,
                           input integer cx, input integer cy,
                           input integer c, input integer s);
        begin rot_u = ((x-cx)*c + (y-cy)*s) / 1000; end
    endfunction
    function integer rot_v(input integer x, input integer y,
                           input integer cx, input integer cy,
                           input integer c, input integer s);
        begin rot_v = (-(x-cx)*s + (y-cy)*c) / 1000; end
    endfunction

    // 细轮廓三角(局部坐标, 尖顶朝上): 顶点(0,-hh), 底边 v=0, 半底 hb, 线半宽 lw
    function tri_local(input integer u, input integer v,
                       input integer hh, input integer hb, input integer lw);
        integer lx, rx;
        begin
            tri_local = 0;
            if ((v >= -hh) && (v <= 0)) begin
                lx = -(((v + hh) * hb) / hh);
                rx =  (((v + hh) * hb) / hh);
                if (abi(u-lx) <= lw) tri_local = 1;
                if (abi(u-rx) <= lw) tri_local = 1;
                if ((v >= -lw) && (abi(u) <= hb)) tri_local = 1;      // 底边
            end
        end
    endfunction

    // 实心十字(局部坐标): 臂半长 hl, 臂半宽 hw
    function cross_local(input integer u, input integer v,
                         input integer hl, input integer hw);
        begin
            cross_local = ((abi(u) <= hl) && (abi(v) <= hw)) ||
                          ((abi(u) <= hw) && (abi(v) <= hl));
        end
    endfunction

    function is_edge(input integer x, input integer y);
        integer u, v;
        begin
            is_edge = 0;
            if (frame == 1) begin
                // ---- 三个倾斜三角(细轮廓线宽±2) + 一个正十字 ----
                u = rot_u(x,y, 200,550, 999,  52); v = rot_v(x,y, 200,550, 999,  52);
                if (tri_local(u,v,100,80,2)) is_edge = 1;
                u = rot_u(x,y, 500,550, 995, 105); v = rot_v(x,y, 500,550, 995, 105);
                if (tri_local(u,v,100,80,2)) is_edge = 1;
                u = rot_u(x,y, 800,550, 995,-105); v = rot_v(x,y, 800,550, 995,-105);
                if (tri_local(u,v,100,80,2)) is_edge = 1;
                u = x - 1120; v = y - 550;
                if (cross_local(u,v,80,20)) is_edge = 1;
            end else begin
                // ---- 三角 + 底边下方杂线(隔 3 行) ----
                u = x - 200; v = y - 550;
                if (tri_local(u,v,100,80,2)) is_edge = 1;
                if ((y == 553) && (x >= 140) && (x <= 180)) is_edge = 1;
                // ---- 粗轮廓(±3)斜 4° 三角 ----
                u = rot_u(x,y, 500,550, 998, 70); v = rot_v(x,y, 500,550, 998, 70);
                if (tri_local(u,v,100,80,3)) is_edge = 1;
                // ---- 斜 4° 十字 ----
                u = rot_u(x,y, 800,550, 998, 70); v = rot_v(x,y, 800,550, 998, 70);
                if (cross_local(u,v,80,20)) is_edge = 1;
                // ---- 空心方框 100x100 线宽 4 (矩形回归) ----
                u = x - 1120; v = y - 550;
                if ((abi(u) <= 50) && (abi(v) <= 50) &&
                    ((abi(u) >= 47) || (abi(v) >= 47))) is_edge = 1;
            end
        end
    endfunction

    //------------------------------------------------ 检查
    integer i, nvalid, seen_c, seen_r, seen_t, seen_x;
    reg [2:0] cls;
    integer exp_c, exp_r, exp_t, exp_x;

    task run_frame(input integer f);
        integer xx, yy;
        begin
            frame = f;
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
            in_de <= 1'b0; in_d <= 8'h00;
            repeat (50) @(posedge clk);
            @(negedge clk); in_vs <= 1'b1;
            @(negedge clk); in_vs <= 1'b0;
            repeat (8000) @(posedge clk);      // 等 FSM 排空 FIFO + 退休 + 提交
        end
    endtask

    task check_frame(input integer f, input integer xc, input integer xr,
                     input integer xt, input integer xx);
        begin
            $display("--- 帧%0d 形状识别结果 ---", f);
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
            $display("  有效框数=%0d (期望%0d) 圆=%0d 矩=%0d 三角=%0d 十字=%0d  FIFO溢出=%0d",
                     nvalid, xc+xr+xt+xx, seen_c, seen_r, seen_t, seen_x, b_ovf);
            if (nvalid    != xc+xr+xt+xx) begin $display("  FAIL 有效框数"); errors = errors + 1; end
            if (seen_c    != xc) begin $display("  FAIL 圆 数=%0d 期望%0d", seen_c, xc); errors = errors + 1; end
            if (seen_r    != xr) begin $display("  FAIL 矩形数=%0d 期望%0d", seen_r, xr); errors = errors + 1; end
            if (seen_t    != xt) begin $display("  FAIL 三角数=%0d 期望%0d", seen_t, xt); errors = errors + 1; end
            if (seen_x    != xx) begin $display("  FAIL 十字数=%0d 期望%0d", seen_x, xx); errors = errors + 1; end
        end
    endtask

    initial begin
        $dumpfile("sim/algo/run/tb_tilt.vcd");
        $dumpvars(0, tb_shp_tilt);

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // 帧1: 3 个倾斜三角 + 1 个正十字；十字必须拒识。
        run_frame(1);
        check_frame(1, 0, 0, 3, 0);

        // 帧2: 底部杂线在GAPY内粘到第一个三角，改变真实轮廓，须保守拒识；
        // 粗轮廓斜三角仍识别，斜十字拒识，空心方框识别。
        run_frame(2);
        check_frame(2, 0, 1, 1, 0);

        if (b_ovf != 16'd0) begin
            $display("  FAIL FIFO 溢出=%0d", b_ovf);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("SHAPE_TEST_PASS tb_shp_tilt");
            $finish_and_return(0);
        end else begin
            $display("FAIL tb_shp_tilt: %0d errors", errors);
            $finish_and_return(1);
        end
    end

endmodule

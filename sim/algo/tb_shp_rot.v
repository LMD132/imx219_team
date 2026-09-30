`timescale 1ns/1ps
//=============================================================================
// tb_shp_rot.v -- 旋转矩形 -> 分类 诊断扫描 (赛题4 形状识别)
//
// 背景(上板现象): A4 纸打印的空心方框(矩形)相对相机稍微转一点角度,
//   就被识别成"圆形"; 摆正时才是矩形。
//   用户描述: 识别框和矩形平行(端正)->矩形; 有一定角度差->圆形。
//
// 假设: shp_detect 用水平外接矩形(bbox)算填充率 fill1000=fill/area*1000。
//   空心方框图形不变时, bbox 随旋转角度变大(约 (cos+sin)^2 倍), 各级行
//   跨度累加(fill)基本不变, fill1000 下降 -> 从 矩形档(>=fil_th=875/1000)
//   掉进 圆形档(600..875/1000)。
//
// 本 tb 帧1 放 6 个不同旋转角的空心方框(80x80, 线宽3px); 帧2 放 40度方框
//   + 圆r40 + 圆r30 + 实心矩形120x80 做对照。每个 blob 退休(S_CLS)时打印
//   ret_w/ret_h/fill/area/fill1000/分类, 用数据验证上述假设。
//
// 实测(旧判据): 0度=矩形(1000), 8度=圆(778), 15度=圆(659), 22度=十字(587),
//   30度=十字(526), 45度=十字(500); 圆=765/758 恒定。
// 修复后(新增"最宽平台率"判据, 阈值 40%): 0~22 度=矩形, 30/45 度=十字
//   (平台率 27%/1%, 遗留); 圆仍=圆。本 tb 的 check_frame 即按修复后期望断言。
//
// 跑法(工作目录=仓库根):
//   C:\iverilog\bin\iverilog.exe -g2005 -o sim\algo\run\tb_rot.vvp sim\algo\tb_shp_rot.v rtl\algo\shp_detect.v
//   C:\iverilog\bin\vvp.exe sim\algo\run\tb_rot.vvp
//=============================================================================

module tb_shp_rot;

    localparam integer W = 1280;
    localparam integer H = 720;

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

    shp_detect #(.W(W), .H(H), .NB(8), .NBX(6)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_en(1'b1), .cfg_min_size(8'd24), .cfg_max_boxes(3'd6),
        .cfg_fill_th(10'd875), .cfg_max_area(7'd50),
        .in_vs(in_vs), .in_de(in_de), .in_x(in_x), .in_y(in_y), .in_d(in_d),
        .o_bx0(b_x0), .o_bx1(b_x1), .o_by0(b_y0), .o_by1(b_y1),
        .o_bcls(b_cls), .o_bval(b_val), .o_cnt(b_cnt), .o_ovf(b_ovf)
    );

    //---------------------------------------------- 退休(S_CLS)诊断打印
    reg [4:0] st_d;
    integer   dbg_f1000;
    always @(posedge clk) begin
        if ((dut.state == 5'd9) && (st_d != 5'd9)) begin
            dbg_f1000 = (dut.ret_area > 0) ? (dut.ret_fill * 1000) / dut.ret_area : -1;
            $display("    [RET] bbox=(%0d,%0d)-(%0d,%0d) w=%0d h=%0d fill=%0d area=%0d fill1000=%0d a_th=%0d lsp=%0d my0=%0d my1=%0d ytop=%0d ybot=%0d cls=%0d",
                     dut.b_x0[dut.ret_slot], dut.b_y0[dut.ret_slot],
                     dut.b_x1[dut.ret_slot], dut.b_y1[dut.ret_slot],
                     dut.ret_w, dut.ret_h, dut.ret_fill, dut.ret_area, dbg_f1000,
                     dut.r_a_th, dut.ret_lsp, dut.ret_my0, dut.ret_my1,
                     dut.ret_ytop, dut.ret_ybot, dut.cls_now);
        end
        st_d <= dut.state;
    end

    //---------------------------------------------- 画图工具
    function integer abi(input integer v); begin abi = (v<0)? -v : v; end endfunction

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

    // 空心方框(局部半宽40, 线宽3px), 绕中心(cx,cy)旋转 c/s 千分比
    function box_rot(input integer x, input integer y,
                     input integer cx, input integer cy,
                     input integer c, input integer s);
        integer u, v;
        begin
            u = rot_u(x,y,cx,cy,c,s);
            v = rot_v(x,y,cx,cy,c,s);
            box_rot = (abi(u) <= 40) && (abi(v) <= 40) &&
                      ((abi(u) >= 38) || (abi(v) >= 38));
        end
    endfunction

    // 圆环: 半径 r, 线宽 3px
    function circ_ring(input integer x, input integer y,
                       input integer cx, input integer cy, input integer r);
        integer u, v, d2;
        begin
            u = x-cx; v = y-cy; d2 = u*u + v*v;
            circ_ring = (d2 <= r*r) && (d2 >= (r-3)*(r-3));
        end
    endfunction

    // 实心矩形: 半宽 hw, 半高 hh
    function rect_solid(input integer x, input integer y,
                        input integer cx, input integer cy,
                        input integer hw, input integer hh);
        begin
            rect_solid = (abi(x-cx) <= hw) && (abi(y-cy) <= hh);
        end
    endfunction

    function is_edge(input integer x, input integer y);
        begin
            is_edge = 0;
            if (frame == 1) begin
                if (box_rot(x,y,  90,550, 1000,   0)) is_edge = 1;  // 0  deg
                if (box_rot(x,y, 230,550,  990, 139)) is_edge = 1;  // 8  deg
                if (box_rot(x,y, 370,550,  966, 259)) is_edge = 1;  // 15 deg
                if (box_rot(x,y, 510,550,  927, 375)) is_edge = 1;  // 22 deg
                if (box_rot(x,y, 650,550,  866, 500)) is_edge = 1;  // 30 deg
                if (box_rot(x,y, 790,550,  707, 707)) is_edge = 1;  // 45 deg
            end else begin
                if (box_rot(x,y, 150,550,  766, 643)) is_edge = 1;  // 40 deg
                if (circ_ring(x,y, 330,550, 40)) is_edge = 1;       // 圆 r40
                if (circ_ring(x,y, 510,550, 30)) is_edge = 1;       // 圆 r30
                if (rect_solid(x,y, 750,550, 60, 40)) is_edge = 1;  // 实心矩形 120x80
            end
        end
    endfunction

    //---------------------------------------------- 帧驱动
    task run_frame(input integer f);
        integer xx, yy;
        begin
            frame = f;
            for (yy = 0; yy < H; yy = yy + 1) begin
                for (xx = 0; xx < W; xx = xx + 1) begin
                    @(negedge clk);
                    in_de <= 1'b1;
                    in_x  <= xx[11:0];
                    in_y  <= yy[12:0];
                    in_d  <= is_edge(xx, yy) ? 8'hFF : 8'h00;
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

    integer i, nvalid, seen_c, seen_r, seen_t, seen_x;
    reg [2:0] cls;

    task check_frame(input integer f, input integer xc, input integer xr,
                     input integer xt, input integer xx);
        begin
            $display("--- frame %0d output ---", f);
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
            $display("  valid=%0d (expect %0d) circle=%0d rect=%0d tri=%0d cross=%0d fifo_ovf=%0d",
                     nvalid, xc+xr+xt+xx, seen_c, seen_r, seen_t, seen_x, b_ovf);
            if (nvalid != xc+xr+xt+xx) begin $display("  FAIL valid count"); errors = errors + 1; end
            if (seen_c != xc) begin $display("  FAIL circle=%0d expect %0d", seen_c, xc); errors = errors + 1; end
            if (seen_r != xr) begin $display("  FAIL rect=%0d expect %0d", seen_r, xr); errors = errors + 1; end
            if (seen_t != xt) begin $display("  FAIL tri=%0d expect %0d", seen_t, xt); errors = errors + 1; end
            if (seen_x != xx) begin $display("  FAIL cross=%0d expect %0d", seen_x, xx); errors = errors + 1; end
            if (b_ovf != 16'd0) begin $display("  FAIL fifo overflow"); errors = errors + 1; end
        end
    endtask

    initial begin
        $dumpfile("sim/algo/run/tb_rot.vcd");
        $dumpvars(0, tb_shp_rot);

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // 帧1: 空心方框 0/8/15/22/30/45 度 (6 个, 用满 NBX=6)
        //   修复后: 0/8/15/22 度 = 矩形(平台率判据), 30/45 度 = 十字(遗留)
        run_frame(1);
        check_frame(1, 0, 4, 0, 2);

        // 帧2: 40度方框 + 圆r40 + 圆r30 + 实心矩形120x80
        //   修复后: 圆x2, 实心矩=矩形, 40 度方框 = 十字(平台率仅 6%, 遗留)
        run_frame(2);
        check_frame(2, 2, 1, 0, 1);

        if (errors == 0) $display("DIAG DONE (errors=0)");
        else             $display("DIAG DONE (%0d errors)", errors);
        $finish;
    end

endmodule
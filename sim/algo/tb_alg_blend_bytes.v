//=============================================================================
// tb_alg_blend_bytes.v -- alg_blend_bytes.v 单元测试(整字并行版)
//
//  金标准与 tb_alg_blend.v 完全同一份, 不另算:
//      sim/algo/model/gen_blend_golden.py -> sim/algo/blend_golden.txt
//  每行: temp alpha_q8 cur prev ref
//
//  这个测试回答的唯一问题: 把 16 个字节并成一条 128bit 字一次算完,
//  是不是和逐字节版 alg_blend.v 得到同样的东西? 所以向量按 16 行一组:
//  第 n 组的 16 行 cur 拼成 in_cur、prev 拼成 in_prev, 输出 16 个字节
//  逐个和 ref 比。组内 16 行的 temp 必须一样(生成脚本按 temp 分块穷举)。
//
//  判定与 tb_alg_blend.v 相同: maxd <= 1, alut_mism == 0, xcount == 0,
//  且 TEMP 0/25/50/75 必须 mism == 0。
//
//  运行(在 sim/algo/run 下, 见 model/check_blend_bytes.py):
//      vvp blend_bytes.vvp +GOLDEN=../blend_golden.txt
//=============================================================================
`timescale 1ns/1ps

module tb_alg_blend_bytes;
    localparam NBYTE = 16;

    reg  [6:0]              temp = 7'd0;
    reg  [NBYTE*8-1:0]      cur_w = 'd0;
    reg  [NBYTE*8-1:0]      prv_w = 'd0;

    wire [NBYTE*8-1:0]      out_w;
    wire [7:0]              alpha_q8;

    alg_blend_bytes #(.NBYTE(NBYTE)) u_dut (
        .i_temp     (temp),
        .in_cur     (cur_w),
        .in_prev    (prv_w),
        .out_data   (out_w),
        .o_alpha_q8 (alpha_q8)
    );

    integer fd, i, b;
    integer t, a8, cu, pv, rf;
    integer gt [0:NBYTE-1];
    integer gc [0:NBYTE-1];
    integer gp [0:NBYTE-1];
    integer gr [0:NBYTE-1];

    integer total = 0, mism = 0, maxd = 0, alut_mism = 0, xcount = 0;
    integer t_prev = -1, t_total = 0, t_mism = 0, t_maxd = 0, t_a8 = 0;
    integer shown = 0, r, bad_temp, got, dif, ga8, this_t;

    string gpath;

    task flush_temp;
        begin
            if (t_prev >= 0)
                $display("TEMP %0d rows %0d mism %0d maxd %0d alpha_q8 %0d",
                         t_prev, t_total, t_mism, t_maxd, t_a8);
        end
    endtask

    initial begin
        if (!$value$plusargs("GOLDEN=%s", gpath))
            gpath = "../blend_golden.txt";

        fd = $fopen(gpath, "r");
        if (fd == 0) begin
            $display("FATAL cannot open golden file: %0s", gpath);
            $finish;
        end

        begin : read_loop
        while (1) begin
            // ---- 读 16 行, 凑成一个 128bit 向量组
            r = 0;
            for (i = 0; i < NBYTE; i = i + 1) begin
                if ($fscanf(fd, "%d %d %d %d %d\n", t, a8, cu, pv, rf) == 5) begin
                    gt[i] = t;  gc[i] = cu;  gp[i] = pv;  gr[i] = rf;
                    r = r + 1;
                end
            end
            if (r != NBYTE) begin
                if (r != 0)
                    $display("FATAL golden 行数不是 16 的整数倍(尾组 %0d 行)", r);
                disable read_loop;      // 读完了, 退出 while(1)
            end

            // ---- 组内 temp 必须一致, 否则这一个字没有单一 alpha, 向量无效
            bad_temp = 0;
            for (i = 1; i < NBYTE; i = i + 1)
                if (gt[i] != gt[0]) bad_temp = 1;
            if (bad_temp) begin
                $display("FATAL 第 %0d 组的 16 行 temp 不一致: %0d/%0d",
                         total/NBYTE, gt[0], gt[1]);
                $finish;
            end

            this_t = gt[0];
            ga8    = a8;                // 组内 alpha 相同, 取最后读到的那个

            // ---- 逐档统计切换
            if (this_t != t_prev) begin
                flush_temp;
                t_prev  = this_t;
                t_total = 0;
                t_mism  = 0;
                t_maxd  = 0;
                t_a8    = ga8;
            end

            // ---- 拼字; DUT 是纯组合, 等 1ns 让输出稳定
            temp = this_t[6:0];
            for (i = 0; i < NBYTE; i = i + 1) begin
                cur_w[i*8 +: 8] = gc[i][7:0];
                prv_w[i*8 +: 8] = gp[i][7:0];
            end
            #1;

            // ---- alpha LUT: 一个字只查一次表
            if (alpha_q8 !== ga8[7:0]) begin
                alut_mism = alut_mism + 1;
                if (alut_mism <= 3)
                    $display("ALUT temp=%0d rtl=%0d golden=%0d", this_t, alpha_q8, ga8);
            end

            for (b = 0; b < NBYTE; b = b + 1) begin
                got = out_w[b*8 +: 8];
                // X 的传染性: 4 态比较, X 单独算错
                if (got === 8'bx || alpha_q8 === 8'bx) begin
                    xcount = xcount + 1;
                    dif    = 99;
                end else begin
                    dif = (got > gr[b]) ? (got - gr[b]) : (gr[b] - got);
                end

                if (shown < 3) begin
                    $display("ROWW%0d temp=%0d dut_a8=%0d byte=%0d cur=%0d prev=%0d dut=%0d py=%0d",
                             total, this_t, alpha_q8, b, gc[b], gp[b], got, gr[b]);
                    shown = shown + 1;
                end

                total   = total + 1;
                t_total = t_total + 1;

                if (dif != 0) begin
                    mism   = mism + 1;
                    t_mism = t_mism + 1;
                    if (t_mism <= 3)
                        $display("DIFF temp=%0d byte=%0d cur=%0d prev=%0d rtl=%0d py=%0d",
                                 this_t, b, gc[b], gp[b], got, gr[b]);
                end
                if (dif > maxd)   maxd   = dif;
                if (dif > t_maxd) t_maxd = dif;
            end
        end
        end

        flush_temp;
        $fclose(fd);

        $display("BLEND_SUMMARY total=%0d mism=%0d maxd=%0d alut_mism=%0d xcount=%0d",
                 total, mism, maxd, alut_mism, xcount);
        if (maxd > 1 || alut_mism != 0 || xcount != 0)
            $display("BLEND_RESULT FAIL");
        else
            $display("BLEND_RESULT PASS");
        $finish;
    end
endmodule

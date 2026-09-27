//=============================================================================
// tb_alg_blend.v -- alg_blend.v 单元测试(逐位/逐档)
//
//  金标准由 Python 现算, 不是 RTL 自己算自己:
//      sim/algo/model/gen_blend_golden.py  ->  sim/algo/blend_golden.txt
//  每行:  temp  alpha_q8  cur  prev  ref
//        ref = Python 参考(live_tune.py 的 alpha=1-temp/100 ->
//              edge_pipeline.py:338 temporal_blend, float32 截断成 uint8)
//
//  逐行喂进 DUT, 每一个 (temp, cur, prev) 都过一拍, 记录:
//      * out_data 与 ref 的差 -> mism / maxd
//      * o_alpha_q8 与金标准的 alpha_q8 是否一致 -> alut_mism(钉住 LUT)
//
//  判定: maxd <= 1 (Q8 定点化最多差 1 LSB); TEMP=0/25/50/75 必须 mism=0。
//
//  运行(在 sim/algo/run 下, 见 model/check_blend.py):
//      vvp blend.vvp +GOLDEN=../blend_golden.txt
//=============================================================================
`timescale 1ns/1ps

module tb_alg_blend;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         rst_n = 1'b0;
    reg  [6:0]  temp  = 7'd0;
    reg  [7:0]  cur   = 8'd0;
    reg  [7:0]  prv   = 8'd0;
    reg         de    = 1'b0;

    wire        out_vs, out_hs, out_de;
    wire [7:0]  out_data;
    wire [7:0]  alpha_q8;

    alg_blend u_dut (
        .clk(clk), .rst_n(rst_n),
        .i_temp(temp),
        .in_vs(1'b0), .in_hs(1'b0), .in_de(de),
        .in_cur(cur), .in_prev(prv),
        .out_vs(out_vs), .out_hs(out_hs), .out_de(out_de),
        .out_data(out_data),
        .o_alpha_q8(alpha_q8)
    );

    integer fd, r;
    integer t, a8, cu, pv, rf;
    integer got, exp_a8, dif;

    integer total = 0, mism = 0, maxd = 0, alut_mism = 0, xcount = 0;
    integer t_prev = -1, t_total = 0, t_mism = 0, t_maxd = 0, t_a8 = 0;
    integer shown = 0;

    string gpath;

    task flush_temp;
        begin
            if (t_prev >= 0) begin
                $display("TEMP %0d rows %0d mism %0d maxd %0d alpha_q8 %0d",
                         t_prev, t_total, t_mism, t_maxd, t_a8);
            end
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

        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        while ($fscanf(fd, "%d %d %d %d %d\n", t, a8, cu, pv, rf) == 5) begin
            @(negedge clk);
            temp = t[6:0];
            cur  = cu[7:0];
            prv  = pv[7:0];
            de   = 1'b1;

            @(posedge clk);
            #1;

            got    = out_data;
            exp_a8 = alpha_q8;

            // X 的传染性: dif 一旦是 X, "dif != 0" 就是假, 会假装对上了。
            // 所以用 4 态比较, 把 X 单独拎出来算错。
            if (got === 8'bx || exp_a8 === 8'bx) begin
                xcount = xcount + 1;
                dif    = 99;
            end else begin
                dif = (got > rf) ? (got - rf) : (rf - got);
            end

            if (shown < 3) begin
                $display("ROW%0d temp=%0d golden_a8=%0d dut_a8=%0d cur=%0d prev=%0d dut=%0d py=%0d",
                         total, t, a8, exp_a8, cu, pv, got, rf);
                shown = shown + 1;
            end

            if (t != t_prev) begin
                flush_temp;
                t_prev  = t;
                t_total = 0;
                t_mism  = 0;
                t_maxd  = 0;
                t_a8    = exp_a8;
            end

            total  = total + 1;
            t_total = t_total + 1;

            if (dif != 0) begin
                mism   = mism + 1;
                t_mism = t_mism + 1;
                if (t_mism <= 3)
                    $display("DIFF temp=%0d cur=%0d prev=%0d rtl=%0d py=%0d",
                             t, cu, pv, got, rf);
            end
            if (dif > maxd)  maxd  = dif;
            if (dif > t_maxd) t_maxd = dif;

            if (exp_a8 != a8) begin
                alut_mism = alut_mism + 1;
                if (alut_mism <= 3)
                    $display("ALUT temp=%0d rtl=%0d golden=%0d", t, exp_a8, a8);
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

`timescale 1ns/1ps
//=============================================================================
// tb_shp_overlay.v -- 形状框(shp_overlay)单模块仿真
//
// 场景: 1 个框, 源坐标 (100,100)-(300,300), 类别 1(圆), mode=0(左右分屏 2:1)。
//   mode 0 下屏幕列与源列的关系: 左半 screen x = 源 x/2, 右半 = 640 + 源 x/2。
//   所以框在屏幕上出现两次: 左半 (50,100)-(150,300), 右半 (690,100)-(790,300)。
//   标签 32x16 摆在框上方 2px: 屏幕 y 82..97, x 50..81。
//
// 检查: 边框命中(颜色=黄) + 左右两半都有 + 标签区点阵打成 ASCII 图肉眼核对
//       (应看到"圆形"两个字) + 框外不命中。
//
// 跑法(在工程根目录, 这里需要读到 shp_font.mem):
//   iverilog -g2005 -o sim\algo\run\tb_ovl.vvp sim\algo\tb_shp_overlay.v ^
//            rtl\algo\shp_overlay.v rtl\algo\shp_font.v rtl\simple_dual_port_ram.v
//   vvp sim\algo\run\tb_ovl.vvp
//=============================================================================

module tb_shp_overlay;

    localparam integer W = 1280;
    localparam integer H = 720;

    reg clk = 1'b0;
    always #10 clk = ~clk;              // 50 MHz 仿真时钟
    reg rst_n = 1'b0;

    reg         en   = 1'b0;
    reg         de   = 1'b0;
    reg  [11:0] x    = 12'd0;
    reg  [12:0] y    = 13'd0;
    reg  [1:0]  mode = 2'd0;

    // 1 个框: 源坐标 (100,100)-(300,300), cls=1(圆)
    reg [6*12-1:0] bx0  = 72'd0;
    reg [6*12-1:0] bx1  = 72'd0;
    reg [6*13-1:0] by0  = 78'd0;
    reg [6*13-1:0] by1  = 78'd0;
    reg [6*3-1:0]  bcls = 18'd0;
    reg [5:0]      bval = 6'd0;

    wire        ov_hit;
    wire [23:0] ov_rgb;

    shp_overlay #(.W(W), .H(H), .NBX(6), .HALF(640)) dut (
        .clk(clk), .rst_n(rst_n),
        .en(en), .de(de), .x(x), .y(y), .mode(mode),
        .bx0(bx0), .bx1(bx1), .by0(by0), .by1(by1), .bcls(bcls), .bval(bval),
        .ov_hit(ov_hit), .ov_rgb(ov_rgb)
    );

    integer errors = 0;
    integer i, j;

    reg         phit;
    reg  [23:0] prgb;

    task probe(input integer px, input integer py);
        begin
            @(negedge clk); x <= px[11:0]; y <= py[12:0]; de <= 1'b1;
            repeat (4) @(negedge clk);
            phit = ov_hit; prgb = ov_rgb;
        end
    endtask

    reg [7:0] cmap [0:16*32-1];
    integer   nhit_l, nhit_r;

    initial begin
        $dumpfile("sim/algo/run/tb_shp_overlay.vcd");
        $dumpvars(0, tb_shp_overlay);

        bx0[0 +: 12] = 12'd100;  bx1[0 +: 12] = 12'd300;
        by0[0 +: 13] = 13'd100;  by1[0 +: 13] = 13'd300;
        bcls[0 +: 3] = 3'd1;     bval[0]      = 1'b1;

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);
        en   = 1'b1;
        mode = 2'd0;

        //--------------------------------------------------------- 1) 边框
        // 左边框: 源 x=100 -> 屏幕 50 (y 100..300)
        probe(50, 200);
        if (phit && (prgb === 24'hFFFF00)) $display("  ok   左边框(50,200) 命中, 黄");
        else begin
            $display("  FAIL 左边框(50,200): hit=%b rgb=%h (期望 1/ffff00)", phit, prgb);
            errors = errors + 1;
        end
        // 上边框: 源 y=100 -> 屏幕 y=100, x 50..150 整行
        nhit_l = 0;
        for (i = 50; i <= 150; i = i + 1) begin
            probe(i, 100);
            if (phit) nhit_l = nhit_l + 1;
        end
        if (nhit_l == 101) $display("  ok   上边框整行命中 %0d/101", nhit_l);
        else begin
            $display("  FAIL 上边框: 命中 %0d/101", nhit_l);
            errors = errors + 1;
        end
        // 右半屏同样位置也要有框(源 x 相同): 屏幕 690
        probe(690, 200);
        if (phit && (prgb === 24'hFFFF00)) $display("  ok   右半屏边框(690,200) 命中");
        else begin
            $display("  FAIL 右半屏边框(690,200): hit=%b rgb=%h", phit, prgb);
            errors = errors + 1;
        end
        // 框内(非边框)不应命中
        probe(100, 200);
        if (!phit) $display("  ok   框内空白(100,200) 不命中");
        else begin
            $display("  FAIL 框内空白(100,200) 命中 rgb=%h", prgb);
            errors = errors + 1;
        end
        // 框外不应命中
        probe(400, 400);
        if (!phit) $display("  ok   框外(400,400) 不命中");
        else begin
            $display("  FAIL 框外(400,400) 命中 rgb=%h", prgb);
            errors = errors + 1;
        end

        //--------------------------------------------------------- 2) 标签
        nhit_r = 0;
        for (j = 0; j < 16; j = j + 1) begin
            for (i = 0; i < 32; i = i + 1) begin
                probe(50 + i, 82 + j);
                cmap[j*32 + i] = phit ? 8'h23 : 8'h2E;      // '#' / '.'
                if (phit) nhit_r = nhit_r + 1;
            end
        end
        $display("  标签区 32x16 (屏幕 x 50..81, y 82..97), 命中 %0d 点:", nhit_r);
        for (j = 0; j < 16; j = j + 1) begin
            $write("    y=%0d |", 82 + j);
            for (i = 0; i < 32; i = i + 1) $write("%c", cmap[j*32 + i]);
            $write("|\n");
        end
        if (nhit_r < 60) begin
            $display("  FAIL 标签点太少(%0d < 60), 字库没读出来?", nhit_r);
            errors = errors + 1;
        end else if (nhit_r > 400) begin
            $display("  FAIL 标签点太多(%0d), 整块刷白?", nhit_r);
            errors = errors + 1;
        end else begin
            $display("  ok   标签点数 %0d 在合理区间(60..400)", nhit_r);
        end

        // All four display modes retain the original source-coordinate map.
        mode=1; bcls[0 +: 3]=2; probe(100,200);
        if(!phit||prgb!==24'h00FFFF)$fatal(1,"FAIL mode1 rectangle color/coordinate");
        mode=2; bcls[0 +: 3]=3; probe(100,200);
        if(!phit||prgb!==24'hFF00FF)$fatal(1,"FAIL mode2 triangle color/coordinate");
        mode=3; bcls[0 +: 3]=1; probe(100,200);
        if(!phit||prgb!==24'hFFFF00)$fatal(1,"FAIL mode3 circle color/coordinate");

        // Class 4 is no longer supported even when an old producer asserts bval.
        mode=1; bcls[0 +: 3]=4; probe(100,200);
        if(phit)$fatal(1,"FAIL legacy cross border rendered");
        probe(100,82);
        if(phit)$fatal(1,"FAIL legacy cross label rendered");

        // Class 0's unknown glyph stays at slots 7/8, still white.
        bcls[0 +: 3]=0; nhit_r=0;
        for(j=0;j<16;j=j+1)for(i=0;i<32;i=i+1)begin
            probe(100+i,82+j);
            if(phit)begin
                nhit_r=nhit_r+1;
                if(prgb!==24'hFFFFFF)$fatal(1,"FAIL unknown label color");
            end
        end
        if(nhit_r<30)$fatal(1,"FAIL unknown glyph missing");

        // An isolated edge produces output after exactly two rising edges.
        bcls[0 +: 3]=1;
        @(negedge clk);de=0;x=400;y=400;
        repeat(3)@(negedge clk);
        de=1;x=100;y=200;
        @(posedge clk);#1;if(ov_hit)$fatal(1,"FAIL overlay early by one cycle");
        @(posedge clk);#1;if(!ov_hit||ov_rgb!==24'hFFFF00)$fatal(1,"FAIL two-cycle overlay output");
        @(negedge clk);de=0;x=400;y=400;
        @(posedge clk);#1;if(!ov_hit)$fatal(1,"FAIL overlay cleared early");
        @(posedge clk);#1;if(ov_hit)$fatal(1,"FAIL overlay delayed beyond two cycles");

        if(errors!=0)$fatal(1,"FAIL existing overlay assertions: %0d",errors);
        $display("SHAPE_TEST_PASS tb_shp_overlay modes colors labels and two-cycle latency");
        $finish_and_return(0);
    end

endmodule

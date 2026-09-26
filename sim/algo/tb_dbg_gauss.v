// 调试用: 把 alg_gauss5 的 5x5 窗口向量 + 输出 dump 出来, 定位 top-2 行差异
`timescale 1ns/1ps
module tb_dbg_gauss;
    parameter integer W=17, VEXT=5, H=9, REXT=3, LINE=W+VEXT, NPIX=W*H, GAP=VEXT+4;
    reg clk=0, rst_n=0, vs=0, hs=0, de=0;
    reg [23:0] pdata=0;
    reg [23:0] img [0:NPIX-1];
    wire pr,pb; wire [7:0] pg;
    assign pg = pdata[15:8];
    wire        g_vs,g_hs,g_de; wire [11:0] g_x; wire [12:0] g_y; wire [7:0] g_d;
    alg_gray #(.W(W),.VEXT(VEXT),.H(H),.REXT(REXT),.PAD_EDGE(1)) u_gray (
        .clk(clk),.rst_n(rst_n),.in_vs(vs),.in_hs(hs),.in_de(de),
        .in_r(pdata[23:16]),.in_g(pdata[15:8]),.in_b(pdata[7:0]),
        .out_vs(g_vs),.out_hs(g_hs),.out_de(g_de),.out_x(g_x),.out_y(g_y),.out_data(g_d));
    wire        u_vs,u_hs,u_de,o_def,o_de; wire [11:0] u_x; wire [12:0] u_y;
    wire [7:0]  o_d;
    alg_gauss5 #(.W(W),.VEXT(VEXT),.H(H)) u_gau (
        .clk(clk),.rst_n(rst_n),.en(1'b1),
        .in_vs(g_vs),.in_hs(g_hs),.in_de(g_de),.in_x(g_x),.in_y(g_y),.in_data(g_d),
        .out_vs(u_vs),.out_hs(u_hs),.out_de_full(o_def),.out_de(o_de),
        .out_x(u_x),.out_y(u_y),.out_data(o_d));
    always #5 clk = ~clk;
    integer f, fr=0; reg vsd=0;
    initial begin
        f = $fopen("dbg_gauss.txt","w");
        $readmemh("in_rgb.hex", img);
        rst_n=0; repeat(8) @(posedge clk); rst_n=1;
    end
    always @(posedge clk) begin
        vsd<=vs; if (vs&~vsd) fr<=fr+1;
        if (o_def && u_x<W && u_y<H)
            $fwrite(f,"%0d %0d %0d %050h %02x %04x %04x %04x %04x %04x %06x\n",
                fr,u_x,u_y,u_gau.win,o_d,u_gau.r0,u_gau.r1,u_gau.r2,u_gau.r3,u_gau.r4,{2'b0,u_gau.tot});
    end
    localparam integer S_IDLE=0,S_VS=1,S_ROW=2,S_GAP=3,S_END=4;
    reg [2:0] st=S_IDLE; reg [31:0] cc=0,pc=0; reg [11:0] rc=0;
    always @(posedge clk) begin
        if (!rst_n) begin st<=S_IDLE; cc<=0; pc<=0; rc<=0; vs<=0;hs<=0;de<=0; pdata<=0; end
        else case (st)
            S_IDLE: begin vs<=0;hs<=0;de<=0; st<=S_VS; cc<=0; rc<=0; end
            S_VS: begin vs<=1; de<=0; if (cc==4) begin vs<=0; st<=S_ROW; pc<=0; cc<=0; end else cc<=cc+1; end
            S_ROW: begin hs<=(pc==0); de<=1; pdata<=img[rc*W+pc];
                if (pc==W-1) begin pc<=0; st<=S_GAP; cc<=0; end else pc<=pc+1; end
            S_GAP: begin de<=0;hs<=0;
                if (cc==GAP) begin cc<=0; if (rc==H-1) st<=S_END; else begin rc<=rc+1; st<=S_ROW; end end
                else cc<=cc+1; end
            default: begin de<=0;
                if (cc==200) begin $fclose(f); $display("DBG DONE"); $finish; end else cc<=cc+1; end
        endcase
    end
endmodule
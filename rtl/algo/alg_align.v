//=============================================================================
// alg_align.v  --  把一条数据流按"图像空间"平移 (DR 行, DC 列), 用于显示对齐
//
//  结构 = alg_win 的行缓存骨架 + 一条 (DC+1) 级列移位链 + EXTRA 级输出延迟:
//    * DR 行 bank(2^ceil(log2(DR)) 块), 第 0 行写满所有 bank(EDGE 顶部)
//    * 列方向只取移位链第 DC 级
//    * EXTRA 级寄存器用于把本模块总延迟凑成与算法主链完全一致
//      ==> 输出 out_de/out_x/out_y 与主链逐拍一致, 灰度与边缘严格同像素
//
//  流水线延迟 = 3 + EXTRA (拍)
//=============================================================================

module alg_align #(
    parameter integer DW       = 8,
    parameter integer W        = 1280,
    parameter integer VEXT     = 16,
    parameter integer H        = 720,
    parameter integer DR       = 7,      // 行平移
    parameter integer DC       = 7,      // 列平移
    parameter integer EXTRA    = 1,      // 额外流水线拍数(>=1)
    parameter integer PAD_EDGE = 1
)(
    input  wire           clk,
    input  wire           rst_n,
    input  wire           in_vs,
    input  wire           in_hs,
    input  wire           in_de,
    input  wire           in_de_full,
    input  wire [11:0]    in_x,
    input  wire [12:0]    in_y,
    input  wire [DW-1:0]  in_data,
    output wire           out_vs,
    output wire           out_hs,
    output wire           out_de,
    output wire           out_de_full,
    output wire [11:0]    out_x,
    output wire [12:0]    out_y,
    output wire [DW-1:0]  out_data
);

localparam integer LINE = W + VEXT;
localparam integer AW   = $clog2(LINE);
localparam integer RB   = (DR < 2) ? 2 : (1 << $clog2(DR));
localparam integer SB   = $clog2(RB);
localparam integer DWV  = DW + 12 + 13 + 4;      // 打包 {vs,hs,de,de_full,x,y,data}

wire [DW-1:0] din_use = ((PAD_EDGE == 0) &&
                         ((in_x >= W) || (in_y >= H))) ? {DW{1'b0}} : in_data;

//--------------------------------------------------------------------------
// 行 bank
//--------------------------------------------------------------------------
wire [DW-1:0] bank_dout [0:RB-1];

genvar gk;
generate
for (gk = 0; gk < RB; gk = gk + 1) begin : g_bank
    wire we_k = in_de & ( (in_y[SB-1:0] == gk) | ((PAD_EDGE != 0) & (in_y == 13'd0)) );
    true_dual_port_ram #(
        .DATA_WIDTH  (DW),
        .ADDR_WIDTH  (AW),
        .WRITE_MODE_1("READ_FIRST"),
        .WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),
        .OUTPUT_REG_2("TRUE"),
        .RAM_INIT_FILE("")
    ) u_ram (
        .we1   (we_k),
        .clka  (clk),
        .din1  (din_use),
        .addr1 (in_x[AW-1:0]),
        .dout1 (),
        .we2   (1'b0),
        .clkb  (clk),
        .din2  ({DW{1'b0}}),
        .addr2 (in_x[AW-1:0]),
        .dout2 (bank_dout[gk])
    );
end
endgenerate

wire [RB*DW-1:0] bank_pack;
generate
for (gk = 0; gk < RB; gk = gk + 1) begin : g_pack
    assign bank_pack[gk*DW +: DW] = bank_dout[gk];
end
endgenerate

//--------------------------------------------------------------------------
// 两级对齐寄存器
//--------------------------------------------------------------------------
reg [11:0]   x1, x2;
reg [12:0]   y1, y2;
reg [DW-1:0] d1, d2;
reg          de1, de2, df1, df2, vs1, vs2, hs1, hs2;

always @(posedge clk) begin
    if (!rst_n) begin
        x1 <= 0; y1 <= 0; d1 <= 0; de1 <= 0; df1 <= 0; vs1 <= 0; hs1 <= 0;
        x2 <= 0; y2 <= 0; d2 <= 0; de2 <= 0; df2 <= 0; vs2 <= 0; hs2 <= 0;
    end else begin
        x1 <= in_x;  y1 <= in_y;  d1 <= din_use; de1 <= in_de; df1 <= in_de_full;
        vs1 <= in_vs; hs1 <= in_hs;
        x2 <= x1;    y2 <= y1;    d2 <= d1;      de2 <= de1;   df2 <= df1;
        vs2 <= vs1;  hs2 <= hs1;
    end
end

//--------------------------------------------------------------------------
// 取第 DR 行数据(与 alg_win 同法)
//--------------------------------------------------------------------------
wire [SB-1:0] sel_r = y2[SB-1:0] - DR;
wire [DW-1:0] row_d = ((PAD_EDGE == 0) && (y2 < DR)) ? {DW{1'b0}}
                                                     : (bank_pack >> (DW * sel_r));

//--------------------------------------------------------------------------
// 列方向 (DC+1) 级移位链, x==0 整链填入(EDGE)
//--------------------------------------------------------------------------
reg [DW-1:0] sr [0:DC];
integer i;
always @(posedge clk) begin
    if (!rst_n) begin
        for (i = 0; i <= DC; i = i + 1) sr[i] <= {DW{1'b0}};
    end else if (de2) begin
        sr[0] <= row_d;
        for (i = 1; i <= DC; i = i + 1)
            sr[i] <= (x2 == 12'd0) ? (PAD_EDGE ? row_d : {DW{1'b0}}) : sr[i-1];
    end
end

//--------------------------------------------------------------------------
// 核心输出 + EXTRA 级打包延迟
//--------------------------------------------------------------------------
wire        nd_de      = de2 & (x2 >= DC) & (y2 >= DR);
wire [11:0] nd_x       = x2 - DC;
wire [12:0] nd_y       = y2 - DR;
wire [DWV-1:0] core    = {vs2, hs2, nd_de, df2, nd_x, nd_y, sr[DC]};

reg [DWV-1:0] dly [0:EXTRA-1];
integer j;
always @(posedge clk) begin
    if (!rst_n) begin
        for (j = 0; j < EXTRA; j = j + 1) dly[j] <= {DWV{1'b0}};
    end else begin
        dly[0] <= core;
        for (j = 1; j < EXTRA; j = j + 1) dly[j] <= dly[j-1];
    end
end

assign out_vs      = dly[EXTRA-1][DWV-1];
assign out_hs      = dly[EXTRA-1][DWV-2];
assign out_de      = dly[EXTRA-1][DWV-3];
assign out_de_full = dly[EXTRA-1][DWV-4];
assign out_x       = dly[EXTRA-1][DW + 24 -: 12];
assign out_y       = dly[EXTRA-1][DW + 12 -: 13];
assign out_data    = dly[EXTRA-1][DW-1:0];

endmodule

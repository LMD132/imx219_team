//=============================================================================
// alg_win.v  --  赛题4  NxN 滑动窗口(行缓存 Line Buffer + 列移位寄存器)
//
//  输入: alg_gray 输出的"扩展光栅流"(行内 x = 0..LINE-1, 行号 y = 0..)
//  输出: N x N 窗口, 窗口中心 = (out_x, out_y) = (x - H2, y - H2)
//        win[(i*N + j)*DW +: DW]:  i = 0 为最上一行, j = 0 为最左一列
//
//  行缓存结构(每行一个独立 bank, bank 号 = y mod RB, RB = N-1):
//      - 每个 bank 一块真双口 RAM: 口1 写当前行, 口2 读历史行(2 拍延迟)
//      - 第 y 行流经时, bank(y-t) 中正好存着第 y-t 行  ==> t = 1..N-1 同时可读
//      - PAD_EDGE=1: 第 0 行同时写入所有 bank, 于是 y < RB 时"不存在的历史行"
//        自动读出第 0 行(等价 np.pad(mode="edge")); PAD_EDGE=0 时读出 0
//      - 列方向: 每行各一条 N 级移位寄存器, x==0 时整条填入当前像素,
//        于是左侧不足的列被复制为第 0 列(EDGE)或填充 0(ZERO)
//
//  资源: RB 块 EFX_RAM10 (每块 depth=2^$clog2(LINE) <= 2048, 宽 DW)
//  流水线延迟: 输入 -> out_de / win 共 3 拍
//=============================================================================

module alg_win #(
    parameter integer DW       = 8,
    parameter integer W        = 1280,
    parameter integer VEXT     = 16,
    parameter integer H        = 720,
    parameter integer N        = 3,
    parameter integer PAD_EDGE = 1
)(
    input  wire           clk,
    input  wire           rst_n,

    input  wire           in_vs,
    input  wire           in_hs,
    input  wire           in_de,
    input  wire [11:0]    in_x,
    input  wire [12:0]    in_y,
    input  wire [DW-1:0]  in_data,

    output reg            out_vs,
    output reg            out_hs,
    output reg            out_de,
    output reg  [11:0]    out_x,
    output reg  [12:0]    out_y,
    output wire [N*N*DW-1:0] win
);

localparam integer LINE = W + VEXT;
localparam integer AW   = $clog2(LINE);
localparam integer H2   = (N-1)/2;    // 半窗
localparam integer RB   = N-1;        // 历史行 bank 数
localparam integer SB   = (RB < 2) ? 1 : $clog2(RB);
localparam integer HLASEL = (H - 1) % RB;   // 第 H-1 行所在 bank(常量下标, 无桶形移位器)
localparam integer HLAST  = H - 1;          // 最后一行行号

//--------------------------------------------------------------------------
// 0) PAD_EDGE=0 时, 视场外(x>=W 或 y>=H)的数据一律按 0 处理, 等价 np.pad(0)
//    - EDGE 档(中值/Sobel/高斯)保持扩展像素不变;
//    - ZERO 档(膨胀/去孤立点)把行尾扩展列与帧尾复制行强制清零.
//--------------------------------------------------------------------------
wire [DW-1:0] din_use = ((PAD_EDGE == 0) &&
                         ((in_x >= W) || (in_y >= H))) ? {DW{1'b0}} : in_data;

//--------------------------------------------------------------------------
// 1) 行缓存: 每个 bank 一块真双口 RAM
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

// 打包成向量, 用"算术右移"实现 bank 选择(避免变量位选)
wire [RB*DW-1:0] bank_pack;
generate
for (gk = 0; gk < RB; gk = gk + 1) begin : g_pack
    assign bank_pack[gk*DW +: DW] = bank_dout[gk];
end
endgenerate

//--------------------------------------------------------------------------
// 2) 两级流水, 使 x2/y2/de2/d2 与 RAM 读数据(dout2, 2 拍)对齐
//--------------------------------------------------------------------------
reg [11:0]   x1, x2;
reg [12:0]   y1, y2;
reg [DW-1:0] d1, d2;
reg          de1, de2, vs1, vs2, hs1, hs2;

always @(posedge clk) begin
    if (!rst_n) begin
        x1 <= 0; y1 <= 0; d1 <= 0; de1 <= 0; vs1 <= 0; hs1 <= 0;
        x2 <= 0; y2 <= 0; d2 <= 0; de2 <= 0; vs2 <= 0; hs2 <= 0;
    end else begin
        x1 <= in_x; y1 <= in_y; d1 <= din_use; de1 <= in_de; vs1 <= in_vs; hs1 <= in_hs;
        x2 <= x1;   y2 <= y1;   d2 <= d1;      de2 <= de1;  vs2 <= vs1;  hs2 <= hs1;
    end
end

//--------------------------------------------------------------------------
// 3) 各历史行的数据(第 t 行, t = 1..N-1)
//--------------------------------------------------------------------------
wire clamp_col = (PAD_EDGE != 0) && (x2 > (W - 1));    // 列越界(x2>=W): 改用保持值
reg  [DW-1:0] hold_bot;                                // 第 H-1 行第 W-1 列(帧尾行统一用)
reg  [DW-1:0] holdc [0:N-1];                           // 各 tap 的"本行第 W-1 列"

// hold_bot: 第 H-1 行扫过 W-1 列时, 从输入流直接捕获(每次帧只有一次)
always @(posedge clk) begin
    if (!rst_n) hold_bot <= {DW{1'b0}};
    else if ((PAD_EDGE != 0) && (x2 == (W - 1)) && (y2 == HLAST)) hold_bot <= d2;
end

wire [DW-1:0] sr_in [0:N-1];

// 本段是 PAD_EDGE 语义正确性的关键(逐位对拍 np.pad(mode="edge")):
//   [行方向] 行缓存 bank 选择:
//     EDGE 顶部 y2 < gk      -> 第 0 行(bank0; 此时 y2<gk<=RB-1, 行 RB 还没写过)
//     EDGE 底部 y2 >= H-1+gk -> 第 H-1 行(常量位选 bank HLASEL)
//       必要性: 帧尾复制行会覆盖 bank, bank((y2-gk) mod RB) 可能已不是第 y2-gk 行;
//       而 y2 <= H-1+H2 <= H-1+RB/2 < H-1+RB, 故行 H-1 之后没有行的余数是 HLASEL,
//       bank HLASEL 仍保存第 H-1 行(READ_FIRST 保证同拍读到写前旧值)。
//     ZERO: y2<gk 或 y2-gk>=H -> 0
//   [列方向] 只有 EDGE 需要(x2 >= W 时取第 W-1 列):
//     行缓存读地址是 in_x = x2+2; 若直接把地址钳到 W-1, 就撞上当前行对同 bank 的写入,
//     READ_FIRST 的"读旧值"保护失效(读到当前行, 丢掉第 y2-gk 行)。
//     因此改为"保持": 在 x2 == W-1 那一拍把该 tap 的读回值存进 holdc[gk](= 该行第 W-1
//     列), 之后 x2 >= W 直接用它; 帧尾行(y2-gk > H-1)统一用 hold_bot(第 H-1 行第 W-1 列,
//     该行扫过 W-1 列时从输入流捕获)。
//   ZERO 档这些地址在 din_use 里已被写成 0, 正是补 0 语义, 不需要保持逻辑。
//   以上只改"读哪一 bank / 是否用保持值", 不新增行缓存, 不引入桶形移位器。
generate
for (gk = 0; gk < N; gk = gk + 1) begin : g_tap
    wire [SB-1:0] sel_g = y2[SB-1:0] - gk;              // = (y2 - gk) mod RB
    wire [DW-1:0] raw_g = bank_pack >> (DW * sel_g);
    wire top_g  = (PAD_EDGE != 0) && (y2 < gk);                 // 顶部越界 -> 第 0 行
    wire bot_g  = (PAD_EDGE != 0) && (y2 >= (HLAST + gk));      // 底部越界 -> 第 H-1 行
    wire zero_g = (PAD_EDGE == 0) && ((y2 < gk) || (y2 >= (H + gk)));
    wire [DW-1:0] bank_g = top_g  ? bank_pack[0 +: DW]
                         : bot_g  ? bank_pack[HLASEL*DW +: DW]
                         : zero_g ? {DW{1'b0}}
                         :          raw_g;
    wire [DW-1:0] hold_g = (y2 > (HLAST + gk)) ? hold_bot : holdc[gk];
    if (gk == 0) begin : g_t0
        // 当前行用 d2(与 bank 读等价, 且无同地址读写竞争); 帧尾复制行(y2>H-1)才读 bank HLASEL
        always @(posedge clk) begin
            if (!rst_n) holdc[0] <= {DW{1'b0}};
            else if ((PAD_EDGE != 0) && (x2 == (W - 1)) && (y2 <= HLAST)) holdc[0] <= d2;
        end
        assign sr_in[0] = clamp_col ? hold_g
                        : ((PAD_EDGE != 0) && (y2 > HLAST)) ? bank_pack[HLASEL*DW +: DW]
                        : d2;
    end else begin : g_tn
        always @(posedge clk) begin
            if (!rst_n) holdc[gk] <= {DW{1'b0}};
            else if ((PAD_EDGE != 0) && (x2 == (W - 1)) && (y2 <= (HLAST + gk))) holdc[gk] <= raw_g;
        end
        assign sr_in[gk] = clamp_col ? hold_g : bank_g;
    end
end
endgenerate

//--------------------------------------------------------------------------
// 4) 列移位寄存器 + 输出寄存(同一拍更新, 保证 win 与 out_de 对齐)
//--------------------------------------------------------------------------
reg [DW-1:0] sr [0:N-1][0:N-1];      // [row][col], col 0 = 最新列

wire nd_de = de2 & (x2 >= H2) & (y2 >= H2);
wire [11:0] nd_x = x2 - H2;
wire [12:0] nd_y = y2 - H2;

integer r, c;
always @(posedge clk) begin
    if (!rst_n) begin
        for (r = 0; r < N; r = r + 1)
            for (c = 0; c < N; c = c + 1)
                sr[r][c] <= {DW{1'b0}};
        out_de <= 1'b0; out_x <= 12'd0; out_y <= 13'd0;
        out_vs <= 1'b0; out_hs <= 1'b0;
    end else begin
        if (de2) begin
            for (r = 0; r < N; r = r + 1) begin
                sr[r][0] <= sr_in[r];
                for (c = 1; c < N; c = c + 1)
                    sr[r][c] <= (x2 == 12'd0) ? (PAD_EDGE ? sr_in[r] : {DW{1'b0}})
                                              : sr[r][c-1];
            end
        end
        out_de <= nd_de;
        out_x  <= nd_x;
        out_y  <= nd_y;
        out_vs <= vs2;
        out_hs <= hs2;
    end
end

// 打包窗口: win[(i*N+j)] : i=0 最上行, j=0 最左列(即最老列)
//   sr[N-1] = 最老的一行(第 y-N+1 行) = 窗口最上行
//   sr[r][N-1] = 最早移入的列 = 窗口最左列
reg [N*N*DW-1:0] win_pack;
integer wi, wj;
always @* begin
    for (wi = 0; wi < N; wi = wi + 1)
        for (wj = 0; wj < N; wj = wj + 1)
            win_pack[(wi*N + wj)*DW +: DW] = sr[N-1-wi][N-1-wj];
end
assign win = win_pack;

endmodule

//=============================================================================
// alg_gray.v  --  赛题4  彩色图像转灰度 + 边界扩展光栅流
//
//  功能
//    1) RGB888 -> 8bit 灰度, 定点式 Y = (77R + 150G + 29B) >> 8
//       77 = 64+8+4+1, 150 = 128+16+4+2, 29 = 32-4+1  ==> 只用移位加法, 无除法器
//    2) 输出"扩展光栅流", 供后续 NxN 窗口模块做 EDGE/PAD 边界:
//         * 每一行真实像素(W 个)之后, 紧跟 VEXT 个行尾扩展像素
//           PAD_EDGE=1 : 复制本行最后一个像素(EDGE)
//           PAD_EDGE=0 : 填 0(ZERO, 对应 cv2.dilate / remove_isolated 的 0 边界)
//         * 最后一帧行之后, 再回放 REXT 行"最后一行"(EDGE 行扩展)
//       于是:
//           源行号 y      = 0 .. H-1     真实行
//           y = H .. H+REXT-1            最后一行复制行
//           行内列号 x    = 0 .. W-1     真实列
//           x = W .. W+VEXT-1            行尾扩展列
//       每一级 NxN 窗口吃掉 (N-1)/2 行/列, 所以级联后仍能覆盖整幅画面.
//
//  流水线延迟(输入 in_de -> 输出 out_de): 1 拍
//  复位: rst_n 低有效, 同步复位
//=============================================================================

module alg_gray #(
    parameter integer W        = 1280,   // 有效宽度
    parameter integer VEXT     = 16,     // 行尾扩展像素数
    parameter integer H        = 720,    // 有效高度
    parameter integer REXT     = 8,      // 帧尾复制行数
    parameter integer PAD_EDGE = 1       // 1=EDGE 复制, 0=ZERO
)(
    input  wire        clk,
    input  wire        rst_n,

    // 源视频流(1 pixel / clk)
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,
    input  wire [7:0]  in_r,
    input  wire [7:0]  in_g,
    input  wire [7:0]  in_b,

    // 扩展光栅流
    output reg         out_vs,
    output reg         out_hs,
    output reg         out_de,
    output reg [11:0]  out_x,      // 0 .. LINE-1
    output reg [12:0]  out_y,      // 0 .. H+REXT-1
    output reg [7:0]   out_data
);

localparam integer LINE = W + VEXT;
localparam integer AW   = $clog2(LINE);   // 行存储地址宽度

//--------------------------------------------------------------------------
// 1) 灰度: 16bit 累加不溢出(最大 255*256 = 65280 < 65536)
//--------------------------------------------------------------------------
wire [15:0] r16 = {8'b0, in_r};
wire [15:0] g16 = {8'b0, in_g};
wire [15:0] b16 = {8'b0, in_b};

wire [15:0] luma_sum = (r16 << 6) + (r16 << 3) + (r16 << 2) + r16
                     + (g16 << 7) + (g16 << 4) + (g16 << 2) + (g16 << 1)
                     + (b16 << 5) - (b16 << 2) + b16;
wire [7:0]  luma_now = luma_sum[15:8];

//--------------------------------------------------------------------------
// 2) 最后一行存储(用于帧尾行回放), 2 拍读延迟
//--------------------------------------------------------------------------
reg        ext_phase;
reg        replay;
reg [11:0] xo;
reg [12:0] rd_cnt;
reg [6:0]  rep;
reg [7:0]  y_hold;

wire          store_we = in_de | ext_phase;
wire [AW-1:0] store_wa = xo[AW-1:0];
wire [7:0]    store_wd = ext_phase ? (PAD_EDGE ? y_hold : 8'd0) : luma_now;

wire [AW-1:0] rd_addr  = (rd_cnt < LINE) ? rd_cnt[AW-1:0] : (LINE-1);
wire [7:0]    rd_data;

simple_dual_port_ram #(
    .DATA_WIDTH  (8),
    .ADDR_WIDTH  (AW),
    .OUTPUT_REG  ("TRUE"),
    .RAM_INIT_FILE("")
) u_row_store (
    .wdata (store_wd),
    .waddr (store_wa),
    .we    (store_we),
    .wclk  (clk),
    .raddr (rd_addr),
    .re    (replay),
    .rclk  (clk),
    .rdata (rd_data)
);

//--------------------------------------------------------------------------
// 3) 行/列计数器
//--------------------------------------------------------------------------
reg        de_r, vs_r;
reg        started;
reg [12:0] yo;

wire line_start = in_de & ~de_r;
wire vs_rise    = in_vs & ~vs_r;

wire [12:0] yo_now   = vs_rise ? 13'd0
                                : (line_start ? (started ? (yo + 1'b1) : 13'd0) : yo);
wire        started_nx = vs_rise ? 1'b0 : (line_start ? 1'b1 : started);
wire        last_line  = (yo_now == (H-1));

//--------------------------------------------------------------------------
// 4) 输出时序
//--------------------------------------------------------------------------
always @(posedge clk) begin
    if (!rst_n) begin
        de_r <= 1'b0; vs_r <= 1'b0; started <= 1'b0;
        ext_phase <= 1'b0; replay <= 1'b0;
        xo <= 12'd0; yo <= 13'd0; rd_cnt <= 13'd0; rep <= 7'd0; y_hold <= 8'd0;
        out_vs <= 1'b0; out_hs <= 1'b0; out_de <= 1'b0;
        out_x <= 12'd0; out_y <= 13'd0; out_data <= 8'd0;
    end else begin
        de_r <= in_de;
        vs_r <= in_vs;
        out_vs <= in_vs;      // 与 out_de 同拍(1 拍延迟), 保持下游时序一致
        out_hs <= in_hs;

        if (vs_rise) begin
            yo <= 13'd0; started <= 1'b0;
            replay <= 1'b0; ext_phase <= 1'b0;
            xo <= 12'd0; rd_cnt <= 13'd0; rep <= 7'd0;
        end else begin
            yo      <= yo_now;
            started <= started_nx;
        end

        if (replay) begin
            // 帧尾行回放: 先发 (LINE+2) 次读地址, 数据 2 拍后有效
            if (rd_cnt <= (LINE+1)) begin
                out_de   <= (rd_cnt >= 2);
                out_x    <= (rd_cnt >= 2) ? (rd_cnt - 2) : 12'd0;
                out_y    <= H + rep;
                out_data <= rd_data;
                rd_cnt   <= rd_cnt + 1'b1;
            end else if (rep == (REXT-1)) begin
                replay <= 1'b0;
                out_de <= 1'b0;
            end else begin
                rep    <= rep + 1'b1;
                rd_cnt <= 13'd0;
                out_de <= 1'b0;          // 行间空拍: 不能沿用上一拍的 de
            end
        end else if (in_de) begin
            out_de   <= 1'b1;
            out_x    <= ext_phase ? 12'd0 : xo;
            out_y    <= yo_now;
            out_data <= luma_now;
            y_hold   <= luma_now;
            if (ext_phase) begin
                // 水平消隐不足(VEXT 尚未发完)就来了新行: 放弃剩余扩展像素,
                // 重新对齐到新行第 0 列, 保证帧结构不错位.
                ext_phase <= 1'b0;
                xo        <= 12'd1;
            end else if (xo == (W-1)) begin
                xo        <= W;
                ext_phase <= 1'b1;
            end else begin
                xo <= xo + 1'b1;
            end
        end else if (ext_phase) begin
            out_de   <= 1'b1;
            out_x    <= xo;
            out_y    <= yo_now;
            out_data <= PAD_EDGE ? y_hold : 8'd0;
            if (xo == (LINE-1)) begin
                ext_phase <= 1'b0;
                xo        <= 12'd0;
                if (last_line) begin
                    replay <= 1'b1;
                    rd_cnt <= 13'd0;
                    rep    <= 7'd0;
                end
            end else begin
                xo <= xo + 1'b1;
            end
        end else begin
            out_de <= 1'b0;
        end
    end
end

endmodule

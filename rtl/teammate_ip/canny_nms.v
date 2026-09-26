///////////////////////////////////////////////////////////////////////////////
// canny_nms.v — 非极大值抑制(赛题高阶④, Canny 第三步)
// 对应 Python: nms()。输入 sobel 全量程梯度幅值 mag[11:0] 与量化方向 dir,
// 沿梯度方向比较两个相邻像素, 只保留局部极大值。
// 比较规则与 OpenCV 一致: 一侧严格 >, 另一侧 >= (打破平局, 细化为单像素边)。
// 方向约定(与 Python 一致): 0=左右, 1=主对角(左上/右下), 2=上下, 3=副对角(右上/左下)
// 输出: keep ? min(mag,255) : 0   (8bit, 与 Python np.clip(...,0,255) 一致)
// 对齐: 输出延迟 OUT_DELAY = 2*DEPTH+2; 前 2 行/前 2 列无效(de=0)
///////////////////////////////////////////////////////////////////////////////
module canny_nms #(
    parameter MW    = 12,
    parameter DEPTH = 1280
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             i_de,
    input  wire             i_hs,
    input  wire             i_vs,
    input  wire [MW-1:0]    i_mag,
    input  wire [1:0]       i_dir,
    output reg              o_de,
    output reg              o_hs,
    output reg              o_vs,
    output reg  [7:0]       o_mag
);
    localparam OUT_DELAY = DEPTH + 1;    // 窗口中心 = 输入的上一行前一列

    // ---- 行缓存(3 行 mag 窗口) ----
    wire [MW-1:0] row1_in, row2_in;
    tip_line_buffer #(.W(MW), .DEPTH(DEPTH)) u_lb1 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(i_mag), .dout(row1_in));
    tip_line_buffer #(.W(MW), .DEPTH(DEPTH)) u_lb2 (
        .clk(clk), .rst_n(rst_n), .we(i_de), .din(row1_in), .dout(row2_in));

    // ---- 列打拍 ----
    reg [MW-1:0] cur0, cur1;
    reg [MW-1:0] r1_0, r1_1;
    reg [MW-1:0] r2_0, r2_1;
    always @(posedge clk) begin
        cur1 <= cur0; cur0 <= i_mag;
        r1_1 <= r1_0; r1_0 <= row1_in;
        r2_1 <= r2_0; r2_0 <= row2_in;
    end

    // ---- 行列计数 ----
    reg [15:0] hcnt, vcnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            hcnt <= 16'd0; vcnt <= 16'd0;
        end else if (i_vs) begin
            hcnt <= 16'd0; vcnt <= 16'd0;
        end else if (i_hs) begin
            hcnt <= 16'd0;
            vcnt <= vcnt + 1'b1;
        end else if (i_de) begin
            hcnt <= hcnt + 1'b1;
        end
    end
    wire win_valid = (hcnt >= 16'd2) && (vcnt >= 16'd2);

    // ---- 3x3 窗口(中心 = row1.col-1 = m11) ----
    //   w[0][0]=r2_1(左上), w[0][1]=r2_0(上), w[0][2]=row2_in(右上)
    //   w[1][0]=r1_1(左) , w[1][1]=r1_0(中心), w[1][2]=row1_in(右)
    //   w[2][0]=cur1(左下), w[2][1]=cur0(下), w[2][2]=i_mag(右下)
    wire [MW-1:0] n_left   = r1_1;       // 左
    wire [MW-1:0] n_right  = row1_in;    // 右
    wire [MW-1:0] n_up     = r2_0;       // 上
    wire [MW-1:0] n_down   = cur0;       // 下
    wire [MW-1:0] n_diag1a = r2_1;       // 主对角: 左上
    wire [MW-1:0] n_diag1b = cur1;       // 主对角: 右下
    wire [MW-1:0] n_diag2a = row2_in;    // 副对角: 右上
    wire [MW-1:0] n_diag2b = i_mag;      // 副对角: 左下
    wire [MW-1:0] m_center = r1_0;       // 中心

    // ---- 方向与 NMS 判定 ----
    wire [1:0] dir_d;
    line_delay_n #(.WIDTH(2), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dd
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(i_dir), .dout(dir_d));

    wire keep =
        (dir_d == 2'd0) ? (m_center > n_left)  && (m_center >= n_right) :
        (dir_d == 2'd1) ? (m_center > n_diag1a) && (m_center >= n_diag1b) :
        (dir_d == 2'd2) ? (m_center > n_up)    && (m_center >= n_down) :
                          (m_center > n_diag2a) && (m_center >= n_diag2b);

    wire [7:0] mag_out = keep ? ((m_center > 8'd255) ? 8'hFF : m_center[7:0]) : 8'd0;

    // ---- 输出对齐 ----
    wire win_d, hs_d, vs_d;
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dv
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(win_valid), .dout(win_d));
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_dh
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(i_hs),      .dout(hs_d));
    line_delay_n #(.WIDTH(1), .DEPTH(DEPTH), .N(OUT_DELAY)) u_ds
        (.clk(clk), .rst_n(rst_n), .we(i_de), .din(i_vs),      .dout(vs_d));

    always @(posedge clk) begin
        if (!rst_n) begin
            o_de  <= 1'b0;
            o_hs  <= 1'b0;
            o_vs  <= 1'b0;
            o_mag <= 8'd0;
        end else begin
            o_de  <= win_d;
            o_hs  <= hs_d;
            o_vs  <= vs_d;
            o_mag <= win_d ? mag_out : 8'd0;
        end
    end
endmodule

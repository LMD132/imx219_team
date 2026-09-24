// 720p streaming grayscale/Sobel display stage.
// Left half: grayscale video. Right half: binary Sobel edges.
// The two line stores are read before being overwritten by the current row.
module edge_display_720p #(
    parameter integer IMAGE_WIDTH = 1280,
    parameter [10:0] EDGE_THRESHOLD = 11'd180,
    parameter integer EDGE_THRESHOLD_SHIFT = 1
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       in_vs,
    input  wire       in_hs,
    input  wire       in_de,
    input  wire [7:0] in_r,
    input  wire [7:0] in_g,
    input  wire [7:0] in_b,
    input  wire [7:0] in_edge_gray,
    output reg        out_vs,
    output reg        out_hs,
    output reg        out_de,
    output reg  [7:0] out_r,
    output reg  [7:0] out_g,
    output reg  [7:0] out_b
);

// BT.601 integer approximation: Y = (77 R + 150 G + 29 B) / 256.
// Constant products are written as shifts and adds; no divider is inferred.
wire [15:0] r16 = {8'b0, in_r};
wire [15:0] g16 = {8'b0, in_g};
wire [15:0] b16 = {8'b0, in_b};
wire [15:0] gray_sum =
    (r16 << 6) + (r16 << 3) + (r16 << 2) + r16 +
    (g16 << 7) + (g16 << 4) + (g16 << 2) + (g16 << 1) +
    (b16 << 4) + (b16 << 3) + (b16 << 2) + b16;
wire [7:0] gray_now = gray_sum[15:8];

reg [7:0] line_a [0:IMAGE_WIDTH-1];
reg [7:0] line_b [0:IMAGE_WIDTH-1];
reg [7:0] read_a;
reg [7:0] read_b;

reg prev_de;
reg prev_vs;
reg first_line;
reg write_bank;
reg [10:0] x_count;
reg [9:0]  y_count;

wire line_start = in_de && !prev_de;
wire frame_start = in_vs && !prev_vs;
wire next_frame_line = first_line || frame_start;
wire pixel_bank = line_start ? (next_frame_line ? 1'b0 : !write_bank)
                             : write_bank;
wire [10:0] pixel_x = line_start ? 11'd0 : x_count;
wire [9:0] pixel_y = line_start ? (next_frame_line ? 10'd0 : y_count + 1'b1)
                                : y_count;

// Stage 0: grayscale, line-memory access, and pixel coordinates.
reg s0_vs;
reg s0_hs;
reg s0_de;
reg s0_bank;
reg [10:0] s0_x;
reg [9:0]  s0_y;
reg [7:0] s0_gray;
reg [7:0] s0_edge_gray;

always @(posedge clk) begin
    if (rst_n && in_de && pixel_x < IMAGE_WIDTH) begin
        read_a <= line_a[pixel_x];
        read_b <= line_b[pixel_x];
        if (pixel_bank)
            line_b[pixel_x] <= in_edge_gray;
        else
            line_a[pixel_x] <= in_edge_gray;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        prev_de    <= 1'b0;
        prev_vs    <= 1'b0;
        first_line <= 1'b1;
        write_bank <= 1'b0;
        x_count    <= 11'd0;
        y_count    <= 10'd0;
        s0_vs      <= 1'b0;
        s0_hs      <= 1'b0;
        s0_de      <= 1'b0;
        s0_bank    <= 1'b0;
        s0_x       <= 11'd0;
        s0_y       <= 10'd0;
        s0_gray    <= 8'd0;
        s0_edge_gray <= 8'd0;
    end else begin
        prev_de <= in_de;
        prev_vs <= in_vs;
        if (frame_start)
            first_line <= 1'b1;
        if (in_de) begin
            x_count <= pixel_x + 1'b1;
            s0_x <= pixel_x;
            s0_y <= pixel_y;
            s0_bank <= pixel_bank;
            s0_gray <= gray_now;
            s0_edge_gray <= in_edge_gray;
            if (line_start) begin
                first_line <= 1'b0;
                y_count <= pixel_y;
                write_bank <= pixel_bank;
            end
        end
        s0_vs <= in_vs;
        s0_hs <= in_hs;
        s0_de <= in_de;
    end
end

wire [7:0] top_now = s0_bank ? read_b : read_a;
wire [7:0] mid_now = s0_bank ? read_a : read_b;
reg [7:0] top_left, top_center;
reg [7:0] mid_left, mid_center;
reg [7:0] bot_left, bot_center;

// Each unsigned side of Gx or Gy is at most 4*255 = 1020.
wire [10:0] gx_positive = {3'b0, top_now} + {2'b0, mid_now, 1'b0}
                        + {3'b0, s0_edge_gray};
wire [10:0] gx_negative = {3'b0, top_left} + {2'b0, mid_left, 1'b0}
                        + {3'b0, bot_left};
wire [10:0] gy_positive = {3'b0, bot_left} + {2'b0, bot_center, 1'b0}
                        + {3'b0, s0_edge_gray};
wire [10:0] gy_negative = {3'b0, top_left} + {2'b0, top_center, 1'b0}
                        + {3'b0, top_now};

// Stage 1: sliding 3x3 window and Sobel side sums.
reg s1_vs;
reg s1_hs;
reg s1_de;
reg s1_window_valid;
reg [10:0] s1_x;
reg [7:0] s1_gray;
reg [7:0] s1_center;
reg [10:0] s1_gx_positive, s1_gx_negative;
reg [10:0] s1_gy_positive, s1_gy_negative;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        top_left <= 8'd0;
        top_center <= 8'd0;
        mid_left <= 8'd0;
        mid_center <= 8'd0;
        bot_left <= 8'd0;
        bot_center <= 8'd0;
        s1_vs <= 1'b0;
        s1_hs <= 1'b0;
        s1_de <= 1'b0;
        s1_window_valid <= 1'b0;
        s1_x <= 11'd0;
        s1_gray <= 8'd0;
        s1_center <= 8'd0;
        s1_gx_positive <= 11'd0;
        s1_gx_negative <= 11'd0;
        s1_gy_positive <= 11'd0;
        s1_gy_negative <= 11'd0;
    end else begin
        s1_vs <= s0_vs;
        s1_hs <= s0_hs;
        s1_de <= s0_de;
        s1_x <= s0_x;
        s1_gray <= s0_gray;
        s1_window_valid <= s0_de && s0_x >= 11'd2 && s0_y >= 10'd2;
        if (s0_de) begin
            s1_center <= s0_edge_gray;
            top_left <= top_center;
            top_center <= top_now;
            mid_left <= mid_center;
            mid_center <= mid_now;
            bot_left <= bot_center;
            bot_center <= s0_edge_gray;
            s1_gx_positive <= gx_positive;
            s1_gx_negative <= gx_negative;
            s1_gy_positive <= gy_positive;
            s1_gy_negative <= gy_negative;
        end
    end
end

wire [10:0] gx_abs = (s1_gx_positive >= s1_gx_negative)
                   ? s1_gx_positive - s1_gx_negative
                   : s1_gx_negative - s1_gx_positive;
wire [10:0] gy_abs = (s1_gy_positive >= s1_gy_negative)
                   ? s1_gy_positive - s1_gy_negative
                   : s1_gy_negative - s1_gy_positive;
wire [11:0] magnitude = {1'b0, gx_abs} + {1'b0, gy_abs};
// The gradient magnitude of a real edge scales with local contrast, not with
// absolute brightness. A fixed threshold therefore loses low contrast objects
// (a person in dim light) while a bright source (a phone screen) clears it
// easily. Scale the threshold with the gray level at the window centre and use
// EDGE_THRESHOLD as a noise floor. EDGE_THRESHOLD_SHIFT = 8 disables the
// adaptive term and restores a purely fixed threshold.
wire [10:0] local_threshold = {3'b0, s1_center} >> EDGE_THRESHOLD_SHIFT;
wire [10:0] active_threshold = (local_threshold > EDGE_THRESHOLD)
                             ? local_threshold : EDGE_THRESHOLD;
wire edge_pixel = s1_window_valid && magnitude >= {1'b0, active_threshold};

// Stage 2: synchronized HDMI pixel. The split is intentionally simple for
// first hardware validation; the two halves currently show their own crop.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        out_vs <= 1'b0;
        out_hs <= 1'b0;
        out_de <= 1'b0;
        out_r <= 8'd0;
        out_g <= 8'd0;
        out_b <= 8'd0;
    end else begin
        out_vs <= s1_vs;
        out_hs <= s1_hs;
        out_de <= s1_de;
        if (!s1_de) begin
            out_r <= 8'd0;
            out_g <= 8'd0;
            out_b <= 8'd0;
        end else if (s1_x < IMAGE_WIDTH/2) begin
            out_r <= s1_gray;
            out_g <= s1_gray;
            out_b <= s1_gray;
        end else if (s1_x == IMAGE_WIDTH/2) begin
            out_r <= 8'hff;
            out_g <= 8'hff;
            out_b <= 8'hff;
        end else begin
            out_r <= edge_pixel ? 8'hff : 8'h00;
            out_g <= edge_pixel ? 8'hff : 8'h00;
            out_b <= edge_pixel ? 8'hff : 8'h00;
        end
    end
end

endmodule

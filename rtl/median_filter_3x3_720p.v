// Streaming 3x3 median filter for the Sobel input path.
// Two BRAM line stores form the window. Nine registered odd-even sorting
// passes keep the comparator depth to one 8-bit compare per pixel clock.
module median_filter_3x3_720p #(
    parameter integer IMAGE_WIDTH = 1280
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       in_vs,
    input  wire       in_hs,
    input  wire       in_de,
    input  wire [7:0] in_r,
    input  wire [7:0] in_g,
    input  wire [7:0] in_b,
    output reg        out_vs,
    output reg        out_hs,
    output reg        out_de,
    output reg  [7:0] out_raw_gray,
    output reg  [7:0] out_median_gray
);

// BT.601 approximation, matching the downstream display stage.
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
reg [7:0] read_a, read_b;
reg prev_de, prev_vs, first_line, write_bank;
reg [10:0] x_count;
reg [9:0] y_count;
wire line_start = in_de && !prev_de;
wire frame_start = in_vs && !prev_vs;
wire next_frame_line = first_line || frame_start;
wire pixel_bank = line_start ? (next_frame_line ? 1'b0 : !write_bank)
                             : write_bank;
wire [10:0] pixel_x = line_start ? 11'd0 : x_count;
wire [9:0] pixel_y = line_start ? (next_frame_line ? 10'd0 : y_count + 1'b1)
                                : y_count;

reg s0_vs, s0_hs, s0_de, s0_bank;
reg [10:0] s0_x;
reg [9:0] s0_y;
reg [7:0] s0_gray;

always @(posedge clk) begin
    if (rst_n && in_de && pixel_x < IMAGE_WIDTH) begin
        read_a <= line_a[pixel_x];
        read_b <= line_b[pixel_x];
        if (pixel_bank)
            line_b[pixel_x] <= gray_now;
        else
            line_a[pixel_x] <= gray_now;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        prev_de <= 1'b0;
        prev_vs <= 1'b0;
        first_line <= 1'b1;
        write_bank <= 1'b0;
        x_count <= 11'd0;
        y_count <= 10'd0;
        s0_vs <= 1'b0;
        s0_hs <= 1'b0;
        s0_de <= 1'b0;
        s0_bank <= 1'b0;
        s0_x <= 11'd0;
        s0_y <= 10'd0;
        s0_gray <= 8'd0;
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

// Stage 0 captures the nine window pixels. Each later stage sorts disjoint
// neighbor pairs; after nine odd-even phases element 4 is the median.
reg [7:0] sort_stage [0:9][0:8];
reg [9:0] de_pipe, hs_pipe, vs_pipe, valid_pipe;
reg [7:0] raw_pipe [0:9];
integer k;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        top_left <= 8'd0;
        top_center <= 8'd0;
        mid_left <= 8'd0;
        mid_center <= 8'd0;
        bot_left <= 8'd0;
        bot_center <= 8'd0;
        de_pipe <= 10'd0;
        hs_pipe <= 10'd0;
        vs_pipe <= 10'd0;
        valid_pipe <= 10'd0;
        for (k = 0; k < 10; k = k + 1)
            raw_pipe[k] <= 8'd0;
    end else begin
        if (s0_de) begin
            top_left <= top_center;
            top_center <= top_now;
            mid_left <= mid_center;
            mid_center <= mid_now;
            bot_left <= bot_center;
            bot_center <= s0_gray;
        end
        de_pipe[0] <= s0_de;
        hs_pipe[0] <= s0_hs;
        vs_pipe[0] <= s0_vs;
        valid_pipe[0] <= s0_de && s0_x >= 11'd2 && s0_y >= 10'd2;
        raw_pipe[0] <= s0_gray;
        for (k = 1; k < 10; k = k + 1) begin
            de_pipe[k] <= de_pipe[k-1];
            hs_pipe[k] <= hs_pipe[k-1];
            vs_pipe[k] <= vs_pipe[k-1];
            valid_pipe[k] <= valid_pipe[k-1];
            raw_pipe[k] <= raw_pipe[k-1];
        end
    end
end

always @(posedge clk) begin
    sort_stage[0][0] <= top_left;
    sort_stage[0][1] <= top_center;
    sort_stage[0][2] <= top_now;
    sort_stage[0][3] <= mid_left;
    sort_stage[0][4] <= mid_center;
    sort_stage[0][5] <= mid_now;
    sort_stage[0][6] <= bot_left;
    sort_stage[0][7] <= bot_center;
    sort_stage[0][8] <= s0_gray;
end

genvar phase, index;
generate
    for (phase = 0; phase < 9; phase = phase + 1) begin: sort_phase
        for (index = 0; index < 9; index = index + 1) begin: sort_element
            if (index < 8 && ((index + phase) % 2) == 0) begin: lower
                always @(posedge clk)
                    sort_stage[phase+1][index] <=
                        (sort_stage[phase][index] <= sort_stage[phase][index+1])
                        ? sort_stage[phase][index] : sort_stage[phase][index+1];
            end else if (index > 0 && ((index - 1 + phase) % 2) == 0) begin: upper
                always @(posedge clk)
                    sort_stage[phase+1][index] <=
                        (sort_stage[phase][index-1] >= sort_stage[phase][index])
                        ? sort_stage[phase][index-1] : sort_stage[phase][index];
            end else begin: passthrough
                always @(posedge clk)
                    sort_stage[phase+1][index] <= sort_stage[phase][index];
            end
        end
    end
endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        out_vs <= 1'b0;
        out_hs <= 1'b0;
        out_de <= 1'b0;
        out_raw_gray <= 8'd0;
        out_median_gray <= 8'd0;
    end else begin
        out_vs <= vs_pipe[9];
        out_hs <= hs_pipe[9];
        out_de <= de_pipe[9];
        out_raw_gray <= raw_pipe[9];
        out_median_gray <= valid_pipe[9] ? sort_stage[9][4] : raw_pipe[9];
    end
end

endmodule

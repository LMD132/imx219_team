////////////////////////////////////////////////////////////////////////////
//
// gauss3_720p.v
//
// One 3x3 binomial (1-2-1) smoothing stage for the Sobel input path.
//
// Why this exists
// ---------------
// The board's Sobel threshold is max(center >> shift, floor). In the dark
// scenes of the competition the floor dominates, so the threshold is a fixed
// number of gradient counts and the only thing that decides whether a faint
// contour survives is the noise amplitude of the gradient magnitude. Measured
// on a captured dim scene (frame mean 25/255, pixel noise sigma 3.2 gray
// levels), the 3x3 median already in the chain leaves a per-pixel noise of
// 1.73, and the resulting edge map flickers: 49 % of the marked pixels change
// from one frame to the next, and only 24 % of them are stable structure.
// Adding this stage drops the noise to 0.93, cuts the flicker to 21 % and
// raises the stable share to 58 % - with the same threshold. Two of these
// stages in series (an effective 5x5 Gaussian) are even better, which is why
// the top level instantiates two and lets i_enable select 0, 1 or 2 of them.
//
// Structure
// ---------
// Same window and the same two-BRAM line-store pattern as
// median_filter_3x3_720p.v, but the arithmetic is a plain weighted sum:
//
//     corners 1, cross 2, centre 4, total 16  ->  sum >> 4
//
// A power-of-two divide needs no divider and no multiplier, unlike a box
// mean (divide by 9). The binomial kernel also keeps a step edge at full
// amplitude and only spreads it over one extra pixel, while a real
// (1-2-1)^2 kernel costs almost nothing in extra LUTs.
//
// Latency, stated because it is the one thing that is easy to get wrong:
// two clock cycles plus the two line stores of the window. i_enable does NOT
// change the latency - when it is low the stage still runs its delay line and
// outputs the centre tap - so switching it live cannot make the picture jump.
//
////////////////////////////////////////////////////////////////////////////

module gauss3_720p #(
    parameter integer IMAGE_WIDTH = 1280
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       i_enable,     // 0 = pass the centre tap straight through
    input  wire       in_vs,
    input  wire       in_hs,
    input  wire       in_de,
    input  wire [7:0] in_gray,
    output reg        out_vs,
    output reg        out_hs,
    output reg        out_de,
    output reg  [7:0] out_gray
);

    // ---------------------------------------------------------------
    // Two line stores, read before write, exactly as in the median filter.
    // ---------------------------------------------------------------
    reg [7:0] line_a [0:IMAGE_WIDTH-1];
    reg [7:0] line_b [0:IMAGE_WIDTH-1];
    reg [7:0] read_a, read_b;
    reg prev_de, prev_vs, first_line, write_bank;
    reg [10:0] x_count;
    reg [9:0]  y_count;

    wire line_start      = in_de && !prev_de;
    wire frame_start     = in_vs && !prev_vs;
    wire next_frame_line = first_line || frame_start;
    wire pixel_bank = line_start ? (next_frame_line ? 1'b0 : !write_bank)
                                 : write_bank;
    wire [10:0] pixel_x = line_start ? 11'd0 : x_count;
    wire [9:0]  pixel_y = line_start ? (next_frame_line ? 10'd0 : y_count + 10'd1)
                                     : y_count;

    reg s0_vs, s0_hs, s0_de, s0_bank;
    reg [10:0] s0_x;
    reg [9:0]  s0_y;
    reg [7:0]  s0_gray;

    always @(posedge clk) begin
        if (rst_n && in_de && pixel_x < IMAGE_WIDTH) begin
            read_a <= line_a[pixel_x];
            read_b <= line_b[pixel_x];
            if (pixel_bank)
                line_b[pixel_x] <= in_gray;
            else
                line_a[pixel_x] <= in_gray;
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
        end else begin
            prev_de <= in_de;
            prev_vs <= in_vs;
            if (frame_start) first_line <= 1'b1;
            if (in_de) begin
                x_count <= pixel_x + 1'b1;
                s0_x    <= pixel_x;
                s0_y    <= pixel_y;
                s0_bank <= pixel_bank;
                s0_gray <= in_gray;
                if (line_start) begin
                    first_line <= 1'b0;
                    y_count    <= pixel_y;
                    write_bank <= pixel_bank;
                end
            end
            s0_vs <= in_vs;
            s0_hs <= in_hs;
            s0_de <= in_de;
        end
    end

    wire [7:0] top_now = s0_bank ? read_b : read_a;   // two lines back
    wire [7:0] mid_now = s0_bank ? read_a : read_b;   // one line back

    // The six delayed taps plus s0_gray form the nine window elements. The
    // geometry is the one already proven by median_filter_3x3_720p.v, so the
    // three rows and the three columns line up on the same pixels.
    reg [7:0] top_left, top_center;
    reg [7:0] mid_left, mid_center;
    reg [7:0] bot_left, bot_center;

    // Stage 1: the three row sums (weight 1 on the ends, 2 in the middle).
    wire [9:0] row_top = {2'b0, top_left}  + {1'b0, top_center, 1'b0} + {2'b0, top_now};
    wire [9:0] row_mid = {2'b0, mid_left}  + {1'b0, mid_center, 1'b0} + {2'b0, mid_now};
    wire [9:0] row_bot = {2'b0, bot_left}  + {1'b0, bot_center, 1'b0} + {2'b0, s0_gray};
    wire [11:0] gsum   = {2'b0, row_top} + {1'b0, row_mid, 1'b0} + {2'b0, row_bot};

    reg [7:0] gauss_r;      // gsum >> 4, the filtered centre pixel
    reg [7:0] through_r;    // mid_center, the same pixel without the filter
    reg       valid_d;      // the window is inside the picture
    reg       s1_vs, s1_hs, s1_de;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            top_left   <= 8'd0;
            top_center <= 8'd0;
            mid_left   <= 8'd0;
            mid_center <= 8'd0;
            bot_left   <= 8'd0;
            bot_center <= 8'd0;
            gauss_r    <= 8'd0;
            through_r  <= 8'd0;
            valid_d    <= 1'b0;
            s1_vs      <= 1'b0;
            s1_hs      <= 1'b0;
            s1_de      <= 1'b0;
            out_vs     <= 1'b0;
            out_hs     <= 1'b0;
            out_de     <= 1'b0;
            out_gray   <= 8'd0;
        end else begin
            if (s0_de) begin
                top_left   <= top_center;
                top_center <= top_now;
                mid_left   <= mid_center;
                mid_center <= mid_now;
                bot_left   <= bot_center;
                bot_center <= s0_gray;
            end

            gauss_r   <= gsum[11:4];       // / 16, no divider inferred
            through_r <= mid_center;
            // The window needs a full row above and a full column to the left.
            valid_d   <= s0_de && (s0_x >= 11'd2) && (s0_y >= 10'd2);

            s1_vs <= s0_vs;
            s1_hs <= s0_hs;
            s1_de <= s0_de;

            out_vs <= s1_vs;
            out_hs <= s1_hs;
            out_de <= s1_de;
            // Inside the picture the filter is used; on the two pixel borders
            // and when the stage is disabled the centre tap passes through, so
            // there are no black seams and no latency change.
            out_gray <= (i_enable && valid_d) ? gauss_r : through_r;
        end
    end

endmodule

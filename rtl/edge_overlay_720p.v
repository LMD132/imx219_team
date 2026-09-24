////////////////////////////////////////////////////////////////////////////
//
// edge_overlay_720p.v
//
// Post-processing stage for the composited split-screen output of
// edge_display_720p.v. It sits between the Sobel stage and the DVI encoder and
// adds two competition features to the binary right half:
//
//   1. Despeckle.
//      A textbook 3x3 erosion (9-input AND) is WRONG here: Sobel edges are
//      only 1-2 pixels wide and a one-pixel-wide line has exactly three set
//      pixels inside its own 3x3 window, so a 9-input AND would erase every
//      edge in the picture. The rule used here is a count instead:
//
//          keep the centre pixel when the centre is set AND at least
//          i_despeckle_min of its eight neighbours are set
//
//      Counts seen in practice:
//        isolated speck    1   -> removed by min = 2
//        two-pixel speck   2   -> removed by min = 3
//        straight line     3   -> kept    by min = 3 (recommended setting)
//        thicker / corner  4-6 -> kept
//      i_despeckle_min = 0 bypasses the filter and is the A/B reference.
//
//   2. Bounding box of the edge region (competition task 6, simple object
//      localisation). The box is the min/max of the despeckled edge pixels of
//      one frame, latched at the frame boundary and drawn in red over the NEXT
//      frame, so no extra frame buffer is needed.
//
//      Honest limitation: a plain min/max over all edge pixels expands to the
//      whole frame as soon as the background carries texture anywhere. It is
//      meaningful for a mostly uniform scene (dark room, single subject). If
//      the box always fills the panel, the fix is a row/column projection with
//      a relative threshold - not a different min/max.
//
// Timing conventions, spelled out because they are easy to get wrong:
//
//   * in_* presents a new pixel on every in_de cycle; x_now/y_now are that
//     pixel's coordinates.
//   * out_* is in_* delayed by exactly one clock, so the pixel presented on
//     the output during a cycle is the one that entered on the PREVIOUS cycle.
//     Its coordinates live in s_x/s_y, which is why every output-side decision
//     (left/edge split, white separator column, box outline) uses s_x/s_y and
//     not x_now/y_now.
//   * The 3x3 window is centred on the pixel presented on the output, i.e. on
//     b_d1 = (x_now-1, y_now), with the two earlier rows coming from the two
//     binary line stores. The three row taps must line up on the same column,
//     so sr1 is IMAGE_WIDTH+2 bits wide and bit IMAGE_WIDTH+1 is exactly one
//     line back AND one column left. A narrower register would skew the upper
//     row of the window by one column.
//   * The stores shift once per active pixel only (x_now < IMAGE_WIDTH), so the
//     blanking interval cannot desynchronise them.
//   * The last column of the right half (s_x = IMAGE_WIDTH-1) is presented on
//     the first cycle of the next line, where the window taps are invalid, so
//     that single column is drawn black. It is the extreme right edge of the
//     picture and is not visible in practice.
//
////////////////////////////////////////////////////////////////////////////

module edge_overlay_720p #(
    parameter integer IMAGE_WIDTH   = 1280,
    parameter integer IMAGE_HEIGHT  = 720,
    parameter integer BOX_THICKNESS = 2
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,
    input  wire [7:0]  in_r,
    input  wire [7:0]  in_g,
    input  wire [7:0]  in_b,
    input  wire [3:0]  i_despeckle_min,   // 0 = filter off
    output reg         out_vs,
    output reg         out_hs,
    output reg         out_de,
    output reg  [7:0]  out_r,
    output reg  [7:0]  out_g,
    output reg  [7:0]  out_b
);

    // Column of the white separator drawn by edge_display_720p. Everything to
    // the right of it is the binary edge map.
    localparam integer HALF_X = IMAGE_WIDTH / 2;

    // ---------------------------------------------------------------
    // Pixel coordinates, mirroring the pattern already proven in
    // edge_display_720p.v (a counter holding the *next* value, with the
    // current one derived from line_start).
    // ---------------------------------------------------------------
    reg        prev_de;
    reg        prev_vs;
    reg        first_line;
    reg [10:0] x_count;
    reg [9:0]  y_count;

    // Coordinates of the pixel presented on the output.
    reg [10:0] s_x;
    reg [9:0]  s_y;

    wire line_start      = in_de && !prev_de;
    wire frame_start     = in_vs && !prev_vs;
    wire next_frame_line = first_line || frame_start;

    wire [10:0] x_now = line_start ? 11'd0 : x_count;
    wire [9:0]  y_now = line_start ? (next_frame_line ? 10'd0 : y_count + 10'd1)
                                   : y_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_de    <= 1'b0;
            prev_vs    <= 1'b0;
            first_line <= 1'b1;
            x_count    <= 11'd0;
            y_count    <= 10'd0;
            s_x        <= 11'd0;
            s_y        <= 10'd0;
        end else begin
            prev_de <= in_de;
            prev_vs <= in_vs;
            if (frame_start) first_line <= 1'b1;
            if (in_de) begin
                x_count <= x_now + 1'b1;
                s_x     <= x_now;
                s_y     <= y_now;
                if (line_start) begin
                    first_line <= 1'b0;
                    y_count    <= y_now;
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // Binary extraction and the two binary line stores.
    // ---------------------------------------------------------------
    wire in_right = in_de && (x_now > HALF_X) && (x_now < IMAGE_WIDTH);
    wire bin_in   = in_right ? (in_r != 8'h00) : 1'b0;

    reg [IMAGE_WIDTH+1:0] sr1;    // one line deep
    reg [IMAGE_WIDTH:0]   sr2;    // two lines deep
    reg                   b_d1;
    reg                   b_d2;

    wire b_prev1  = sr1[IMAGE_WIDTH];
    wire shift_en = in_de && (x_now < IMAGE_WIDTH);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr1  <= {(IMAGE_WIDTH+2){1'b0}};
            sr2  <= {(IMAGE_WIDTH+1){1'b0}};
            b_d1 <= 1'b0;
            b_d2 <= 1'b0;
        end else if (shift_en) begin
            sr1  <= {sr1[IMAGE_WIDTH:0], bin_in};
            sr2  <= {sr2[IMAGE_WIDTH-1:0], b_prev1};
            b_d1 <= bin_in;
            b_d2 <= b_d1;
        end
    end

    // ---------------------------------------------------------------
    // 3x3 window centred on b_d1. nbr_cnt counts the eight neighbours only;
    // the centre is checked separately.
    // ---------------------------------------------------------------
    wire [3:0] nbr_cnt = {3'b0, sr2[IMAGE_WIDTH]}   + {3'b0, sr2[IMAGE_WIDTH-1]}
                       + {3'b0, sr2[IMAGE_WIDTH-2]} + {3'b0, sr1[IMAGE_WIDTH+1]}
                       + {3'b0, sr1[IMAGE_WIDTH]}   + {3'b0, sr1[IMAGE_WIDTH-1]}
                       + {3'b0, b_d2}               + {3'b0, bin_in};

    wire center    = b_d1;
    wire window_ok = in_de && (x_now >= 11'd2) && (y_now >= 10'd2);

    wire edge_clean = window_ok
                    ? ((i_despeckle_min == 4'd0) ? center
                                                 : (center && (nbr_cnt >= i_despeckle_min)))
                    : 1'b0;

    // ---------------------------------------------------------------
    // Bounding box accumulation over one frame. s_x/s_y are the coordinates of
    // the pixel edge_clean refers to, so the two stay in step by construction.
    // ---------------------------------------------------------------
    wire box_pix = edge_clean && (s_x > HALF_X) && (s_x < IMAGE_WIDTH);

    reg [10:0] acc_x_lo;
    reg [10:0] acc_x_hi;
    reg [9:0]  acc_y_lo;
    reg [9:0]  acc_y_hi;
    reg        acc_seen;

    // Latched at the frame boundary, used to draw the next frame.
    reg [10:0] box_x_lo;
    reg [10:0] box_x_hi;
    reg [9:0]  box_y_lo;
    reg [9:0]  box_y_hi;
    reg        box_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_x_lo  <= 11'h7ff;
            acc_x_hi  <= 11'd0;
            acc_y_lo  <= 10'h3ff;
            acc_y_hi  <= 10'd0;
            acc_seen  <= 1'b0;
            box_x_lo  <= 11'd0;
            box_x_hi  <= 11'd0;
            box_y_lo  <= 10'd0;
            box_y_hi  <= 10'd0;
            box_valid <= 1'b0;
        end else if (frame_start) begin
            box_x_lo  <= acc_x_lo;
            box_x_hi  <= acc_x_hi;
            box_y_lo  <= acc_y_lo;
            box_y_hi  <= acc_y_hi;
            box_valid <= acc_seen;
            acc_x_lo  <= 11'h7ff;
            acc_x_hi  <= 11'd0;
            acc_y_lo  <= 10'h3ff;
            acc_y_hi  <= 10'd0;
            acc_seen  <= 1'b0;
        end else if (box_pix) begin
            acc_seen <= 1'b1;
            if (s_x < acc_x_lo) acc_x_lo <= s_x;
            if (s_x > acc_x_hi) acc_x_hi <= s_x;
            if (s_y < acc_y_lo) acc_y_lo <= s_y;
            if (s_y > acc_y_hi) acc_y_hi <= s_y;
        end
    end

    // ---------------------------------------------------------------
    // Box outline. Everything is an addition, so nothing can underflow when
    // the accumulators are still at their reset value.
    // ---------------------------------------------------------------
    wire inside_x  = (s_x >= box_x_lo) && (s_x <= box_x_hi);
    wire inside_y  = (s_y >= box_y_lo) && (s_y <= box_y_hi);
    wire near_x_lo = inside_x && (s_x < box_x_lo + BOX_THICKNESS);
    wire near_x_hi = inside_x && ({1'b0, s_x} + BOX_THICKNESS > {1'b0, box_x_hi});
    wire near_y_lo = inside_y && (s_y < box_y_lo + BOX_THICKNESS);
    wire near_y_hi = inside_y && ({1'b0, s_y} + BOX_THICKNESS > {1'b0, box_y_hi});

    wire box_x_edge = inside_y && (near_x_lo || near_x_hi);
    wire box_y_edge = inside_x && (near_y_lo || near_y_hi);
    wire box_draw   = box_valid && (s_x > HALF_X) && (box_x_edge || box_y_edge);

    // ---------------------------------------------------------------
    // Output register. prev_de is the in_de of the pixel being presented, so
    // gating on it - and not on in_de - keeps the last pixel of every line.
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vs <= 1'b0;
            out_hs <= 1'b0;
            out_de <= 1'b0;
            out_r  <= 8'd0;
            out_g  <= 8'd0;
            out_b  <= 8'd0;
        end else begin
            out_vs <= in_vs;
            out_hs <= in_hs;
            out_de <= in_de;
            if (!prev_de) begin
                out_r <= 8'd0;
                out_g <= 8'd0;
                out_b <= 8'd0;
            end else if (s_x < HALF_X) begin
                out_r <= in_r;
                out_g <= in_g;
                out_b <= in_b;
            end else if (s_x == HALF_X) begin
                out_r <= 8'hff;      // keep the white separator column
                out_g <= 8'hff;
                out_b <= 8'hff;
            end else if (box_draw) begin
                out_r <= 8'hff;      // red, so it cannot be mistaken for an
                out_g <= 8'd0;       // edge pixel
                out_b <= 8'd0;
            end else begin
                out_r <= edge_clean ? 8'hff : 8'd0;
                out_g <= edge_clean ? 8'hff : 8'd0;
                out_b <= edge_clean ? 8'hff : 8'd0;
            end
        end
    end

endmodule
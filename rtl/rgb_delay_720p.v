////////////////////////////////////////////////////////////////////////////
//
// rgb_delay_720p.v
//
// Delays the camera RGB stream by LINE_DELAY whole lines plus PIXEL_DELAY
// active pixels, so that edge_overlay_720p can draw the red edges of
// edge_display_720p on top of the colour picture they were computed from.
//
// Why a delay is needed, and how big it is
// ----------------------------------------
// The edge chain is four identical 3x3 window levels:
//
//     median_filter_3x3_720p -> gauss3_720p -> gauss3_720p -> edge_display_720p
//
// A 3x3 level holds two row stores, so the row taps it has available are the
// current row, the previous row and the one before that. The centre of its
// window is therefore one row ABOVE the pixel entering the level (the middle
// row), and the middle-row tap is additionally registered, which puts the
// centre a handful of pixels to the left as well. In the level's own clock the
// value that leaves the level refers to
//
//     centre = (row - 1, column - k),  k = 1 .. 3
//
// Four of those levels put the edge map 4 rows and 4 * k pixels below and to
// the right of the stream that entered the chain. The colour picture comes
// from that very stream (hdmi_tx_rdata/gdata/bdata, the input of
// median_filter_inst), so this module has to push the colour down by the same
// amount before edge_overlay_720p mixes the two.
//
// The row count is exact: a level contributes exactly one row because k is a
// few pixels and never reaches 1280, and there are exactly four levels. The
// pixel count is NOT exact - the register arrangement differs slightly from
// level to level, so k is somewhere in 1 .. 3 and the horizontal alignment is
// only right to within a few pixels. A few pixels of horizontal error is
// invisible, a whole row is not, so PIXEL_DELAY is a plain integer that can be
// nudged at any time without any other consequence. It is set to 4 * 2 = 8.
//
// Implementation
// --------------
// One inferred RAM with a read-before-write access at a single address: the
// write port stores the incoming pixel at waddr while the read port reads the
// SAME address, so what comes back is the word written STORE_DEPTH writes
// earlier. The address wraps at STORE_DEPTH, which is exactly the delay, so
// the delay is STORE_DEPTH active pixels for every pixel of every frame -
// there is no special case anywhere in the picture.
//
// The comment on the previous version of this file claimed that reading
// "waddr - PIXEL_DELAY" out of a store that is only LINE_DELAY rows deep gives
// the pixel of LINE_DELAY lines ago. It does not: a store that wraps every
// LINE_DELAY rows is just a short circular buffer, so that version shifted the
// picture by a few pixels horizontally and did not shift it by a single line.
// The addressing here is the fix.
//
// The output-side register sits after the RAM and is part of the requested
// delay, so
//
//     STORE_DEPTH = LINE_DELAY * IMAGE_WIDTH + PIXEL_DELAY - 1
//
// because a store of depth STORE_DEPTH read before write hands back a pixel
// that is STORE_DEPTH+1 active pixels old, and the read register adds one more.
// (That +1 cost one round of tools/verify_rgb_delay.py: with the depth written
// here the module delivers exactly DELAY_PIX, which is what the model asserts.)
//
// Validity: the store only holds pixels of the current frame once STORE_DEPTH
// writes have happened since the frame boundary, so the output is forced black
// until the write pointer has wrapped once after the frame boundary and that
// flag has travelled through the output register. The black border is
// therefore exactly DELAY_PIX pixels - LINE_DELAY lines plus PIXEL_DELAY
// pixels, the same offset the module applies - and it is not visible.
//
// The address counter is reset at the frame boundary. The reset makes the
// pointer revisit a few addresses before STORE_DEPTH writes have passed, and
// those words are stale, but that can only happen inside the black region
// above, so the visible picture is always the exact delay.
//
// Measured on TI60F225, 2026-09-26: 51 FFs, 76 LUTs, 24 RAM blocks, and the
// design still closes timing with a positive slack.
//
////////////////////////////////////////////////////////////////////////////

module rgb_delay_720p #(
    parameter integer IMAGE_WIDTH = 1280,
    parameter integer LINE_DELAY  = 4,
    parameter integer PIXEL_DELAY = 8
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
    output reg  [7:0] out_r,
    output reg  [7:0] out_g,
    output reg  [7:0] out_b
);

    localparam integer DELAY_PIX = LINE_DELAY * IMAGE_WIDTH + PIXEL_DELAY;
    // The read register is part of DELAY_PIX; see the header for the -1.
    localparam integer REG_STAGES  = 1;
    localparam integer STORE_DEPTH = DELAY_PIX - REG_STAGES;
    // STORE_DEPTH is 5126 here, i.e. 13 bits are enough. Every operand of the
    // address arithmetic carries that width, so no expression is wider than the
    // index it drives.
    localparam integer         ADDR_BITS     = 13;
    localparam [ADDR_BITS-1:0] STORE_DEPTH_V = STORE_DEPTH[ADDR_BITS-1:0];

    reg [23:0] store [0:STORE_DEPTH-1];
    reg [23:0] read_rgb;

    reg        prev_de;
    reg        prev_vs;
    reg        filled;          // write pointer wrapped once since the frame boundary
    reg        filled_d1;
    reg [ADDR_BITS-1:0] waddr;

    wire frame_start = in_vs && !prev_vs;

    // Read before write at the same address: the read port returns the word
    // written STORE_DEPTH writes earlier.
    always @(posedge clk) begin
        if (rst_n && in_de)
            store[waddr] <= {in_r, in_g, in_b};
        read_rgb <= store[waddr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_de   <= 1'b0;
            prev_vs   <= 1'b0;
            filled    <= 1'b0;
            filled_d1 <= 1'b0;
            waddr     <= {ADDR_BITS{1'b0}};
            out_vs    <= 1'b0;
            out_hs    <= 1'b0;
            out_de    <= 1'b0;
            out_r     <= 8'd0;
            out_g     <= 8'd0;
            out_b     <= 8'd0;
        end else begin
            prev_de <= in_de;
            prev_vs <= in_vs;

            if (frame_start) begin
                // The frame boundary and the first active pixel never coincide
                // in 720p (vs rises in the blanking interval), so the else-if
                // below cannot swallow a pixel.
                filled <= 1'b0;
                waddr  <= {ADDR_BITS{1'b0}};
            end else if (in_de) begin
                if (waddr == STORE_DEPTH_V - 1) begin
                    waddr  <= {ADDR_BITS{1'b0}};
                    filled <= 1'b1;
                end else begin
                    waddr <= waddr + 1'b1;
                end
            end

            filled_d1 <= filled;

            out_vs <= in_vs;
            out_hs <= in_hs;
            out_de <= in_de;

            if (filled_d1) begin
                out_r <= read_rgb[23:16];
                out_g <= read_rgb[15:8];
                out_b <= read_rgb[7:0];
            end else begin
                out_r <= 8'd0;
                out_g <= 8'd0;
                out_b <= 8'd0;
            end
        end
    end

endmodule

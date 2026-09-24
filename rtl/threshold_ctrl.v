////////////////////////////////////////////////////////////////////////////
//
// threshold_ctrl.v
//
// Runtime edge-threshold control for the Sobel stage, driven by board keys.
//
// edge_display_720p compares the gradient magnitude against
//
//     max(center >> shift, floor)
//
// where "center" is the 8-bit gray level at the centre of the 3x3 window.
// That gives two knobs worth exposing at runtime:
//
//   floor  (EDGE_THRESHOLD)        noise gate, useful range 0..255
//   shift  (EDGE_THRESHOLD_SHIFT)  weight of the adaptive term
//
// A larger shift flattens the threshold towards the fixed floor; shift = 8
// makes the adaptive term vanish entirely (classic fixed threshold) and
// shift = 0 follows the local brightness at full weight.
//
// i_mode walks through {8, 3, 2, 1, 0} so a single key covers the whole range
// from "fixed" to "fully adaptive". The floor moves in steps of
// STEP_THRESHOLD, which is coarse enough to see the panel change on every
// press but still fine enough to tune.
//
////////////////////////////////////////////////////////////////////////////

module threshold_ctrl #(
    parameter [10:0]  THRESHOLD_INIT = 11'd24,
    parameter integer STEP_THRESHOLD = 8,
    // Reset value of the adaptive-weight index. Index 3 is shift = 1, which is
    // the configuration the previous bitstream ran with.
    parameter [2:0]   MODE_INIT      = 3'd3
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_up,        // pulse: raise the floor
    input  wire        i_down,      // pulse: lower the floor
    input  wire        i_mode,      // pulse: next adaptive weight
    output reg  [10:0] o_threshold,
    output reg  [3:0]  o_shift,
    output reg         o_changed    // one-clock pulse on any change
);

    // Above 255 the floor can never be reached: the largest possible adaptive
    // term is also 255 (8-bit centre at full weight).
    localparam [10:0] THRESHOLD_MAX = 11'd255;
    localparam [2:0]  MODE_LAST     = 3'd4;

    reg [2:0] mode;

    function [3:0] shift_of;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: shift_of = 4'd8;    // adaptive term off
                3'd1: shift_of = 4'd3;    // /8
                3'd2: shift_of = 4'd2;    // /4
                3'd3: shift_of = 4'd1;    // /2
                default: shift_of = 4'd0; // /1, fully adaptive
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_threshold <= THRESHOLD_INIT;
            mode        <= MODE_INIT;
            o_shift     <= shift_of(MODE_INIT);
            o_changed   <= 1'b0;
        end else begin
            o_changed <= 1'b0;

            if (i_up) begin
                o_threshold <= (o_threshold + STEP_THRESHOLD > THRESHOLD_MAX)
                             ? THRESHOLD_MAX
                             : o_threshold + STEP_THRESHOLD;
                o_changed   <= 1'b1;
            end else if (i_down) begin
                o_threshold <= (o_threshold < STEP_THRESHOLD)
                             ? 11'd0
                             : o_threshold - STEP_THRESHOLD;
                o_changed   <= 1'b1;
            end

            // Both keys in the same cycle is impossible on real hardware, but
            // the mode update is written after the floor update so the
            // o_changed pulse is still asserted exactly once.
            if (i_mode) begin
                mode      <= (mode == MODE_LAST) ? 3'd0 : mode + 3'd1;
                o_shift   <= shift_of((mode == MODE_LAST) ? 3'd0 : mode + 3'd1);
                o_changed <= 1'b1;
            end
        end
    end

endmodule

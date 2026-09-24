////////////////////////////////////////////////////////////////////////////
//
// threshold_ctrl.v
//
// Runtime control of the Sobel stage, driven by the board keys.
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
// Key map (KEY1/KEY2 give a single pulse per debounced press, KEY3 is passed
// in as a level so that one button can carry two actions):
//
//   KEY1 short      raise the floor by STEP_THRESHOLD
//   KEY2 short      lower the floor by STEP_THRESHOLD
//   KEY3 short      next adaptive weight: {8, 3, 2, 1, 0}
//   KEY3 held >=1 s next despeckle window, and the short action is dropped
//
// The short action fires on RELEASE and only when the hold was shorter than
// LONG_PRESS_MS, so a long hold cannot also step the threshold. The long
// action fires while the button is still down, which gives immediate feedback.
//
// o_despeckle is the neighbour-count threshold used by edge_overlay_720p.v:
// 0 disables the filter (A/B reference), 2 removes isolated pixels, 3 removes
// two-pixel specks while keeping one-pixel-wide lines, 5 is aggressive.
//
////////////////////////////////////////////////////////////////////////////

module threshold_ctrl #(
    parameter [10:0]  THRESHOLD_INIT = 11'd24,
    parameter integer STEP_THRESHOLD = 8,
    // Reset value of the adaptive-weight index. Index 3 is shift = 1, which is
    // the configuration the previous bitstream ran with.
    parameter [2:0]   MODE_INIT      = 3'd3,
    // Reset index of the despeckle table; 2 selects the recommended value 3.
    parameter [1:0]   DESPECKLE_INIT = 2'd2,
    parameter integer CLK_HZ         = 25000000,
    parameter integer LONG_PRESS_MS  = 1000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_up,         // pulse: raise the floor
    input  wire        i_down,       // pulse: lower the floor
    input  wire        i_mode_level, // debounced KEY3, high while held
    output reg  [10:0] o_threshold,
    output reg  [3:0]  o_shift,
    output reg  [3:0]  o_despeckle,
    output reg         o_changed     // one-clock pulse on any change
);

    // Above 255 the floor can never be reached: the largest possible adaptive
    // term is also 255 (8-bit centre at full weight).
    localparam [10:0] THRESHOLD_MAX = 11'd255;
    localparam [2:0]  MODE_LAST     = 3'd4;
    localparam [1:0]  DS_LAST       = 2'd3;
    localparam integer HOLD_MAX     = (CLK_HZ / 1000) * LONG_PRESS_MS;

    reg [2:0]  mode;
    reg [1:0]  ds_idx;
    reg [24:0] hold_cnt;
    reg        hold_active;
    reg        hold_long;

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

    function [3:0] despeckle_of;
        input [1:0] idx;
        begin
            case (idx)
                2'd0:    despeckle_of = 4'd0;  // filter off, A/B reference
                2'd1:    despeckle_of = 4'd2;  // drop isolated pixels
                2'd2:    despeckle_of = 4'd3;  // drop specks, keep lines
                default: despeckle_of = 4'd5;  // aggressive
            endcase
        end
    endfunction

    // A press that ended early, and a hold that has just passed LONG_PRESS_MS.
    // Both are combinationally true for exactly one clock.
    wire short_now = !i_mode_level && hold_active && !hold_long;
    wire long_now  =  i_mode_level && hold_active && !hold_long
                     && (hold_cnt >= HOLD_MAX);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_threshold <= THRESHOLD_INIT;
            mode        <= MODE_INIT;
            o_shift     <= shift_of(MODE_INIT);
            ds_idx      <= DESPECKLE_INIT;
            o_despeckle <= despeckle_of(DESPECKLE_INIT);
            o_changed   <= 1'b0;
            hold_cnt    <= 25'd0;
            hold_active <= 1'b0;
            hold_long   <= 1'b0;
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

            // KEY3 hold timer. The debounced level is used directly, so the
            // timer can only start on a clean, bounce-free level.
            if (!i_mode_level) begin
                hold_active <= 1'b0;
                hold_cnt    <= 25'd0;
                hold_long   <= 1'b0;
            end else if (!hold_active) begin
                hold_active <= 1'b1;
                hold_cnt    <= 25'd1;
            end else if (!hold_long) begin
                if (hold_cnt >= HOLD_MAX) hold_long <= 1'b1;
                else                      hold_cnt  <= hold_cnt + 25'd1;
            end

            if (short_now) begin
                mode      <= (mode == MODE_LAST) ? 3'd0 : mode + 3'd1;
                o_shift   <= shift_of((mode == MODE_LAST) ? 3'd0 : mode + 3'd1);
                o_changed <= 1'b1;
            end

            if (long_now) begin
                ds_idx      <= (ds_idx == DS_LAST) ? 2'd0 : ds_idx + 2'd1;
                o_despeckle <= despeckle_of((ds_idx == DS_LAST) ? 2'd0 : ds_idx + 2'd1);
                o_changed   <= 1'b1;
            end
        end
    end

endmodule
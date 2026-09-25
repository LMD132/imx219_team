////////////////////////////////////////////////////////////////////////////
//
// tone_curve_lut.v
//
// Selectable tone curve applied to the 8-bit gray *before* the Sobel stage.
//
// Why: on the bench the sensor sees a back-lit room, so most of the frame sits
// between 0 and 48 and the objects we care about (an instrument on the bench, a
// person in front of the wall) only differ from their background by 10..25 gray
// levels. The gradient of such a contour is 40..100 LSB, but an 8-bit sensor
// only spends 48 codes on the whole shaded part of the scene, so the Sobel
// output there is weak and broken no matter where the threshold is put.
//
// Making the dark half of the transfer curve steeper raises those contours
// above the noise gate without touching the exposure, and the highlight half is
// then compressed to keep the result inside 0..255. Measured offline on two
// captured frames (tools/proto_curve_sweep.py):
//
//   curve          dark edge density   noise floor   edge pixels on real contours
//   bypass                  6.6 %         0.0 %            93 %
//   mode 1 (2x/64)         29.3 %         2.2 %            95 %
//
// mode 1 is the bring-up default. Modes 2 and 3 are milder ; mode 0 is the
// bypass that reproduces the previous bitstream exactly, which is what the A/B
// capture in docs/capture_and_quantify.md compares against.
//
// All three curves are shift-and-add only, no table and no DSP: the multiplier
// of every segment is expanded into a sum of powers of two, so the module is a
// handful of adders. The curve is combinational on purpose - a register here
// would delay the pixel stream by one clock and every module downstream would
// have to be re-aligned.
//
//   mode 0 : y = x
//   mode 1 : x < 64  -> 2x        ; above -> 128 + 0.668*(x-64)
//   mode 2 : x < 96  -> 2x        ; above -> 192 + 0.398*(x-96)
//   mode 3 : x < 96  -> 1.5x      ; above -> 144 + 0.699*(x-96)
//
// Every segment is continuous at its knee and maps 255 to 255.
//
////////////////////////////////////////////////////////////////////////////

module tone_curve_lut (
    input  wire [1:0] i_mode,
    input  wire [7:0] i_gray,
    output reg  [7:0] o_gray
);

    wire [15:0] x = {8'b0, i_gray};

    // ---- mode 1: knee 64, second segment covers 191 codes in 127 steps ----
    wire [7:0]  x1 = i_gray - 8'd64;
    wire [15:0] d1 = {8'b0, x1};
    // 171 = 128 + 32 + 8 + 2 + 1
    wire [15:0] p1 = (d1 << 7) + (d1 << 5) + (d1 << 3) + (d1 << 1) + d1;
    wire [7:0]  m1 = (i_gray < 8'd64) ? {i_gray[6:0], 1'b0}
                                      : (8'd128 + p1[15:8]);

    // ---- mode 2: knee 96, 159 codes in 63 steps ----
    wire [7:0]  x2 = i_gray - 8'd96;
    wire [15:0] d2 = {8'b0, x2};
    // 102 = 64 + 32 + 4 + 2
    wire [15:0] p2 = (d2 << 6) + (d2 << 5) + (d2 << 2) + (d2 << 1);
    wire [7:0]  m2 = (i_gray < 8'd96) ? {i_gray[6:0], 1'b0}
                                      : (8'd192 + p2[15:8]);

    // ---- mode 3: knee 96, gain 1.5, 159 codes in 111 steps ----
    // 179 = 128 + 32 + 16 + 2 + 1
    wire [15:0] p3 = (d2 << 7) + (d2 << 5) + (d2 << 4) + (d2 << 1) + d2;
    wire [7:0]  m3 = (i_gray < 8'd96) ? (i_gray + {1'b0, i_gray[7:1]})
                                      : (8'd144 + p3[15:8]);

    always @(*) begin
        case (i_mode)
            2'd0:    o_gray = i_gray;
            2'd1:    o_gray = m1;
            2'd2:    o_gray = m2;
            default: o_gray = m3;
        endcase
    end

endmodule
////////////////////////////////////////////////////////////////////////////
//
// uart_cmd.v
//
// Remote control of the edge stage over the board UART, so a parameter sweep
// does not need somebody sitting at the board pressing keys.
//
// Line format, ASCII, terminated by LF (CR is ignored):
//
//     T<nnn>\n     threshold floor           0..255
//     S<n>\n       adaptive weight / shift   0..8   (8 = adaptive term off)
//     D<n>\n       despeckle neighbours      0..5
//     E<n>\n       denoise stages            0..2
//     C<n>\n       tone curve before Sobel   0..3   (0 = bypass)
//     H<n>\n       local hysteresis          0..1
//     P<n>\n       colour delay pixels       0..63
//     K\n          release control back to the on-board keys
//     I<n>\n       pixel source: 0 = the verified chain, 1 = the teammate IP
//
// Examples: "T16\n", "E2\n", "K\n". Separators such as '=' or spaces are
// accepted and ignored, so "T=16" and "T 16" work as well.
//
// The first parameter line latches o_override, and from then on the keys
// are ignored - otherwise a KEY3 hold while sweeping would silently fight
// the host. K hands control back. o_commit pulses once per accepted line, which
// the top level uses both to push an immediate telemetry line and to send an
// ACK line.
//
// The parser resolves a three digit value with a saturating accumulate, so a
// long digit string can never wrap around.
//
////////////////////////////////////////////////////////////////////////////

module uart_cmd #(
    // Same reset operating point as threshold_ctrl.v, so a host that only
    // sends one parameter does not silently reset the others.
    parameter [10:0] THRESHOLD_INIT = 11'd24,
    parameter [3:0]  SHIFT_INIT     = 4'd8,
    parameter [3:0]  DESPECKLE_INIT = 4'd3,
    parameter [1:0]  DENOISE_INIT   = 2'd2,
    parameter [1:0]  CURVE_INIT      = 2'd1,
    parameter        HYSTERESIS_INIT = 1'b1,
    parameter [7:0]  PIXEL_DELAY_INIT = 8'd8,
    parameter        IP_SEL_INIT      = 1'b0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  i_data,
    input  wire        i_valid,
    output reg  [10:0] o_threshold,
    output reg  [3:0]  o_shift,
    output reg  [3:0]  o_despeckle,
    output reg  [1:0]  o_denoise,
    output reg  [1:0]  o_curve,
    output reg         o_hysteresis,
    output reg  [7:0]  o_pixel_delay,
    output reg         o_ip_sel,
    output reg         o_override,
    output reg         o_commit
);

    // 0 = threshold, 1 = shift, 2 = despeckle, 3 = denoise stages,
    // 4 = tone curve, 5 = local hysteresis.
    localparam [2:0] K_T = 3'd0,
                     K_S = 3'd1,
                     K_D = 3'd2,
                     K_E = 3'd3,
                     K_C = 3'd4,
                     K_H = 3'd5,
                     K_P = 3'd6,
                     K_I = 3'd7;

    localparam [1:0] S_KEY = 2'd0,
                     S_VAL = 2'd1;

    reg [1:0]  state;
    reg [2:0]  key;
    // 16 bits wide and clamped at 1000, so a long digit string can never wrap
    // around before the commit clamp brings it down to 255.
    reg [15:0] acc;
    reg        got_digit;

    // Digits are within 4 of their own uppercase form.
    // NOTE: explicit widths and hex literals are deliberate here. With an implicit
    // wire and the ASCII string literal "0", Efinity inferred `digit` as ONE bit, so
    // every digit collapsed to its LSB: 1->1, 2->0, 3->1, and "T16" latched THR=10.
    // is_digit was unaffected because a comparison is 1 bit wide anyway.
    wire [7:0] is_digit = (i_data >= 8'h30) && (i_data <= 8'h39);
    wire is_eol   = (i_data == 8'h0A) || (i_data == 8'h0D);
    wire [7:0] digit    = i_data - 8'h30;
    // Anything above 255 is a typo or a longer number than the format allows.
    wire [7:0] val = (acc > 16'd255) ? 8'hFF : acc[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_KEY;
            key         <= K_T;
            acc         <= 16'd0;
            got_digit   <= 1'b0;
            o_threshold <= THRESHOLD_INIT;
            o_shift     <= SHIFT_INIT;
            o_despeckle <= DESPECKLE_INIT;
            o_denoise   <= DENOISE_INIT;
            o_curve     <= CURVE_INIT;
            o_hysteresis <= HYSTERESIS_INIT;
            o_pixel_delay <= PIXEL_DELAY_INIT;
            o_ip_sel    <= IP_SEL_INIT;
            o_override  <= 1'b0;
            o_commit    <= 1'b0;
        end else begin
            o_commit <= 1'b0;

            if (i_valid) begin
                case (state)
                    S_KEY: begin
                        if (i_data == "T" || i_data == "t") begin
                            key   <= K_T;
                            state <= S_VAL;
                            acc   <= 16'd0;
                            got_digit <= 1'b0;
                        end else if (i_data == "S" || i_data == "s") begin
                            key   <= K_S;
                            state <= S_VAL;
                            acc   <= 16'd0;
                            got_digit <= 1'b0;
                        end else if (i_data == "D" || i_data == "d") begin
                            key   <= K_D;
                            state <= S_VAL;
                            acc   <= 16'd0;
                            got_digit <= 1'b0;
                        end else if (i_data == "E" || i_data == "e") begin
                            key   <= K_E;
                            state <= S_VAL;
                            acc   <= 16'd0;
                            got_digit <= 1'b0;
                        end else if (i_data == "C" || i_data == "c") begin
                            key   <= K_C;
                            state <= S_VAL;
                            acc   <= 16'd0;
                            got_digit <= 1'b0;
                        end else if (i_data == "H" || i_data == "h") begin
                            key   <= K_H;
                            state <= S_VAL;
                            acc   <= 16'd0;
                            got_digit <= 1'b0;
                        end else if (i_data == "K" || i_data == "k") begin
                        end else if (i_data == "P" || i_data == "p") begin
                            key   <= K_P;
                            state <= S_VAL;
                            acc   <= 16'd0;
                            got_digit <= 1'b0;
                            // Hand the stage back to the on-board keys.
                            o_override <= 1'b0;
                            o_commit   <= 1'b1;
                        end else if (i_data == "I" || i_data == "i") begin
                            key   <= K_I;
                            state <= S_VAL;
                            acc   <= 16'd0;
                            got_digit <= 1'b0;
                        end
                    end

                    S_VAL: begin
                        if (is_digit) begin
                            got_digit <= 1'b1;
                            acc       <= (acc >= 16'd1000) ? 16'd1000
                                                           : (acc * 16'd10) + digit;
                        end else if (is_eol) begin
                            if (got_digit) begin
                                o_override <= 1'b1;
                                o_commit   <= 1'b1;
                                case (key)
                                    K_T: o_threshold  <= {3'b0, val};
                                    K_S: o_shift      <= (val > 8'd8) ? 4'd8 : val[3:0];
                                    K_D: o_despeckle  <= (val > 8'd5) ? 4'd5 : val[3:0];
                                    K_E: o_denoise    <= (val > 8'd2) ? 2'd2 : val[1:0];
                                    K_C: o_curve      <= (val > 8'd3) ? 2'd3 : val[1:0];
                                    default: o_hysteresis <= (val != 8'd0);
                                    K_P: o_pixel_delay <= (val > 8'd63) ? 8'd63 : val;
                                    K_I: o_ip_sel      <= (val != 8'd0);
                                endcase
                            end
                            state <= S_KEY;
                        end
                        // Any other character (a space, '=') is a separator.
                    end

                    default: state <= S_KEY;
                endcase
            end
        end
    end

endmodule

////////////////////////////////////////////////////////////////////////////
//
// key_debounce.v
//
// Push-button debouncer for the Ti60F225 demo board keys.
//
// The board keys are active low: an external pull-up holds the pin high and
// pressing the button shorts it to ground. The pinout report and the vendor
// key demo both use that polarity, so nothing is inverted here.
//
// A press is reported as a single one-clock pulse on the falling edge of the
// debounced level. Making the output edge-triggered keeps the downstream
// logic independent of how long the button is held down (a held key must not
// keep stepping a counter).
//
// o_level exposes the debounced level itself (high while the key is held),
// which is what threshold_ctrl.v uses for its short-press / long-press split
// on KEY3.
//
// The input is synchronised with two flops and the counter only starts once
// the raw pin disagrees with the stored level, so contact bounce simply
// restarts the timer.
//
////////////////////////////////////////////////////////////////////////////

module key_debounce #(
    parameter integer CLK_HZ      = 25000000,
    parameter integer DEBOUNCE_MS = 20
) (
    input  wire clk,
    input  wire rst_n,
    input  wire i_key,      // raw pin, active low
    output reg  o_press,    // one-clock pulse per debounced press
    output wire o_level     // debounced level, high while held
);

    // 25 MHz * 20 ms = 500000. The counter is 32 bits wide so the module
    // stays correct for any CLK_HZ, matching uart_status_tx.v.
    localparam integer CNT_MAX = (CLK_HZ / 1000) * DEBOUNCE_MS;

    reg [1:0]  sync;
    reg        stable;
    reg [31:0] cnt;

    // The stored level is high when the key is released, so the held state is
    // simply its inverse.
    assign o_level = ~stable;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync    <= 2'b11;       // keys idle high
            stable  <= 1'b1;
            cnt     <= 32'd0;
            o_press <= 1'b0;
        end else begin
            sync <= {sync[0], i_key};

            // o_press is a one-clock pulse, so clear it every cycle and let
            // the branch below re-assert it.
            o_press <= 1'b0;

            if (sync[1] == stable) begin
                // Level agrees with what we already believe: no timer needed.
                cnt <= 32'd0;
            end else if (cnt >= CNT_MAX) begin
                cnt    <= 32'd0;
                stable <= sync[1];
                // Falling edge of the debounced level is a press.
                if (!sync[1]) o_press <= 1'b1;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end

endmodule

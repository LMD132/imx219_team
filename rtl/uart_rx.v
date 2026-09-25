////////////////////////////////////////////////////////////////////////////
//
// uart_rx.v
//
// Minimal 8N1 UART receiver, the other half of uart_tx.v, with the same
// bit-timing rule: every bit is held for DIV = round(CLK_HZ / BAUD) clocks,
// so 25 MHz / 115200 gives 217 (0.006 % fast).
//
// The pin is asynchronous, so it goes through a two-flop synchroniser. The
// receiver samples the middle of each bit: after the falling edge it waits
// half a bit period, checks that the line is still low (a real start bit and
// not a glitch) and then samples once per bit period. o_data is only updated
// when the stop bit is high, so a truncated frame is dropped instead of
// producing a wrong byte.
//
// The board wires the FPGA side to GPIOL_02 / R4 (net UART_TX_3V3 from the
// FT4232H) with a weak pull-up, which is also what the vendor key demo
// declares for its rxd pin.
//
////////////////////////////////////////////////////////////////////////////

module uart_rx #(
    parameter integer CLK_HZ = 25000000,
    parameter integer BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       i_rxd,
    output reg  [7:0] o_data,
    output reg        o_valid
);

    localparam integer DIV = (CLK_HZ + (BAUD / 2)) / BAUD;

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  sync;
    reg [1:0]  state;
    reg [15:0] cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  sh;

    wire rx = sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync     <= 2'b11;
            state    <= S_IDLE;
            cnt      <= 16'd0;
            bit_idx  <= 3'd0;
            sh       <= 8'd0;
            o_data   <= 8'd0;
            o_valid  <= 1'b0;
        end else begin
            sync    <= {sync[0], i_rxd};
            o_valid <= 1'b0;

            case (state)
                // Wait for a falling edge. cnt is pre-loaded with half a bit
                // so the next sample lands in the middle of the start bit.
                S_IDLE: begin
                    if (!rx) begin
                        cnt   <= (DIV / 2) - 1;
                        state <= S_START;
                    end
                end

                S_START: begin
                    if (cnt == 16'd0) begin
                        if (!rx) begin       // still low: a real start bit
                            cnt     <= DIV - 1;
                            bit_idx <= 3'd0;
                            sh      <= 8'd0;
                            state   <= S_DATA;
                        end else begin
                            state <= S_IDLE; // glitch, forget it
                        end
                    end else begin
                        cnt <= cnt - 16'd1;
                    end
                end

                // LSB first, matching uart_tx.v.
                S_DATA: begin
                    if (cnt == 16'd0) begin
                        sh  <= {rx, sh[7:1]};
                        cnt <= DIV - 1;
                        if (bit_idx == 3'd7) state   <= S_STOP;
                        else                 bit_idx <= bit_idx + 3'd1;
                    end else begin
                        cnt <= cnt - 16'd1;
                    end
                end

                // A high stop bit means the byte is good.
                S_STOP: begin
                    if (cnt == 16'd0) begin
                        if (rx) begin
                            o_data  <= sh;
                            o_valid <= 1'b1;
                        end
                        state <= S_IDLE;
                    end else begin
                        cnt <= cnt - 16'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

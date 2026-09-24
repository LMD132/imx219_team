////////////////////////////////////////////////////////////////////////////
//
// uart_tx.v
//
// Minimal 8N1 UART transmitter (1 start bit, 8 data bits LSB-first, 1 stop bit).
// Written for the imx219_team edge-detection project; intentionally self
// contained (no vendor IP, no third-party source).
//
// Handshake:
//   Assert i_valid together with i_data for one clock while o_busy == 0.
//   o_busy rises the next clock and stays high for the whole frame.
//   i_valid is ignored while o_busy is high, so a producer must check o_busy.
//
// Bit timing: every bit (including start and stop) is held for exactly DIV
// clocks, where DIV = round(CLK_HZ / BAUD). At 25 MHz / 115200 baud that is
// 217 clocks, an effective baud of 115207 (+0.006 %).
//
////////////////////////////////////////////////////////////////////////////

module uart_tx #(
    parameter integer CLK_HZ = 25000000,
    parameter integer BAUD   = 115200
) (
    input  wire       i_clk,
    input  wire       i_rstn,
    input  wire [7:0] i_data,
    input  wire       i_valid,
    output reg        o_busy,
    output reg        o_txd
);

    //----------------------------------------------------------------------
    // Baud rate generator constants
    //----------------------------------------------------------------------
    function integer udiv_round;
        input integer a;
        input integer b;
        begin
            udiv_round = (a + (b / 2)) / b;
        end
    endfunction

    function integer clog2;
        input integer value;
        integer i;
        begin
            clog2 = 0;
            for (i = 0; i < 32; i = i + 1)
                if (value > (1 << i)) clog2 = i + 1;
        end
    endfunction

    localparam integer DIV = udiv_round(CLK_HZ, BAUD);  // clocks per bit
    localparam integer CW  = clog2(DIV);                // counter width

    localparam [3:0] PH_START = 4'd0;   // start bit
    localparam [3:0] PH_STOP  = 4'd9;   // stop bit

    reg [3:0]     phase;    // 0 = start, 1..8 = data b0..b7, 9 = stop
    reg [CW-1:0]  baud_cnt;
    reg [7:0]     shift;

    wire bit_done = (baud_cnt == (DIV - 1));

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            o_txd    <= 1'b1;
            o_busy   <= 1'b0;
            phase    <= PH_STOP;
            baud_cnt <= {CW{1'b0}};
            shift    <= 8'h00;
        end else if (!o_busy) begin
            // Line idles high. Start a frame as soon as a byte is offered.
            o_txd    <= 1'b1;
            baud_cnt <= {CW{1'b0}};
            if (i_valid) begin
                shift  <= i_data;
                o_txd  <= 1'b0;          // start bit
                o_busy <= 1'b1;
                phase  <= PH_START;
            end
        end else if (bit_done) begin
            baud_cnt <= {CW{1'b0}};
            if (phase == PH_STOP) begin
                o_busy <= 1'b0;
                o_txd  <= 1'b1;
            end else begin
                phase <= phase + 4'd1;
                if (phase == 4'd8)
                    o_txd <= 1'b1;                       // stop bit
                else
                    o_txd <= shift[phase[2:0]];          // next data bit
            end
        end else begin
            baud_cnt <= baud_cnt + 1'b1;
        end
    end

endmodule

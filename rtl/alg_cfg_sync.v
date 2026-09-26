////////////////////////////////////////////////////////////////////////////
//
// alg_cfg_sync.v
//
// Clock-domain crossing for the runtime edge parameters.
//
// The UART register file (alg_cfg_uart.v) runs on CLK_25M, while alg_top.v
// and the whole video path run on hdmi_tx_slow_clk. A multi-bit bus cannot be
// passed through a two-flop synchroniser, so this module uses the data-stable
// plus toggle pattern: the source side parks the payload in a snapshot register
// and flips a level bit, the destination side synchronises that single bit and
// registers the payload when the synchronised level changes. By then the
// payload has been stable for at least two destination clocks, so what gets
// sampled is always a settled value and never a mix of two commands.
//
// A command can be missed only if two commands arrive within about three
// destination clocks (~40 ns); at 115200 baud a line takes ~90 us, so the
// channel is comfortably slower than that.
//
// Outputs reset to the same power-on defaults as the register file, so a board
// that never sees a UART byte behaves exactly like the constant-tied version.
//
////////////////////////////////////////////////////////////////////////////

module alg_cfg_sync #(
    parameter [1:0]  MODE_INIT   = 2'd2,
    parameter [10:0] T_INIT      = 11'd24,
    parameter [10:0] LO_INIT     = 11'd21,
    parameter [10:0] HI_INIT     = 11'd58,
    parameter        MEDIAN_INIT = 1'b1,
    parameter        GAUSS_INIT  = 1'b0,
    parameter        ISOL_INIT   = 1'b1,
    parameter [1:0]  DISP_INIT   = 2'd0,
    parameter        OVC_INIT    = 1'b1
) (
    input  wire        clk_a,       // source: CLK_25M (UART register file)
    input  wire        rst_a_n,
    input  wire        i_commit,    // one-clock pulse when the host changed a value
    input  wire [1:0]  i_mode,
    input  wire [10:0] i_t,
    input  wire [10:0] i_lo,
    input  wire [10:0] i_hi,
    input  wire        i_median,
    input  wire        i_gauss,
    input  wire        i_isol,
    input  wire [1:0]  i_disp,
    input  wire        i_ovc,
    input  wire        clk_b,       // destination: hdmi_tx_slow_clk
    input  wire        rst_b_n,
    output reg  [1:0]  o_mode,
    output reg  [10:0] o_t,
    output reg  [10:0] o_lo,
    output reg  [10:0] o_hi,
    output reg         o_median,
    output reg         o_gauss,
    output reg         o_isol,
    output reg  [1:0]  o_disp,
    output reg         o_ovc
);

    // {mode, t, lo, hi} = 35 bits, {median, gauss, isol, disp, ovc} = 6 bits
    wire [34:0] a_bus = {i_mode, i_t, i_lo, i_hi};
    wire [5:0]  a_flg = {i_median, i_gauss, i_isol, i_disp, i_ovc};

    reg [34:0] snap_bus;
    reg [5:0]  snap_flg;
    reg        tog;

    always @(posedge clk_a or negedge rst_a_n) begin
        if (!rst_a_n) begin
            snap_bus <= {MODE_INIT, T_INIT, LO_INIT, HI_INIT};
            snap_flg <= {MEDIAN_INIT, GAUSS_INIT, ISOL_INIT, DISP_INIT, OVC_INIT};
            tog      <= 1'b0;
        end else if (i_commit) begin
            snap_bus <= a_bus;
            snap_flg <= a_flg;
            tog      <= ~tog;
        end
    end

    reg [2:0] tog_sync;
    wire      take = tog_sync[2] ^ tog_sync[1];

    always @(posedge clk_b or negedge rst_b_n) begin
        if (!rst_b_n) begin
            tog_sync <= 3'b000;
            o_mode   <= MODE_INIT;
            o_t      <= T_INIT;
            o_lo     <= LO_INIT;
            o_hi     <= HI_INIT;
            o_median <= MEDIAN_INIT;
            o_gauss  <= GAUSS_INIT;
            o_isol   <= ISOL_INIT;
            o_disp   <= DISP_INIT;
            o_ovc    <= OVC_INIT;
        end else begin
            tog_sync <= {tog_sync[1:0], tog};
            if (take) begin
                o_mode   <= snap_bus[34:33];
                o_t      <= snap_bus[32:22];
                o_lo     <= snap_bus[21:11];
                o_hi     <= snap_bus[10:0];
                o_median <= snap_flg[5];
                o_gauss  <= snap_flg[4];
                o_isol   <= snap_flg[3];
                o_disp   <= snap_flg[2:1];
                o_ovc    <= snap_flg[0];
            end
        end
    end

endmodule

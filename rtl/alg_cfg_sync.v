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
    parameter [3:0]  EPS_INIT    = 4'd0,
    parameter [1:0]  EPF_INIT    = 2'd2,
    parameter [10:0] GFEPS_INIT  = 11'd400,
    parameter [1:0]  BRG_INIT    = 2'd2,
    parameter        INMS_INIT   = 1'b1,
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
    input  wire [3:0]  i_eps,
    input  wire [1:0]  i_epf,
    input  wire [10:0] i_gf_eps,
    input  wire [1:0]  i_brg,
    input  wire        i_inms,
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
    output reg  [3:0]  o_eps,
    output reg  [1:0]  o_epf,
    output reg  [10:0] o_gf_eps,
    output reg  [1:0]  o_brg,
    output reg         o_inms,
    output reg         o_median,
    output reg         o_gauss,
    output reg         o_isol,
    output reg  [1:0]  o_disp,
    output reg         o_ovc
);

    // {mode, t, lo, hi, gf_eps} = 46 bits, {inms, median, gauss, isol, disp,
    // ovc, epf, eps, brg} = 15 bits.  New fields are appended at the top end of
    // the flag bus and the map is written out once here, so the payload order is
    // never in doubt: bus[45:44]=mode [43:33]=t [32:22]=lo [21:11]=hi
    // [10:0]=gf_eps; flg[14]=inms [13]=median [12]=gauss [11]=isol [10:9]=disp
    // [8]=ovc [7:6]=epf [5:2]=eps [1:0]=brg.
    wire [45:0] a_bus = {i_mode, i_t, i_lo, i_hi, i_gf_eps};
    wire [14:0] a_flg = {i_inms, i_median, i_gauss, i_isol, i_disp, i_ovc,
                         i_epf, i_eps, i_brg};

    reg [45:0] snap_bus;
    reg [14:0] snap_flg;
    reg        tog;

    always @(posedge clk_a or negedge rst_a_n) begin
        if (!rst_a_n) begin
            snap_bus <= {MODE_INIT, T_INIT, LO_INIT, HI_INIT, GFEPS_INIT};
            snap_flg <= {INMS_INIT, MEDIAN_INIT, GAUSS_INIT, ISOL_INIT,
                         DISP_INIT, OVC_INIT, EPF_INIT, EPS_INIT, BRG_INIT};
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
            o_eps    <= EPS_INIT;
            o_epf    <= EPF_INIT;
            o_gf_eps <= GFEPS_INIT;
            o_brg    <= BRG_INIT;
            o_inms   <= INMS_INIT;
            o_median <= MEDIAN_INIT;
            o_gauss  <= GAUSS_INIT;
            o_isol   <= ISOL_INIT;
            o_disp   <= DISP_INIT;
            o_ovc    <= OVC_INIT;
        end else begin
            tog_sync <= {tog_sync[1:0], tog};
            if (take) begin
                o_mode   <= snap_bus[45:44];
                o_t      <= snap_bus[43:33];
                o_lo     <= snap_bus[32:22];
                o_hi     <= snap_bus[21:11];
                o_gf_eps <= snap_bus[10:0];
                o_brg    <= snap_flg[1:0];
                o_eps    <= snap_flg[5:2];
                o_epf    <= snap_flg[7:6];
                o_ovc    <= snap_flg[8];
                o_disp   <= snap_flg[10:9];
                o_isol   <= snap_flg[11];
                o_gauss  <= snap_flg[12];
                o_median <= snap_flg[13];
                o_inms   <= snap_flg[14];
            end
        end
    end

endmodule

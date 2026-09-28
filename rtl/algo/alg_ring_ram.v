/////////////////////////////////////////////////////////////////////////////
// alg_ring_ram.v -- 精确深度行缓存(赛题4 显示对齐用)
//
// 为什么不能直接用 simple_dual_port_ram:
//   那个包装模块里 MEMORY_DEPTH = 2**ADDR_WIDTH, 深度一律向上取到 2 的幂。
//   ROWD 11->14 之后 alg_vdisp 的行缓存 ROWS=15:
//     彩色环 SIZE = 15*1280 = 19200 -> 需要 15 位地址 -> 数组被撑成 32768 深,
//     每 1024 深一块 x 16bit 折 2 块 = 64 块(原来是 16384 深 -> 32 块);
//     边缘环 SIZEE = 15*640 = 9600 -> 16384 深 -> 32 块(原来 16 块)。
//   BRAM 合计 256 块挡不住(PnR: capacity=256 usage=278)。
//
// 本模块按 DEPTH 精确建数组, Efinity 按 1024 深一块地拼:
//   彩色环 -> ceil(19200/1024)=19 块深 x 2 = 38 块, 边缘环 -> 10 x 2 = 20 块,
//   合计 58 块(比 96 块省 38 块)。
//
// 端口与时序和 simple_dual_port_ram(OUTPUT_REG="TRUE") 完全一致:
//   写: we 有效那拍写入; 读: re 有效后 rdata 延迟 2 拍(OUTPUT_REG="TRUE")。
//   地址由调用方保证 < DEPTH(环形回卷在 alg_vdisp 里已经做好)。
/////////////////////////////////////////////////////////////////////////////

module alg_ring_ram #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ADDR_WIDTH = 15,
    parameter integer DEPTH      = 19200,
    parameter         OUTPUT_REG = "TRUE"
) (
    input  wire [(DATA_WIDTH-1):0] wdata,
    input  wire [(ADDR_WIDTH-1):0] waddr,
    input  wire [(ADDR_WIDTH-1):0] raddr,
    input  wire                    we,
    input  wire                    wclk,
    input  wire                    re,
    input  wire                    rclk,
    output wire [(DATA_WIDTH-1):0] rdata
);

    reg [(DATA_WIDTH-1):0] ram [0:DEPTH-1];
    reg [(DATA_WIDTH-1):0] r_rdata_1P;
    reg [(DATA_WIDTH-1):0] r_rdata_2P;

    always @(posedge wclk) begin
        if (we)
            ram[waddr] <= wdata;
    end

    always @(posedge rclk) begin
        if (re)
            r_rdata_1P <= ram[raddr];
        r_rdata_2P <= r_rdata_1P;
    end

    generate
        if (OUTPUT_REG == "TRUE")
            assign rdata = r_rdata_2P;
        else
            assign rdata = r_rdata_1P;
    endgenerate

endmodule

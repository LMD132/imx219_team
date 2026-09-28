

`timescale 1ps/1ps
//=============================================================================
// ddr_rd_buffer.v -- DDR3 AXI 读侧: 把一帧字流读出来 -> RD FIFO -> 下游按像素时钟排空
//
//  本版本新增 "双基址交替突发"(时域降噪 TEMP 的取数通道, 见 docs/时序降噪_移植说明.md):
//    同一个地址发生器按 当前帧 bank / 上一帧 bank(同帧偏移) 交替发 AR 突发,
//    两条数据流按 rd_prev_sel 各进一个 FIFO(rd_fifo_rddata / rd_fifo_rddata_prev),
//    下游同一拍排空, 于是第 k 个字天然配成对(同一像素位置的连续两帧)。融合在
//    frame_buffer.v 的 alg_blend_bytes 里做, 本模块只负责把两条流对齐搬出来。
//
//  为什么两条流能共用一个地址发生器: bank_switch 的 bank 基址都按 4096 对齐
//    (FRAME_LEN 向上取整到 4K), 两条流的 4K 突发切分(first/mid/last 长度)完全
//    一样, 差的只是基址, 所以一个 arlen 序列对两条都成立。突发总数是 2N(N = 单帧
//    突发数), 偶数, 最后一发必然是 "上一帧" 那条 —— 与单流版本一样, 读完最后一发
//    才 ddr_read_stop -> bank_sw 翻 bank。
//
//  注意: 本模块恒定交替(不管 TEMP 是不是 0)。不做 "TEMP=0 就不读上一帧" 的开关,
//    因为读侧在 axi_clk 域、排空/融合侧在 o_clk 域, 两个域各自判断"这帧读不读上
//    一帧"时, 滑条一动两边的判断会在某一帧错开: 排空侧要等上一帧 FIFO 的数据,
//    而读侧没发, 那双 FIFO 排空会把整帧画面卡死。恒定交替在结构上没有这个风险,
//    代价只是 DDR 读流量翻倍(一帧 ~900 个 128 拍突发, 约占帧周期的 4%)。
//    TEMP=0 时画面靠 alg_blend_bytes 的 alpha==0 直通逐位等于单流版本。
//=============================================================================
module ddr_rd_buffer #(
parameter AXI_DATA_WIDTH     = 512,  //!AXI接口位宽
parameter AXI_ADDR_WIDTH     = 33,   //!AXI地址位宽
parameter RD_FIFO_DEPTH      = 1024, //!当前帧 read fifo depth
parameter RD_FIFO_PREV_DEPTH = 512,  //!上一帧 read fifo depth (比当前帧浅一档, 省 Memory)
parameter BURST_LEN          = 15

) (

input 								            axi_clk,
input 								            axi_clk_rst_n,
input 								            start,//!电平有效。

input		[AXI_ADDR_WIDTH-1:0]	            start_addr,
input		[AXI_ADDR_WIDTH-1:0]	            start_addr_prev, //!上一帧 bank 基址(同帧偏移读出)
input		[24:0]								burst_len,
input wire                                     bank_sw_ack	,
output  wire                                     bank_sw 		  ,

input											rd_fifo_rdclk,
input                                           rd_fifo_rst_p,
output	reg										rd_fifo_rdvalid ='d0,
output	 [AXI_DATA_WIDTH-1:0] 				    rd_fifo_rddata,
output wire										rd_fifo_rdempty,
output	 [AXI_DATA_WIDTH-1:0] 				    rd_fifo_rddata_prev,
output wire										rd_fifo_rdempty_prev,
input	 wire									rd_fifo_rden,

output [5:0] 									    arid,
output  [AXI_ADDR_WIDTH-1:0] 	                    araddr,
output  [8-1:0] 						            arlen,
output  [2:0] 										arsize,
output  [1:0] 										arburst,
output  											arlock,
output reg 											arvalid,
output  											arapcmd,
output 												arqos,
input 												arready,
output  [3:0] 								        arcache,
output [2:0]                                        arprot,

input [5:0] 									rid,
input [AXI_DATA_WIDTH-1:0] 						rdata,
input 											rlast,
input 											rvalid,
output  reg										rready,
input [1:0] 									rresp,
output[31:0]									wr_fifo_rd_data_test,

output [7:0] test_BURST_LEN
);
assign test_BURST_LEN = BURST_LEN;
localparam AXSIZE_WTH = $clog2(AXI_DATA_WIDTH/8);//!内部数据
localparam RD_USEDW_WITH = $clog2(RD_FIFO_DEPTH) ;
localparam RD_PREV_USEDW_WITH = $clog2(RD_FIFO_PREV_DEPTH) ;
localparam ADDR_SHIFT_BITS = $clog2(AXI_DATA_WIDTH/8);
reg 										ddr_rd_valid;                      
reg [AXI_DATA_WIDTH-1:0] 					ddr_rd_data;     
wire [RD_USEDW_WITH   :0]					rd_fifo_wrusedw;   
wire [RD_PREV_USEDW_WITH:0]					rd_fifo_wrusedw_prev;
 
reg	 [AXI_ADDR_WIDTH-1:0] 					ddr_addr	= 'd0;  
reg	 [AXI_ADDR_WIDTH-1:0] 					ddr_addr_prev = 'd0;
reg			[2:0]							start_sync = 'd0;
reg	[24:0]									burst_len_r = 'd0;
reg [AXI_ADDR_WIDTH-1:0] 					start_addr_r = 'd0;
reg [AXI_ADDR_WIDTH-1:0] 					start_addr_prev_r = 'd0;
reg                                         sync_r0 = 'd0;
reg                                         sync_r1 = 'd0;
reg                                         sync_r2 = 'd0;
reg [8-1:0]                                 first_burst_cnt = 'd0;
reg	[8-1:0] 			                    last_burst_cnt = 'd0;
reg [24:0]                                  align_burst_num = 'd0;
reg [24:0]                                  burst_num = 'd0;

//--------------------------------------------------------------------------
// 双基址交替: 每个突发用哪个 bank, 以及两条流各自发到第几个突发
//   rd_prev_sel = 0 -> 当前帧 bank   1 -> 上一帧 bank
//   一帧内: 当前帧第0发 -> 上一帧第0发 -> 当前帧第1发 -> ... (同帧偏移)
//
//   rd_prev_sel 是"下一发要去哪个 bank"(给 araddr/arlen 用), 它在 AR 握手的
//   那一拍就翻到下一发 —— 而这一发的数据要过好几拍才回来。所以数据侧必须另用
//   一个"这一发是谁"的标签 ddr_stream_r: 它在 AR 握手时抄下 rd_prev_sel 的旧值,
//   直到下一发 AR 才变。状态机是"发完一发、收完 rlast 才发下一发"的串行结构,
//   最后一次 ddr_rd_valid 比下一次 AR 早 >=2 拍, 所以标签对每个数据字节都成立。
//--------------------------------------------------------------------------
reg                                         rd_prev_sel = 1'b0;
reg                                         ddr_stream_r = 1'b0;
reg [24:0]                                  seg_cur  = 'd0;
reg [24:0]                                  seg_prev = 'd0;
wire                                        rd_addr_en;      // = arvalid & arready, 提前声明(上面地址块要用)

//wire pos_start;
always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
	if( !axi_clk_rst_n )			start_sync <= 'd0;
	else 				    start_sync <= {start_sync[1:0],start};
end

assign pos_start = start_sync[1:0] == 2'b01;
always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
	if( !axi_clk_rst_n ) begin
		sync_r0 <= 1'b0;
		sync_r1 <= 1'b0;
		sync_r2 <= 1'b0;
	end else begin 
		sync_r0 <= pos_start;
		sync_r1 <= sync_r0;
		sync_r2 <= sync_r1;
	end 
end

always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
	if( !axi_clk_rst_n ) begin
			// cfg_alen_r   <= cfg_alen;
			burst_len_r<= burst_len;
			start_addr_r <= start_addr;
			start_addr_prev_r <= start_addr_prev;
	end else begin
			burst_len_r  <= pos_start ? burst_len   : burst_len_r ;
			// cfg_alen_r   <= pos_start ? cfg_alen    :cfg_alen_r;
			start_addr_r <= pos_start ? start_addr  :start_addr_r;
			start_addr_prev_r <= pos_start ? start_addr_prev : start_addr_prev_r;
	end
end

wire [12-ADDR_SHIFT_BITS:0]     first_4k_burst_len = {1'b0,~start_addr_r[11:ADDR_SHIFT_BITS]} + 1'b1;
wire [31:0]                     last_4k_burst_len  = burst_len_r - first_4k_burst_len;


generate
    if( BURST_LEN == 1)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[0]  ? {7'd0,first_4k_burst_len[0]}-'d1  :BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[0]  ? {7'd0,last_4k_burst_len[0]}-1  :BURST_LEN;
            burst_num <= align_burst_num[24:1] + 2 ;
        end 
    else if( BURST_LEN == 3 )
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[1:0]? {6'd0,first_4k_burst_len[1:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[1:0]? {6'd0,last_4k_burst_len[1:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:2] + 2 ;
        end 
    else if( BURST_LEN == 7)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[2:0]? {5'd0,first_4k_burst_len[2:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[2:0]? {5'd0,last_4k_burst_len[2:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:3] + 2 ;
        end 
    else if( BURST_LEN == 15)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[3:0]? {4'd0,first_4k_burst_len[3:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[3:0]? {4'd0,last_4k_burst_len[3:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:4] + 2 ;
        end 
    else if( BURST_LEN == 31)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[4:0]? {3'd0,first_4k_burst_len[4:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[4:0]? {3'd0,last_4k_burst_len[4:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:5] + 2 ;
        end 
    else if( BURST_LEN == 63)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[5:0]? {2'd0,first_4k_burst_len[5:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[5:0]? {2'd0,last_4k_burst_len[5:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:6] + 2 ;
        end 
    else if( BURST_LEN == 127)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[6:0]?{1'd0,first_4k_burst_len[6:0]}-1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[6:0]? {1'd0,last_4k_burst_len[6:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:7] + 2 ;
        end 
    else if( BURST_LEN == 255)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[7:0]?first_4k_burst_len[7:0]-1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[7:0]? last_4k_burst_len[7:0]-1:BURST_LEN;
            burst_num <= align_burst_num[24:8] + 2 ;
        end 

endgenerate

always @( posedge axi_clk or negedge axi_clk_rst_n   )
begin 
    if( !axi_clk_rst_n ) begin
        align_burst_num <= 'd0;
    end else begin //w_wr_sync_r1;
	    align_burst_num <= burst_len_r - first_burst_cnt - last_burst_cnt -'d2 ;
    end 
end

//====================================================================================
//address process
//  两条流各自的地址计数器, 只在轮到自己那一发时 + 步长;
//  发哪个 bank 由 rd_prev_sel 组合选择。突发长度序列(first/mid/last)两条一样。
//====================================================================================
wire [24:0]                 burst_num_m1 = burst_num - 25'd1;
wire [24:0]                 sel_seg      = rd_prev_sel ? seg_prev : seg_cur;
wire                        sel_first    = (sel_seg == 25'd0);
wire                        sel_last     = (sel_seg == burst_num_m1);
wire [8-1:0]                sel_arlen    = sel_first ? first_burst_cnt :
                                           (sel_last  ? last_burst_cnt  : BURST_LEN);
// 显式给足位宽: "sel_arlen+1" 这种混了无位宽常数的式子在自己决定位宽的上下文里
// 会被判成不定宽, iverilog 直接报错, Efinity 也可能按最窄位宽截掉进位。
wire [8:0]                  sel_alen_p1  = {1'b0, sel_arlen} + 9'd1;
wire [AXI_ADDR_WIDTH-1:0]   nx_ddr_addr      = ddr_addr      + {sel_alen_p1,{ADDR_SHIFT_BITS{1'b0}} };
wire [AXI_ADDR_WIDTH-1:0]   nx_ddr_addr_prev = ddr_addr_prev + {sel_alen_p1,{ADDR_SHIFT_BITS{1'b0}} };

always @(posedge axi_clk or negedge axi_clk_rst_n) 
begin
	if (!axi_clk_rst_n) begin
		ddr_addr       <= start_addr_r;
		ddr_addr_prev  <= start_addr_prev_r;
		rd_prev_sel    <= 1'b0;
		ddr_stream_r   <= 1'b0;
		seg_cur        <= 'd0;
		seg_prev       <= 'd0;
	end else if( sync_r2 ) begin
		ddr_addr       <= start_addr_r;
		ddr_addr_prev  <= start_addr_prev_r;
		rd_prev_sel    <= 1'b0;      // 每帧先读当前帧那一发
		ddr_stream_r   <= 1'b0;
		seg_cur        <= 'd0;
		seg_prev       <= 'd0;
	end else if (rd_addr_en) begin
		ddr_stream_r <= rd_prev_sel;     // 非阻塞: 抄的是"刚发出去那一发"的归属
		rd_prev_sel <= ~rd_prev_sel;
		if (rd_prev_sel) begin
			ddr_addr_prev <= nx_ddr_addr_prev;
			seg_prev      <= seg_prev + 25'd1;
		end else begin
			ddr_addr      <= nx_ddr_addr;
			seg_cur       <= seg_cur + 25'd1;
		end
	end 
end 


//=====================================================================================
// ddr alen process: arlen 直接由 sel_seg/sel_first/sel_last 组合给出。
//   原版用 "sync_r2 预置 first, 每拍 rd_addr_en 预置下一发的长度" 的寄存器写法,
//   那套只在"每发都是同一条流"时成立 —— 交替突发下第 k 发和第 k+1 发属于不同
//   bank, 寄存器的值永远是上一发的长度, 会串到另一条流上(第一发还好, 因为两条
//   流的第 0 发都是 first)。sel_arlen 的输入全是寄存器, 组合路径很短。
//=====================================================================================
assign arapcmd  = 1'b0;  
assign arlock   = 1'b0;  
assign arqos    = 1'b0; 
assign arid     = 6'h00;
assign arsize   = AXSIZE_WTH;
assign arlen	= sel_arlen;
assign arburst  = 2'b01;
assign araddr   = rd_prev_sel ? ddr_addr_prev : ddr_addr;
assign arprot       = 3'd2;
assign arcache 		= 4'd3; 


assign rd_addr_en = arvalid & arready;

always @(posedge axi_clk or negedge axi_clk_rst_n )											
begin
	if( !axi_clk_rst_n )							ddr_rd_valid <= 1'b0;
	else											ddr_rd_valid <= rvalid;				
end 			

always @( posedge axi_clk )
begin
    ddr_rd_data <= rdata;
end

//==========================================================================================
reg [1:0] state = 2'd0;
reg rd_req = 0;
reg ddr_read_stop = 'd0;
always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
    if( !axi_clk_rst_n )
        ddr_read_stop <= 1'b0;
    else if( sync_r2 )
        ddr_read_stop <= 1'b0;
    // 必须带 rd_prev_sel: sel_last 对两条流都会成立(各自 seg 走到 burst_num-1),
    // 而一帧的最后一发是"上一帧"那条(总发数 2N 是偶数)。若不限定, 会在倒数第二发
    // (当前帧最后一发)就把状态机停掉, 上一帧那条少 128 个字 -> 帧尾错位。
    else if( rd_addr_en && rd_prev_sel && sel_last )
        ddr_read_stop <= 1'b1;
end
assign bank_sw = ddr_read_stop;

// 只按 "这一发要去哪个 FIFO" 查空间: 两条流各自不溢出就够了。严格交替下谁也不会
// 被另一条饿着 —— 空间不够时 rd_req 拉低, 状态机停在 state1 等, 两条流一起等。
wire        room_cur  = (RD_FIFO_DEPTH      >= rd_fifo_wrusedw      + BURST_LEN + 5);
wire        room_prev = (RD_FIFO_PREV_DEPTH >= rd_fifo_wrusedw_prev + BURST_LEN + 5);
wire        room_sel  = rd_prev_sel ? room_prev : room_cur;

always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
    if( !axi_clk_rst_n )
        rd_req <= 1'b0;
    else if( !room_sel )//( rd_fifo_wrusedw > 512  )//
        rd_req <= 1'b0;
    else 
        rd_req <= 1'b1;
end


always @( posedge axi_clk or negedge axi_clk_rst_n )
begin
    if( !axi_clk_rst_n ) begin
        arvalid <= 1'b0;
        rready <= 1'b0;
        state <= 'd0;
    end else if(rd_fifo_rst_p) begin
        state <= 2'd0;
        arvalid <= 1'b0;
        rready <= 1'b0;
    end else begin
        rready <= 1'b1;
        case(state )
        2'd0 : begin
            state <= sync_r2 ? 2'd1 : 2'd0;
        end
        2'd1 : begin
            if( rd_req ) begin
                state <= 2'd2;
                arvalid <= 1'b1;
            end
        end
        2'd2 : begin
            if( arready) begin
                state <= 2'd3;
                arvalid <= 1'b0;
                rready <= 1'b1;
            end
        end
        2'd3 : begin
            if( rvalid & rlast) begin//rready & 
                if( ddr_read_stop )
                    state <= 2'd0;
                else 
                    state <= 2'd1;
            end
        end
        default :;
    
        endcase
end
end


wire										rd_fifo_wr_full;
wire										rd_fifo_wr_full_prev;
wire [RD_USEDW_WITH   :0] 					rd_fifo_rdusedw;
wire [RD_PREV_USEDW_WITH:0]					rd_fifo_rdusedw_prev;

// 当前帧那条(ddr_rd_valid & ~ddr_stream_r): 与单流版本逐位一致
	DC_FIFO
# (
  	.FIFO_MODE  ( "Normal"    	 ), //"Normal"; //"ShowAhead"
    .DATA_WIDTH ( AXI_DATA_WIDTH ),
    .FIFO_DEPTH ( RD_FIFO_DEPTH  )
  ) u_rd_fifo(   
  //System Signal
  /*i*/.Reset   (	(~axi_clk_rst_n)	|| rd_fifo_rst_p		), 
  /*i*/.WrClk   (axi_clk			), 
  /*i*/.WrEn    (ddr_rd_valid & ~ddr_stream_r	), 
  /*o*/.WrDNum  (rd_fifo_wrusedw	), 
  /*o*/.WrFull  (rd_fifo_wr_full 	), 
  /*i*/.WrData  (ddr_rd_data 		), 
  /*i*/.RdClk   (rd_fifo_rdclk		), 
  /*i*/.RdEn    (rd_fifo_rden		), 
  /*o*/.RdDNum  (rd_fifo_rdusedw	), 
  /*o*/.RdEmpty (rd_fifo_rdempty	), 
  /*o*/.RdData  (rd_fifo_rddata		)  
);

// 上一帧那条: 同一发序列的错拍副本(rd_prev_sel=1 的突发), 下游同拍排空
	DC_FIFO
# (
  	.FIFO_MODE  ( "Normal"    	 ), //"Normal"; //"ShowAhead"
    .DATA_WIDTH ( AXI_DATA_WIDTH ),
    .FIFO_DEPTH ( RD_FIFO_PREV_DEPTH )
  ) u_rd_fifo_prev(   
  /*i*/.Reset   (	(~axi_clk_rst_n)	|| rd_fifo_rst_p		), 
  /*i*/.WrClk   (axi_clk			), 
  /*i*/.WrEn    (ddr_rd_valid & ddr_stream_r	), 
  /*o*/.WrDNum  (rd_fifo_wrusedw_prev	), 
  /*o*/.WrFull  (rd_fifo_wr_full_prev 	), 
  /*i*/.WrData  (ddr_rd_data 		), 
  /*i*/.RdClk   (rd_fifo_rdclk		), 
  /*i*/.RdEn    (rd_fifo_rden		), 
  /*o*/.RdDNum  (rd_fifo_rdusedw_prev	), 
  /*o*/.RdEmpty (rd_fifo_rdempty_prev	), 
  /*o*/.RdData  (rd_fifo_rddata_prev	)  
);

always @( posedge axi_clk )
begin
    rd_fifo_rdvalid <=   rd_fifo_rden;
end



endmodule

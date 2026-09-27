

module bank_switch #(
		parameter FB_NUM = 2,
		parameter MAX_VID_WIDTH = 1920,
		parameter MAX_VID_HIGHT = 1080,
		parameter START_ADDR= 0,
		parameter VID_DATA_WIDTH= 16,
		parameter AXI_DATA_WIDTH = 256
		
)

(
input	wire		ddr_clk,//!时钟
input	wire		rst_n,//!复位，低电平有效

input	wire		wr_sw,//!写bank切换请求信号,电平有效
input	wire		rd_sw,//!读bank切换请求信号,电平有效

output	reg	[1:0]	wr_bank,
output	reg	[1:0]	rd_bank,
output	reg			rd_sw_ack,
output	reg			wr_sw_ack,
output	reg[31:0] 	rd_start_addr,
output	reg[31:0]	wr_start_addr,
output	wire[31:0]	rd_start_addr_prev




);                       
localparam AXI_BYTE_NUMBER = AXI_DATA_WIDTH/8  ;
	localparam FRAME_LEN_RAW = MAX_VID_WIDTH*MAX_VID_HIGHT*VID_DATA_WIDTH/8 + 32'h200;
	// 双基址读(当前帧 + 上一帧)要求各 bank 基址低 12 位相同, 否则两条读出流的
	// 4K 突发切分不同, 一个地址发生器就无法交替发这两条的地址。这里向上取整到 4096。
	// 只影响 bank 间距(多占一点 DDR); 一帧的数据长度由 ddr_frame_len 决定, 与本参数无关。
	localparam FRAME_LEN     = (FRAME_LEN_RAW + 32'd4095) & 32'hFFFFF000;

localparam FRAME_1ST_START_ADDR = START_ADDR;
localparam FRAME_2ND_START_ADDR = FRAME_LEN + START_ADDR ;

localparam FRAME_3RD_START_ADDR = FRAME_LEN+ FRAME_2ND_START_ADDR;
	
	// 第 4 个 bank(读上一帧用): 与前面同一个口径 bank_addr = START_ADDR + n*FRAME_LEN
	localparam FRAME_4TH_START_ADDR = FRAME_LEN+ FRAME_3RD_START_ADDR;
	
	// bank 号 -> 起始地址。四缓冲轮换里 bank 号就是帧龄顺序(见 four_fb 的注释),
	// 所以上一帧基址 = bank_addr(rd_bank - 1); 2bit 减法天然回绕到第 4 个 bank。
	function [31:0] bank_addr;
		input [1:0] b;
		begin
			case( b )
				2'd0:		bank_addr = FRAME_1ST_START_ADDR;
				2'd1:		bank_addr = FRAME_2ND_START_ADDR;
				2'd2:		bank_addr = FRAME_3RD_START_ADDR;
				default:	bank_addr = FRAME_4TH_START_ADDR;
			endcase
		end
	endfunction


	
	generate 
	if( FB_NUM == 1 ) begin : one_fb 
		always @( posedge ddr_clk or negedge rst_n ) 
		begin 
			if( !rst_n ) begin
				wr_bank <= 2'b00;
				rd_bank <= 2'b01;
				wr_sw_ack <= 1'b0;
				rd_sw_ack <= 1'b0;     
				rd_start_addr <= FRAME_1ST_START_ADDR; 
				wr_start_addr <= FRAME_1ST_START_ADDR; 
			end else begin 
				wr_bank <= 2'b00;
				rd_bank <= 2'b00;
				wr_sw_ack <= wr_sw;
				rd_sw_ack <= rd_sw;   
				rd_start_addr <= FRAME_1ST_START_ADDR;
				wr_start_addr <= FRAME_1ST_START_ADDR;
			end 
		end 

	end else if( FB_NUM == 2 ) begin :tow_fb
		reg			bank_sw_en = 1'b0;
		reg			bank_sw_en_d1 = 1'b0;
		wire		pos_bank_sw_en;
		always @( posedge ddr_clk )
		begin
			bank_sw_en <= wr_sw & rd_sw;
			bank_sw_en_d1 <= bank_sw_en;
		end
		assign pos_bank_sw_en = {bank_sw_en_d1,bank_sw_en} == 2'b01;
		
		always @( posedge ddr_clk or negedge rst_n)
		begin
			if( !rst_n ) begin
				wr_bank <= 2'b00;
				rd_bank <= 2'b01;      
				wr_start_addr <= FRAME_1ST_START_ADDR; 
				rd_start_addr <= FRAME_2ND_START_ADDR; 
			end else if( pos_bank_sw_en ) begin//必须两个bank同时切换
				wr_bank[0] <= ~wr_bank[0];
				rd_bank[0] <= wr_bank[0];
				rd_bank[1] <= 1'b0;
				wr_bank[1] <= 1'b0;      
				wr_start_addr <= wr_bank[0] ? FRAME_1ST_START_ADDR : FRAME_2ND_START_ADDR;
				rd_start_addr <= wr_bank[0] ? FRAME_2ND_START_ADDR : FRAME_1ST_START_ADDR; 
			end
		end
		
		always @( posedge ddr_clk )
		begin
			wr_sw_ack	 <= pos_bank_sw_en;
			rd_sw_ack	 <= pos_bank_sw_en;
		end
		
		
	end else if( FB_NUM == 3 ) begin :three_fb
		reg	[1:0] 	dirt_bank = 2'b10;
		reg			dirt_en = 1'b1;
		reg	[1:0]	clean_bank = 2'b00;
		reg			clean_en = 1'b0;
		wire		pos_wr_sw_en;
		wire		pos_rd_sw_en;
		reg			wr_sw_d1 = 1'b0;
		reg			rd_sw_d1 = 1'b0;
		always @( posedge ddr_clk )
		begin
				wr_sw_d1 <= wr_sw;
				rd_sw_d1 <= rd_sw;
		end
		assign pos_wr_sw_en = {wr_sw_d1,wr_sw} == 2'b01;
		assign pos_rd_sw_en = {rd_sw_d1,rd_sw} == 2'b01;
		
		always @( posedge ddr_clk )
		begin
			wr_sw_ack <= pos_wr_sw_en;
			rd_sw_ack <= pos_rd_sw_en;
		end
		always @( posedge ddr_clk or negedge rst_n)
		begin
			if( !rst_n ) begin
				wr_bank <= 2'b00;
				rd_bank <= 2'b01;
				dirt_bank <= 2'b10;
				dirt_en <= 1'b1;
				clean_en <= 1'b0;
				clean_bank <= 2'b00;    
				
				wr_start_addr <= FRAME_1ST_START_ADDR;
				rd_start_addr <= FRAME_2ND_START_ADDR; 
			end	else if( pos_wr_sw_en ) begin
						
				if( dirt_en ) begin
						wr_bank <= dirt_bank; 
						wr_start_addr <= (dirt_bank ==  2'b00) ? FRAME_1ST_START_ADDR :((dirt_bank == 2'b01)? FRAME_2ND_START_ADDR : FRAME_3RD_START_ADDR );
						clean_bank <= wr_bank;
						clean_en <= 1'b1;
						dirt_en	<= 1'b0;
				end else begin
						wr_bank <= wr_bank;
						clean_en <= clean_en;
				end
						
			end else if( pos_rd_sw_en ) begin
				if( clean_en ) begin
						rd_bank <= clean_bank;   
						rd_start_addr <= (clean_bank ==  2'b00) ? FRAME_1ST_START_ADDR :((clean_bank == 2'b01)? FRAME_2ND_START_ADDR : FRAME_3RD_START_ADDR );
						dirt_bank <= rd_bank;
						dirt_en <= 1'b1;
						clean_en <= 1'b0;
				end else begin
						rd_bank <= rd_bank;
						dirt_en <= dirt_en;
				end
				clean_en <= 1'b0;
			end
		end
						
	
	//-----------------------------------------------------------------------------
	// 四缓冲轮换 (FB_NUM == 4)
	//   bank 号就是帧的代数: 读侧每滚动一次 rd_bank 就 +1, 写侧永远往 wr_bank+1 写,
	//   于是三条关系恒成立(rd_start_addr_prev 只要算 rd_bank-1 就是这么来的):
	//       wr_bank      = rd_bank + 1     写侧比正在显示的那一帧新一帧
	//       rd_bank - 1  = 上一帧           读侧还要读它, 写侧碰不得
	//       clean_bank   = 刚写满的那一帧    等 clean_en, 读侧一滚它就变成新的 rd_bank
	//   为什么必须 4 个 bank: {正在显示, 上一帧, 正在写} 三个角色 3 个 bank 排不下,
	//   上一帧那个 bank 必然被写端抢走 -> 时域降噪读上一帧会读到正在被覆盖的帧。
	//   free_en: 写完一帧要等读侧滚动一次(把 rd 让到 wr-1)才允许写下一帧, 否则写侧的
	//   wr+1 会踩到 rd-1 = 上一帧。
	//   完成脉冲可能同拍到达(写侧相机 30fps, 读侧显示约 60fps, 相位会漂), 所以先把
	//   边沿转成待处理请求再逐个服务: 写侧优先, 读侧同拍让路, 两个请求都不会丢。
	//-----------------------------------------------------------------------------
	end else if( FB_NUM == 4 ) begin :four_fb
		reg	[1:0]	clean_bank = 2'b00;
		reg			clean_en   = 1'b0;
		reg			free_en    = 1'b1;
		wire		pos_wr_sw_en;
		wire		pos_rd_sw_en;
		reg			wr_sw_d1 = 1'b0;
		reg			rd_sw_d1 = 1'b0;
		reg			wr_req   = 1'b0;
		reg			rd_req   = 1'b0;
		always @( posedge ddr_clk )
		begin
				wr_sw_d1 <= wr_sw;
				rd_sw_d1 <= rd_sw;
		end
		assign pos_wr_sw_en = {wr_sw_d1,wr_sw} == 2'b01;
		assign pos_rd_sw_en = {rd_sw_d1,rd_sw} == 2'b01;
		
		wire		wr_go = wr_req & free_en;
		wire		rd_go = rd_req & clean_en & ~wr_go;
		
		always @( posedge ddr_clk or negedge rst_n )
		begin
			if( !rst_n )
				wr_req <= 1'b0;
			else if( pos_wr_sw_en )
				wr_req <= 1'b1;
			else if( wr_go )
				wr_req <= 1'b0;
		end
		always @( posedge ddr_clk or negedge rst_n )
		begin
			if( !rst_n )
				rd_req <= 1'b0;
			else if( pos_rd_sw_en )
				rd_req <= 1'b1;
			else if( rd_go )
				rd_req <= 1'b0;
		end
		
		always @( posedge ddr_clk )
		begin
				wr_sw_ack <= wr_go;
				rd_sw_ack <= rd_go;
		end
		
		// 复位: wr_bank=0 / rd_bank=3, 于是 rd_bank-1 = 2 就是上一帧; 第一帧写满后读侧滚到
		// 0, 上一帧 = 3, 关系自洽。地址一律用 bank_addr 算, 不做地址加法。
		always @( posedge ddr_clk or negedge rst_n )
		begin
			if( !rst_n ) begin
				wr_bank 			<= 2'b00;
				rd_bank 			<= 2'b11;
				clean_bank			<= 2'b00;
				clean_en			<= 1'b0;
				free_en				<= 1'b1;
				wr_start_addr <= bank_addr(2'b00);
				rd_start_addr <= bank_addr(2'b11);
			end else if( wr_go ) begin
				// 一帧写满: 这一帧交给读侧(clean), 写侧换到 bank+1 —— 那个 bank 比上一帧还老
				// 两帧, 读侧绝不可能在用, 所以四缓冲下写侧不必等读侧把 bank 挪走。
				clean_bank    <= wr_bank;
				clean_en      <= 1'b1;
				wr_bank       <= wr_bank + 2'd1;
				wr_start_addr <= bank_addr(wr_bank + 2'd1);
				free_en       <= 1'b0;
			end else if( rd_go ) begin
				// 读侧滚动: rd 往前一帧(上一帧就是原来的 rd), 同时允许写侧开下一帧。
				rd_bank       <= clean_bank;
				rd_start_addr <= bank_addr(clean_bank);
				clean_en      <= 1'b0;
				free_en       <= 1'b1;
			end
		end
	end
	// 上一帧起始地址: 只有 FB_NUM==4 有意义; 其它档镜像 rd_start_addr, 端口不悬空。
	assign rd_start_addr_prev = ( FB_NUM == 4 ) ? bank_addr(rd_bank - 2'd1) : rd_start_addr;
	endgenerate


endmodule

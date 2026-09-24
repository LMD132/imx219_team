module raw_to_rgb
#(
	parameter	P_DEPTH			= 10,
	parameter	PW				= P_DEPTH*2,
	parameter	LEGACY			= 1'b1		//已废弃：本版行边界在下方 row_mux 里统一钳位
)
(
	input			i_arstn,
	input			i_pclk,

	input			i_vsync,
	input			i_hsync,
	input			i_de,
	input			i_valid,
	input[PW-1:0]	i_p_0,		//行 N  ,窗口 y+2
	input[PW-1:0]	i_p_1,		//行 N-1,窗口 y+1
	input[PW-1:0]	i_p_2,		//行 N-2,窗口 y  (中心行 = 输出行)
	input[PW-1:0]	i_p_3,		//行 N-3,窗口 y-1
	input[PW-1:0]	i_p_4,		//行 N-4,窗口 y-2

	output			o_vsync,
	output			o_hsync,
	output			o_de,
	output			o_valid,
	output[10:0]	o_x_cnt,
	output[10:0]	o_y_cnt,
	output[PW-1:0]	o_r,
	output[PW-1:0]	o_g,
	output[PW-1:0]	o_b
);

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 5x5 梯度校正线性插值 (Malvar-He-Cutler)，整数复刻 MATLAB R2021b demosaic(I,'rggb')
//
// 行窗口：输出行 y = N-2，窗口五行 = 行 N-4 .. N，分别记为
//         m2(行 N-4, y-2)  m1(行 N-3, y-1)  z0(行 N-2, y)  p1(行 N-1, y+1)  p2(行 N, y+2)
// 列窗口：输出偶像素 x=2T / 奇像素 x=2T+1，抽头横跨 x-2 .. x+2
//         字 T-1 = XX:11 (2P)   字 T = XX:00 (1P)   字 T+1 = XX:01 (0P)
//         _0 = 偶列, _1 = 奇列
//
//   x-2   x-1    x    x+1   x+2
//   L2    L1     C    R1    R2          <- 中心行 z0
//   UL    U1          U1    UR          <- 上行 m1  (L2/R2 用 z0 行, U2/D2 用 m2/p2 行)
//   DL    D1          D1    DR          <- 下行 p1
//   U2    U2     C    U2    U2          <- 行 m2
//   D2    D2     C    D2    D2          <- 行 p2
//
//   red()    R=C
//            G=( 8C - 2(L2+R2+U2+D2) + 4(L1+R1+U1+D1) ) >> 4
//            B=(12C - 3(L2+R2+U2+D2) + 4(UL+UR+DL+DR) ) >> 4
//   green2() R=(10C - 2(UL+UR+DL+DR) - 2(L2+R2) +  (U2+D2) + 8(L1+R1) ) >> 4
//            G=C
//            B=(10C - 2(UL+UR+DL+DR) +  (L2+R2) - 2(U2+D2) + 8(U1+D1) ) >> 4
//   green1() R=green2() 的 B 式, B=green2() 的 R 式, G=C
//   blue()   R=red() 的 B 式,   G=red() 的 G 式,   B=C
//
//   >> 为算术右移(=floor)，之后饱和到 [0,255] —— 与 MATLAB 的 eml_cast(...,'floor') 一致。
//
// RGGB 分工： (偶行,偶列)=red  (偶行,奇列)=green2  (奇行,偶列)=green1  (奇行,奇列)=blue
// 分支判据 r_y_cnt[0] = N 的奇偶，而输出行 y=N-2 与 N 同奇偶：
//   r_y_cnt[0]==1 -> y 奇 -> 低字节(偶列)=green1, 高字节(奇列)=blue   -> G B G B
//   else          -> y 偶 -> 低字节(偶列)=red,    高字节(奇列)=green2 -> R G R G
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

localparam	SUM_W	= P_DEPTH + 2;		//4 个抽头之和
localparam	CAL_W	= P_DEPTH + 7;		//带系数的和，有符号

reg	[10:0]			r_x_cnt;
reg	[10:0]			r_x_cnt_1P;
reg	[10:0]			r_x_cnt_2P;
reg	[10:0]			r_y_cnt;
reg	[10:0]			r_y_cnt_1P;
reg	[10:0]			r_y_cnt_2P;

reg	[PW-1:0]		r_r_00_00_1P;
reg	[PW-1:0]		r_g_00_00_1P;
reg	[PW-1:0]		r_b_00_00_1P;

/* 30 个抽头寄存器：5 行 x 3 字 x 2 字节 */
reg	[P_DEPTH-1:0]	r_bayer_m2_01_0P_0;
reg	[P_DEPTH-1:0]	r_bayer_m2_01_0P_1;
reg	[P_DEPTH-1:0]	r_bayer_m1_01_0P_0;
reg	[P_DEPTH-1:0]	r_bayer_m1_01_0P_1;
reg	[P_DEPTH-1:0]	r_bayer_z0_01_0P_0;
reg	[P_DEPTH-1:0]	r_bayer_z0_01_0P_1;
reg	[P_DEPTH-1:0]	r_bayer_p1_01_0P_0;
reg	[P_DEPTH-1:0]	r_bayer_p1_01_0P_1;
reg	[P_DEPTH-1:0]	r_bayer_p2_01_0P_0;
reg	[P_DEPTH-1:0]	r_bayer_p2_01_0P_1;

reg	[P_DEPTH-1:0]	r_bayer_m2_00_1P_0;
reg	[P_DEPTH-1:0]	r_bayer_m2_00_1P_1;
reg	[P_DEPTH-1:0]	r_bayer_m1_00_1P_0;
reg	[P_DEPTH-1:0]	r_bayer_m1_00_1P_1;
reg	[P_DEPTH-1:0]	r_bayer_z0_00_1P_0;
reg	[P_DEPTH-1:0]	r_bayer_z0_00_1P_1;
reg	[P_DEPTH-1:0]	r_bayer_p1_00_1P_0;
reg	[P_DEPTH-1:0]	r_bayer_p1_00_1P_1;
reg	[P_DEPTH-1:0]	r_bayer_p2_00_1P_0;
reg	[P_DEPTH-1:0]	r_bayer_p2_00_1P_1;

reg	[P_DEPTH-1:0]	r_bayer_m2_11_2P_0;
reg	[P_DEPTH-1:0]	r_bayer_m2_11_2P_1;
reg	[P_DEPTH-1:0]	r_bayer_m1_11_2P_0;
reg	[P_DEPTH-1:0]	r_bayer_m1_11_2P_1;
reg	[P_DEPTH-1:0]	r_bayer_z0_11_2P_0;
reg	[P_DEPTH-1:0]	r_bayer_z0_11_2P_1;
reg	[P_DEPTH-1:0]	r_bayer_p1_11_2P_0;
reg	[P_DEPTH-1:0]	r_bayer_p1_11_2P_1;
reg	[P_DEPTH-1:0]	r_bayer_p2_11_2P_0;
reg	[P_DEPTH-1:0]	r_bayer_p2_11_2P_1;

reg					r_vsync_00_1P;
reg					r_hsync_00_1P;
reg					r_de_00_1P;
reg					r_valid_1P;
reg					r_vsync_00_2P;
reg					r_hsync_00_2P;
reg					r_de_00_2P;
reg					r_valid_2P;

reg	[PW-1:0]		r_row_m2;
reg	[PW-1:0]		r_row_m1;
reg	[PW-1:0]		r_row_z0;
reg	[PW-1:0]		r_row_p1;
reg	[PW-1:0]		r_row_p2;

/* 行源选择：输出行 y=N-2 需要行 N-4..N。帧头 N<4 时 N-4/N-3/N-2 尚不存在，
   用最近的有效行顶替（钳位）。注意这与 MATLAB 的 reflect 填充不同，只用于避免帧头花屏；
   底部 2 行、左右 2 列的精确边界留待后续处理。 */
always@(*)
begin
	case (r_y_cnt)
		11'd0:	begin r_row_m2 = i_p_0; r_row_m1 = i_p_0; r_row_z0 = i_p_0; r_row_p1 = i_p_0; r_row_p2 = i_p_0; end
		11'd1:	begin r_row_m2 = i_p_1; r_row_m1 = i_p_1; r_row_z0 = i_p_1; r_row_p1 = i_p_1; r_row_p2 = i_p_0; end
		11'd2:	begin r_row_m2 = i_p_2; r_row_m1 = i_p_2; r_row_z0 = i_p_2; r_row_p1 = i_p_1; r_row_p2 = i_p_0; end
		11'd3:	begin r_row_m2 = i_p_3; r_row_m1 = i_p_3; r_row_z0 = i_p_2; r_row_p1 = i_p_1; r_row_p2 = i_p_0; end
		default:begin r_row_m2 = i_p_4; r_row_m1 = i_p_3; r_row_z0 = i_p_2; r_row_p1 = i_p_1; r_row_p2 = i_p_0; end
	endcase
end

/* RAW to RGB Debayer filter */
always@(posedge i_pclk)
begin
	if (~i_arstn)
	begin
		r_vsync_00_1P		<= 1'b0;
		r_hsync_00_1P		<= 1'b0;
		r_de_00_1P			<= 1'b0;
		r_valid_1P			<= 1'b0;
		r_vsync_00_2P		<= 1'b0;
		r_hsync_00_2P		<= 1'b0;
		r_de_00_2P			<= 1'b0;
		r_valid_2P			<= 1'b0;
	end else begin
		r_vsync_00_1P		<= i_vsync;
		r_hsync_00_1P		<= i_hsync;
		r_de_00_1P			<= i_de;
		r_valid_1P			<= i_valid;
		r_vsync_00_2P		<= r_vsync_00_1P;
		r_hsync_00_2P		<= r_hsync_00_1P;
		r_de_00_2P			<= r_de_00_1P;
		r_valid_2P			<= r_valid_1P;
	end
end
wire neg_vs = !i_vsync && r_vsync_00_1P;
wire pos_hs = i_hsync && !r_hsync_00_1P;
always@(posedge i_pclk)
begin
	if (~i_arstn)
		r_y_cnt	<= 11'b0;
	else if (!i_vsync && r_vsync_00_1P)		//Falling edge of VSYNC
		r_y_cnt	<= 11'b0;
	else if (r_de_00_1P && !i_de)			//Falling edge of DE
		r_y_cnt <= r_y_cnt + 1'b1;

end

always@(posedge i_pclk)
begin
	if (~i_arstn)
		r_x_cnt <= 11'b0;
	else if (i_de )
		r_x_cnt	<= r_x_cnt + 1'b1;
	else
		r_x_cnt <= 11'b0;

end

always@(posedge i_pclk)
begin
	if (~i_arstn)
	begin
		r_x_cnt_1P			<= 11'b0;
		r_x_cnt_2P			<= 11'b0;
	end else begin
		r_x_cnt_1P			<= r_x_cnt;
		r_x_cnt_2P          <= r_x_cnt_1P;
	end
end

always@(posedge i_pclk)
begin
	if (~i_arstn) begin
		r_y_cnt_1P			<= 11'b0;
		r_y_cnt_2P			<= 11'b0;
	end else begin
		r_y_cnt_1P			<= r_y_cnt;
		r_y_cnt_2P          <= r_y_cnt_1P;
	end

end

/* 0P 级：捕获 5 路行源 */
always @( posedge i_pclk )
begin
	if (~i_arstn)
	begin
		r_bayer_m2_01_0P_0	<= {P_DEPTH{1'b0}};
		r_bayer_m2_01_0P_1	<= {P_DEPTH{1'b0}};
		r_bayer_m1_01_0P_0	<= {P_DEPTH{1'b0}};
		r_bayer_m1_01_0P_1	<= {P_DEPTH{1'b0}};
		r_bayer_z0_01_0P_0	<= {P_DEPTH{1'b0}};
		r_bayer_z0_01_0P_1	<= {P_DEPTH{1'b0}};
		r_bayer_p1_01_0P_0	<= {P_DEPTH{1'b0}};
		r_bayer_p1_01_0P_1	<= {P_DEPTH{1'b0}};
		r_bayer_p2_01_0P_0	<= {P_DEPTH{1'b0}};
		r_bayer_p2_01_0P_1	<= {P_DEPTH{1'b0}};
	end else begin
		if (i_valid)
		begin
			r_bayer_m2_01_0P_0	<= r_row_m2[P_DEPTH-1:0];
			r_bayer_m2_01_0P_1	<= r_row_m2[PW-1:P_DEPTH];
			r_bayer_m1_01_0P_0	<= r_row_m1[P_DEPTH-1:0];
			r_bayer_m1_01_0P_1	<= r_row_m1[PW-1:P_DEPTH];
			r_bayer_z0_01_0P_0	<= r_row_z0[P_DEPTH-1:0];
			r_bayer_z0_01_0P_1	<= r_row_z0[PW-1:P_DEPTH];
			r_bayer_p1_01_0P_0	<= r_row_p1[P_DEPTH-1:0];
			r_bayer_p1_01_0P_1	<= r_row_p1[PW-1:P_DEPTH];
			r_bayer_p2_01_0P_0	<= r_row_p2[P_DEPTH-1:0];
			r_bayer_p2_01_0P_1	<= r_row_p2[PW-1:P_DEPTH];
		end
	end
end

/* 1P 级 */
always@(posedge i_pclk)
begin
	if (~i_arstn)
	begin
		r_bayer_m2_00_1P_0	<= {P_DEPTH{1'b0}};
		r_bayer_m2_00_1P_1	<= {P_DEPTH{1'b0}};
		r_bayer_m1_00_1P_0	<= {P_DEPTH{1'b0}};
		r_bayer_m1_00_1P_1	<= {P_DEPTH{1'b0}};
		r_bayer_z0_00_1P_0	<= {P_DEPTH{1'b0}};
		r_bayer_z0_00_1P_1	<= {P_DEPTH{1'b0}};
		r_bayer_p1_00_1P_0	<= {P_DEPTH{1'b0}};
		r_bayer_p1_00_1P_1	<= {P_DEPTH{1'b0}};
		r_bayer_p2_00_1P_0	<= {P_DEPTH{1'b0}};
		r_bayer_p2_00_1P_1	<= {P_DEPTH{1'b0}};
	end else begin
		if (r_x_cnt == 11'd0) begin
			r_bayer_m2_00_1P_0	<= {P_DEPTH{1'b0}};
			r_bayer_m2_00_1P_1	<= {P_DEPTH{1'b0}};
			r_bayer_m1_00_1P_0	<= {P_DEPTH{1'b0}};
			r_bayer_m1_00_1P_1	<= {P_DEPTH{1'b0}};
			r_bayer_z0_00_1P_0	<= {P_DEPTH{1'b0}};
			r_bayer_z0_00_1P_1	<= {P_DEPTH{1'b0}};
			r_bayer_p1_00_1P_0	<= {P_DEPTH{1'b0}};
			r_bayer_p1_00_1P_1	<= {P_DEPTH{1'b0}};
			r_bayer_p2_00_1P_0	<= {P_DEPTH{1'b0}};
			r_bayer_p2_00_1P_1	<= {P_DEPTH{1'b0}};
		end else begin
			r_bayer_m2_00_1P_0	<= r_bayer_m2_01_0P_0;
			r_bayer_m2_00_1P_1	<= r_bayer_m2_01_0P_1;
			r_bayer_m1_00_1P_0	<= r_bayer_m1_01_0P_0;
			r_bayer_m1_00_1P_1	<= r_bayer_m1_01_0P_1;
			r_bayer_z0_00_1P_0	<= r_bayer_z0_01_0P_0;
			r_bayer_z0_00_1P_1	<= r_bayer_z0_01_0P_1;
			r_bayer_p1_00_1P_0	<= r_bayer_p1_01_0P_0;
			r_bayer_p1_00_1P_1	<= r_bayer_p1_01_0P_1;
			r_bayer_p2_00_1P_0	<= r_bayer_p2_01_0P_0;
			r_bayer_p2_00_1P_1	<= r_bayer_p2_01_0P_1;
		end
	end
end

/* 2P 级 */
always@(posedge i_pclk)
begin
	if (~i_arstn)
	begin
		r_bayer_m2_11_2P_0	<= {P_DEPTH{1'b0}};
		r_bayer_m2_11_2P_1	<= {P_DEPTH{1'b0}};
		r_bayer_m1_11_2P_0	<= {P_DEPTH{1'b0}};
		r_bayer_m1_11_2P_1	<= {P_DEPTH{1'b0}};
		r_bayer_z0_11_2P_0	<= {P_DEPTH{1'b0}};
		r_bayer_z0_11_2P_1	<= {P_DEPTH{1'b0}};
		r_bayer_p1_11_2P_0	<= {P_DEPTH{1'b0}};
		r_bayer_p1_11_2P_1	<= {P_DEPTH{1'b0}};
		r_bayer_p2_11_2P_0	<= {P_DEPTH{1'b0}};
		r_bayer_p2_11_2P_1	<= {P_DEPTH{1'b0}};
	end
	else
	begin
		if (r_x_cnt == 11'd0)
		begin
			r_bayer_m2_11_2P_0	<= {P_DEPTH{1'b0}};
			r_bayer_m2_11_2P_1	<= {P_DEPTH{1'b0}};
			r_bayer_m1_11_2P_0	<= {P_DEPTH{1'b0}};
			r_bayer_m1_11_2P_1	<= {P_DEPTH{1'b0}};
			r_bayer_z0_11_2P_0	<= {P_DEPTH{1'b0}};
			r_bayer_z0_11_2P_1	<= {P_DEPTH{1'b0}};
			r_bayer_p1_11_2P_0	<= {P_DEPTH{1'b0}};
			r_bayer_p1_11_2P_1	<= {P_DEPTH{1'b0}};
			r_bayer_p2_11_2P_0	<= {P_DEPTH{1'b0}};
			r_bayer_p2_11_2P_1	<= {P_DEPTH{1'b0}};
		end else begin
			r_bayer_m2_11_2P_0	<= r_bayer_m2_00_1P_0;
			r_bayer_m2_11_2P_1	<= r_bayer_m2_00_1P_1;
			r_bayer_m1_11_2P_0	<= r_bayer_m1_00_1P_0;
			r_bayer_m1_11_2P_1	<= r_bayer_m1_00_1P_1;
			r_bayer_z0_11_2P_0	<= r_bayer_z0_00_1P_0;
			r_bayer_z0_11_2P_1	<= r_bayer_z0_00_1P_1;
			r_bayer_p1_11_2P_0	<= r_bayer_p1_00_1P_0;
			r_bayer_p1_11_2P_1	<= r_bayer_p1_00_1P_1;
			r_bayer_p2_11_2P_0	<= r_bayer_p2_00_1P_0;
			r_bayer_p2_11_2P_1	<= r_bayer_p2_00_1P_1;
		end

	end
end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 偶像素 (低字节, x = 2T) 的 13 个抽头
wire	[P_DEPTH-1:0]	w_l_c  = r_bayer_z0_00_1P_0;
wire	[P_DEPTH-1:0]	w_l_l1 = r_bayer_z0_11_2P_1;
wire	[P_DEPTH-1:0]	w_l_r1 = r_bayer_z0_00_1P_1;
wire	[P_DEPTH-1:0]	w_l_l2 = r_bayer_z0_11_2P_0;
wire	[P_DEPTH-1:0]	w_l_r2 = r_bayer_z0_01_0P_0;
wire	[P_DEPTH-1:0]	w_l_u1 = r_bayer_m1_00_1P_0;
wire	[P_DEPTH-1:0]	w_l_d1 = r_bayer_p1_00_1P_0;
wire	[P_DEPTH-1:0]	w_l_u2 = r_bayer_m2_00_1P_0;
wire	[P_DEPTH-1:0]	w_l_d2 = r_bayer_p2_00_1P_0;
wire	[P_DEPTH-1:0]	w_l_ul = r_bayer_m1_11_2P_1;
wire	[P_DEPTH-1:0]	w_l_ur = r_bayer_m1_00_1P_1;
wire	[P_DEPTH-1:0]	w_l_dl = r_bayer_p1_11_2P_1;
wire	[P_DEPTH-1:0]	w_l_dr = r_bayer_p1_00_1P_1;

wire	signed	[CAL_W-1:0]	w_l_s1 = w_l_l2 + w_l_r2 + w_l_u2 + w_l_d2;
wire	signed	[CAL_W-1:0]	w_l_s2 = w_l_l1 + w_l_r1 + w_l_u1 + w_l_d1;
wire	signed	[CAL_W-1:0]	w_l_s3 = w_l_ul + w_l_ur + w_l_dl + w_l_dr;
wire	signed	[CAL_W-1:0]	w_l_s4 = w_l_l2 + w_l_r2;
wire	signed	[CAL_W-1:0]	w_l_s5 = w_l_u2 + w_l_d2;
wire	signed	[CAL_W-1:0]	w_l_s6 = w_l_l1 + w_l_r1;
wire	signed	[CAL_W-1:0]	w_l_s7 = w_l_u1 + w_l_d1;
wire	signed	[CAL_W-1:0]	w_l_cs = {{(CAL_W-P_DEPTH){1'b0}}, w_l_c};

wire	signed	[CAL_W-1:0]	w_l_redg_r = ((w_l_cs <<< 3) - (w_l_s1 <<< 1) + (w_l_s2 <<< 2)) >>> 4;
wire	signed	[CAL_W-1:0]	w_l_redb_r = ((w_l_cs <<< 3) + (w_l_cs <<< 2) - w_l_s1 - (w_l_s1 <<< 1) + (w_l_s3 <<< 2)) >>> 4;
wire	signed	[CAL_W-1:0]	w_l_g2r_r  = ((w_l_cs <<< 3) + (w_l_cs <<< 1) - (w_l_s3 <<< 1) - (w_l_s4 <<< 1) + w_l_s5 + (w_l_s6 <<< 3)) >>> 4;
wire	signed	[CAL_W-1:0]	w_l_g2b_r  = ((w_l_cs <<< 3) + (w_l_cs <<< 1) - (w_l_s3 <<< 1) + w_l_s4 - (w_l_s5 <<< 1) + (w_l_s7 <<< 3)) >>> 4;

wire	[P_DEPTH-1:0]	w_l_redg = w_l_redg_r[CAL_W-1] ? {P_DEPTH{1'b0}} :
								  (|w_l_redg_r[CAL_W-1:P_DEPTH]) ? {P_DEPTH{1'b1}} : w_l_redg_r[P_DEPTH-1:0];
wire	[P_DEPTH-1:0]	w_l_redb = w_l_redb_r[CAL_W-1] ? {P_DEPTH{1'b0}} :
								  (|w_l_redb_r[CAL_W-1:P_DEPTH]) ? {P_DEPTH{1'b1}} : w_l_redb_r[P_DEPTH-1:0];
wire	[P_DEPTH-1:0]	w_l_g2r  = w_l_g2r_r[CAL_W-1] ? {P_DEPTH{1'b0}} :
								  (|w_l_g2r_r[CAL_W-1:P_DEPTH]) ? {P_DEPTH{1'b1}} : w_l_g2r_r[P_DEPTH-1:0];
wire	[P_DEPTH-1:0]	w_l_g2b  = w_l_g2b_r[CAL_W-1] ? {P_DEPTH{1'b0}} :
								  (|w_l_g2b_r[CAL_W-1:P_DEPTH]) ? {P_DEPTH{1'b1}} : w_l_g2b_r[P_DEPTH-1:0];

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 奇像素 (高字节, x = 2T+1) 的 13 个抽头
wire	[P_DEPTH-1:0]	w_h_c  = r_bayer_z0_00_1P_1;
wire	[P_DEPTH-1:0]	w_h_l1 = r_bayer_z0_00_1P_0;
wire	[P_DEPTH-1:0]	w_h_r1 = r_bayer_z0_01_0P_0;
wire	[P_DEPTH-1:0]	w_h_l2 = r_bayer_z0_11_2P_1;
wire	[P_DEPTH-1:0]	w_h_r2 = r_bayer_z0_01_0P_1;
wire	[P_DEPTH-1:0]	w_h_u1 = r_bayer_m1_00_1P_1;
wire	[P_DEPTH-1:0]	w_h_d1 = r_bayer_p1_00_1P_1;
wire	[P_DEPTH-1:0]	w_h_u2 = r_bayer_m2_00_1P_1;
wire	[P_DEPTH-1:0]	w_h_d2 = r_bayer_p2_00_1P_1;
wire	[P_DEPTH-1:0]	w_h_ul = r_bayer_m1_00_1P_0;
wire	[P_DEPTH-1:0]	w_h_ur = r_bayer_m1_01_0P_0;
wire	[P_DEPTH-1:0]	w_h_dl = r_bayer_p1_00_1P_0;
wire	[P_DEPTH-1:0]	w_h_dr = r_bayer_p1_01_0P_0;

wire	signed	[CAL_W-1:0]	w_h_s1 = w_h_l2 + w_h_r2 + w_h_u2 + w_h_d2;
wire	signed	[CAL_W-1:0]	w_h_s2 = w_h_l1 + w_h_r1 + w_h_u1 + w_h_d1;
wire	signed	[CAL_W-1:0]	w_h_s3 = w_h_ul + w_h_ur + w_h_dl + w_h_dr;
wire	signed	[CAL_W-1:0]	w_h_s4 = w_h_l2 + w_h_r2;
wire	signed	[CAL_W-1:0]	w_h_s5 = w_h_u2 + w_h_d2;
wire	signed	[CAL_W-1:0]	w_h_s6 = w_h_l1 + w_h_r1;
wire	signed	[CAL_W-1:0]	w_h_s7 = w_h_u1 + w_h_d1;
wire	signed	[CAL_W-1:0]	w_h_cs = {{(CAL_W-P_DEPTH){1'b0}}, w_h_c};

wire	signed	[CAL_W-1:0]	w_h_redg_r = ((w_h_cs <<< 3) - (w_h_s1 <<< 1) + (w_h_s2 <<< 2)) >>> 4;
wire	signed	[CAL_W-1:0]	w_h_redb_r = ((w_h_cs <<< 3) + (w_h_cs <<< 2) - w_h_s1 - (w_h_s1 <<< 1) + (w_h_s3 <<< 2)) >>> 4;
wire	signed	[CAL_W-1:0]	w_h_g2r_r  = ((w_h_cs <<< 3) + (w_h_cs <<< 1) - (w_h_s3 <<< 1) - (w_h_s4 <<< 1) + w_h_s5 + (w_h_s6 <<< 3)) >>> 4;
wire	signed	[CAL_W-1:0]	w_h_g2b_r  = ((w_h_cs <<< 3) + (w_h_cs <<< 1) - (w_h_s3 <<< 1) + w_h_s4 - (w_h_s5 <<< 1) + (w_h_s7 <<< 3)) >>> 4;

wire	[P_DEPTH-1:0]	w_h_redg = w_h_redg_r[CAL_W-1] ? {P_DEPTH{1'b0}} :
								  (|w_h_redg_r[CAL_W-1:P_DEPTH]) ? {P_DEPTH{1'b1}} : w_h_redg_r[P_DEPTH-1:0];
wire	[P_DEPTH-1:0]	w_h_redb = w_h_redb_r[CAL_W-1] ? {P_DEPTH{1'b0}} :
								  (|w_h_redb_r[CAL_W-1:P_DEPTH]) ? {P_DEPTH{1'b1}} : w_h_redb_r[P_DEPTH-1:0];
wire	[P_DEPTH-1:0]	w_h_g2r  = w_h_g2r_r[CAL_W-1] ? {P_DEPTH{1'b0}} :
								  (|w_h_g2r_r[CAL_W-1:P_DEPTH]) ? {P_DEPTH{1'b1}} : w_h_g2r_r[P_DEPTH-1:0];
wire	[P_DEPTH-1:0]	w_h_g2b  = w_h_g2b_r[CAL_W-1] ? {P_DEPTH{1'b0}} :
								  (|w_h_g2b_r[CAL_W-1:P_DEPTH]) ? {P_DEPTH{1'b1}} : w_h_g2b_r[P_DEPTH-1:0];

always@(posedge i_pclk)
begin
	if (~i_arstn) begin
		r_r_00_00_1P		<= {PW{1'b0}};
		r_g_00_00_1P		<= {PW{1'b0}};
		r_b_00_00_1P		<= {PW{1'b0}};
	end else begin

		if (!r_de_00_1P) begin
			r_r_00_00_1P	<= {PW{1'b0}};
			r_g_00_00_1P	<= {PW{1'b0}};
			r_b_00_00_1P	<= {PW{1'b0}};

		end else if (r_y_cnt[0]) begin	//y 为奇数 -> G B G B
			/* Gb B Gb G */
			if (r_valid_1P)
			begin
				//偶列 x=2T   : green1
				r_r_00_00_1P[P_DEPTH-1:0]	<= w_l_g2b;
				r_g_00_00_1P[P_DEPTH-1:0]	<= w_l_c;
				r_b_00_00_1P[P_DEPTH-1:0]	<= w_l_g2r;

				//奇列 x=2T+1 : blue
				r_r_00_00_1P[PW-1:P_DEPTH]	<= w_h_redb;
				r_g_00_00_1P[PW-1:P_DEPTH]	<= w_h_redg;
				r_b_00_00_1P[PW-1:P_DEPTH]	<= w_h_c;
			end
		end
		else
		begin
			/* R Gr RG R */
			if (r_valid_1P)
			begin
				//偶列 x=2T   : red
				r_r_00_00_1P[P_DEPTH-1:0]	<= w_l_c;
				r_g_00_00_1P[P_DEPTH-1:0]	<= w_l_redg;
				r_b_00_00_1P[P_DEPTH-1:0]	<= w_l_redb;

				//奇列 x=2T+1 : green2
				r_r_00_00_1P[PW-1:P_DEPTH]	<= w_h_g2r;
				r_g_00_00_1P[PW-1:P_DEPTH]	<= w_h_c;
				r_b_00_00_1P[PW-1:P_DEPTH]	<= w_h_g2b;
			end
		end
	end
end



assign	o_vsync	= r_vsync_00_2P;
assign	o_hsync	= r_hsync_00_2P;
assign	o_de	= r_de_00_2P;
assign	o_valid	= r_valid_2P;
assign	o_x_cnt	= r_x_cnt_2P;
assign	o_y_cnt	= r_y_cnt_2P;
assign	o_r		= r_r_00_00_1P;
assign	o_g		= r_g_00_00_1P;
assign	o_b		= r_b_00_00_1P;

endmodule

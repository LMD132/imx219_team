// Serial, bounded-work classifier for the three supported geometric shapes.
// Summary words are supplied by shp_summary: 32 direction-ordered extrema,
// followed by one left/right span for each four-line image strip.  Rejection
// is conservative: a missing word or ambiguous contour never becomes a class.
module shp_geometry(
 input wire clk,rst_n,start, input wire [2:0] slot,
 input wire [11:0] bbox_x0,bbox_x1,
 input wire [12:0] bbox_y0,bbox_y1,input wire bad,
 output wire start_ready,output reg done,valid,output reg [2:0] cls,
 output wire rd_req,output wire [2:0] rd_slot,
 output wire [7:0] rd_index,input wire rd_valid,input wire [25:0] rd_data
);
 localparam IDLE=0,READ_REQ=1,READ_WAIT=2,PREP=3,
  PROFILE_REQ=4,PROFILE_WAIT=5,PROFILE_EDGE=6,
  SIM_INIT=7,SIM_SCAN=8,SIM_DECIDE=9,
  LINE_CHECK=10,SIDE_CHECK=11,CURVE_INIT=12,CURVE_POINT=13,
  CURVE_REQ=14,CURVE_WAIT=15,CURVE_Y=16,CURVE_EDGE=17,
  ACCEPT=18,REJECT=19,SHORT_SCAN=20,
  CURVE_MUL=21,CURVE_COMPARE=22,CURVE_EDGE_CHECK=23,
  SIM_PRODUCTS=24,SIM_COMPARE=25,SIDE_CAPTURE=26,SIDE_PRODUCTS=27,
  LINE_CAPTURE=28,LINE_PRODUCTS=29,CURVE_TEST=30,CURVE_DECIDE=31;
 reg [4:0] state;
 reg [2:0] held_slot;
 reg [11:0] x0,x1;
 reg [12:0] y0,y1;
 reg [7:0] ridx;
 reg [5:0] hn,pn,idx,best_i;
 reg [11:0] hx[0:31],px[0:31];
 reg [12:0] hy[0:31],py[0:31];
 reg [7:0] strip;
 reg [11:0] left,right;
 reg [12:0] low,high,scan_y;
 reg [11:0] width,height,scale,tol,epsilon,line_tol;
 reg edge_high,profile_seen,line_hit,curve_right;
 reg [43:0] best_num;
 reg [21:0] best_den;
 reg [43:0] scan_num;
 reg [21:0] scan_den;
 reg [65:0] scan_lhs,scan_rhs;
 reg [20:0] min_ys,max_ys;
 reg [40:0] target;
 reg [20:0] w2,h2;
 reg [22:0] cx2,cy2;
 reg [42:0] radial_reg,strip_min_reg,strip_max_reg;
 reg [42:0] radial_diff_reg;
 reg [49:0] curve_radial_lhs;
 reg [46:0] curve_radial_limit;
 reg [2:0] accepted_cls;
 reg [2:0] short_count;
 reg [1:0] short_idx;
 reg [21:0] side_len,side_nlen,side_olen;
 reg signed [29:0] side_dot,side_parallel;
 reg [49:0] side_perpendicular_lhs,side_perpendicular_rhs;
 reg [49:0] side_parallel_lhs,side_parallel_rhs;
 reg signed [29:0] line_residual_reg;
 reg [21:0] line_den_reg;
 reg [43:0] line_residual2_reg,line_limit_reg;
 integer j;

 assign start_ready=(state==IDLE);
 assign rd_req=(state==READ_REQ||state==PROFILE_REQ||state==CURVE_REQ);
 assign rd_slot=held_slot;
 assign rd_index=(state==READ_REQ)?ridx:8'd32+strip;

 wire [5:0] hp=(idx==0)?hn-1'b1:idx-1'b1;
 wire [5:0] hnxt=(idx==hn-1'b1)?0:idx+1'b1;
 wire [5:0] pp=(idx==0)?pn-1'b1:idx-1'b1;
 wire [5:0] pnxt=(idx==pn-1'b1)?0:idx+1'b1;
 wire [5:0] popp=(idx+2>=pn)?idx+2-pn:idx+2;
 // The next edge begins at pnxt and ends two vertices ahead.  Using
 // idx+1 here makes that edge zero-length and disables the corner test.
 wire [5:0] pnext2=popp;

 // Signed 14-bit deltas cover every valid 1280x720 coordinate difference.
 wire signed [13:0] adx=$signed({2'b0,px[pnxt]})-$signed({2'b0,px[pp]});
 wire signed [13:0] ady=$signed({1'b0,py[pnxt]})-$signed({1'b0,py[pp]});
 wire signed [13:0] bdx=$signed({2'b0,px[idx]})-$signed({2'b0,px[pp]});
 wire signed [13:0] bdy=$signed({1'b0,py[idx]})-$signed({1'b0,py[pp]});
 wire signed [29:0] cross_sim=adx*bdy-ady*bdx;
 wire [43:0] sim_num=$signed(cross_sim)*$signed(cross_sim);
 wire [21:0] sim_den=adx*adx+ady*ady;
 wire [65:0] sim_lhs=scan_num*best_den;
 wire [65:0] sim_rhs=best_num*scan_den;

 wire signed [13:0] edge_dx=$signed({2'b0,hx[hnxt]})-$signed({2'b0,hx[idx]});
 wire signed [13:0] edge_dy=$signed({1'b0,hy[hnxt]})-$signed({1'b0,hy[idx]});
 wire [12:0] target_y=edge_high?high:low;
 wire signed [30:0] edge_n=($signed({1'b0,target_y})-$signed({1'b0,hy[idx]}))*edge_dx;
 wire signed [30:0] edge_l=($signed({2'b0,left})-$signed({2'b0,tol})-$signed({2'b0,hx[idx]}))*edge_dy;
 wire signed [30:0] edge_r=($signed({2'b0,right})+$signed({2'b0,tol})+1-$signed({2'b0,hx[idx]}))*edge_dy;
 wire vertex_in=hy[idx]>=low&&hy[idx]<=high;
 wire crossing=edge_dy!=0&&target_y>=((hy[idx]<hy[hnxt])?hy[idx]:hy[hnxt])&&
                 target_y<=((hy[idx]>hy[hnxt])?hy[idx]:hy[hnxt]);
 wire vertex_out=vertex_in&&
  ($signed({1'b0,hx[idx]})<$signed({1'b0,left})-$signed({1'b0,tol})||
   $signed({1'b0,hx[idx]})>$signed({1'b0,right})+$signed({1'b0,tol}));
 wire crossing_out=crossing&&((edge_dy>0)?(edge_n<edge_l||edge_n>=edge_r):
                                            (edge_n>edge_l||edge_n<=edge_r));

 wire signed [13:0] ldx=$signed({2'b0,px[pnxt]})-$signed({2'b0,px[idx]});
 wire signed [13:0] ldy=$signed({1'b0,py[pnxt]})-$signed({1'b0,py[idx]});
 wire signed [13:0] rdx=$signed({2'b0,hx[ridx[5:0]]})-$signed({2'b0,px[idx]});
 wire signed [13:0] rdy=$signed({1'b0,hy[ridx[5:0]]})-$signed({1'b0,py[idx]});
 wire signed [29:0] residual=ldx*rdy-ldy*rdx;
 wire [43:0] residual2=$signed(line_residual_reg)*$signed(line_residual_reg);
 wire [21:0] line_den=ldx*ldx+ldy*ldy;
 wire [43:0] line_limit=line_tol*line_tol*line_den_reg;

 wire signed [13:0] ndx=$signed({2'b0,px[pnext2]})-$signed({2'b0,px[pnxt]});
 wire signed [13:0] ndy=$signed({1'b0,py[pnext2]})-$signed({1'b0,py[pnxt]});
 wire signed [13:0] odx=$signed({2'b0,px[(idx+3>=pn)?idx+3-pn:idx+3]})-$signed({2'b0,px[popp]});
 wire signed [13:0] ody=$signed({1'b0,py[(idx+3>=pn)?idx+3-pn:idx+3]})-$signed({1'b0,py[popp]});
 wire [21:0] len=line_den,nlen=ndx*ndx+ndy*ndy,olen=odx*odx+ody*ody;
 wire signed [29:0] dot=ldx*ndx+ldy*ndy;
 wire signed [29:0] parallel=ldx*ody-ldy*odx;
 wire [49:0] perpendicular_lhs=($signed(side_dot)*$signed(side_dot))*25;
 wire [49:0] perpendicular_rhs=side_len*side_nlen;
 wire [49:0] parallel_lhs=($signed(side_parallel)*$signed(side_parallel))*25;
 wire [49:0] parallel_rhs=side_len*side_olen;
 // A stroked raster triangle can have a roughly 9-pixel flat apex at
 // 160-pixel scale; merge exactly one side shorter than 12 pixels.
 wire [1:0] ci=(len<144)?idx[1:0]:short_idx;
 wire [1:0] ci1=ci+2'd1,ci2=ci+2'd2,ci3=ci+2'd3;

 wire signed [14:0] rx=$signed({2'b0,hx[idx],1'b0})-$signed({2'b0,x0})-$signed({2'b0,x1});
 wire signed [14:0] ry=$signed({1'b0,hy[idx],1'b0})-$signed({2'b0,y0})-$signed({2'b0,y1});
 wire [22:0] rx2=rx*rx,ry2=ry*ry;
 wire [42:0] radial=cx2*h2+cy2*w2;
 wire [42:0] radial_diff=(radial_reg>target)?radial_reg-target:target-radial_reg;
 wire [46:0] radial_limit=target*14;
 wire [49:0] radial_lhs=radial_diff_reg*7'd100;
 wire signed [14:0] sy=$signed({1'b0,scan_y,1'b0})-$signed({2'b0,y0})-$signed({2'b0,y1});
 wire [20:0] sy2=sy*sy;
 wire signed [14:0] sx=$signed({2'b0,(curve_right?right:left),1'b0})-$signed({2'b0,x0})-$signed({2'b0,x1});
 wire [22:0] sx2=sx*sx;
 wire [42:0] strip_base=sx2*h2;
 wire [42:0] strip_min=strip_base+min_ys*w2;
 wire [42:0] strip_max=strip_base+max_ys*w2;
 // Integer residual > floor(target*14/100) is equivalent to
 // residual*100 > target*14.  The latter avoids a divider entirely.
 wire [49:0] strip_far_lhs=(strip_min_reg-target)*7'd100;
 wire [49:0] strip_near_lhs=(target-strip_max_reg)*7'd100;
 wire strip_too_far=(strip_min_reg>target)&&(strip_far_lhs>radial_limit);
 wire strip_too_near=(strip_max_reg<target)&&(strip_near_lhs>radial_limit);

 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;done<=0;valid<=0;cls<=0;held_slot<=0;
   x0<=0;x1<=0;y0<=0;y1<=0;ridx<=0;hn<=0;pn<=0;idx<=0;best_i<=0;
   strip<=0;left<=0;right<=0;low<=0;high<=0;scan_y<=0;
   width<=0;height<=0;scale<=0;tol<=0;epsilon<=0;line_tol<=0;
   edge_high<=0;profile_seen<=0;line_hit<=0;curve_right<=0;
   best_num<=0;best_den<=0;min_ys<=0;max_ys<=0;target<=0;w2<=0;h2<=0;
   scan_num<=0;scan_den<=0;scan_lhs<=0;scan_rhs<=0;
   cx2<=0;cy2<=0;radial_reg<=0;strip_min_reg<=0;strip_max_reg<=0;
   radial_diff_reg<=0;curve_radial_lhs<=0;curve_radial_limit<=0;
   accepted_cls<=0;short_count<=0;short_idx<=0;
   side_len<=0;side_nlen<=0;side_olen<=0;side_dot<=0;side_parallel<=0;
   side_perpendicular_lhs<=0;side_perpendicular_rhs<=0;
   side_parallel_lhs<=0;side_parallel_rhs<=0;
   line_residual_reg<=0;line_den_reg<=0;
   line_residual2_reg<=0;line_limit_reg<=0;
  end else begin
   case(state)
    IDLE:if(start)begin
     done<=0;valid<=0;cls<=0;held_slot<=slot;
     x0<=bbox_x0;x1<=bbox_x1;y0<=bbox_y0;y1<=bbox_y1;
     ridx<=0;hn<=0;
     if(bad||bbox_x1<=bbox_x0||bbox_y1<=bbox_y0||bbox_x1>=1280||bbox_y1>=720)state<=REJECT;
     else state<=READ_REQ;
    end
    READ_REQ:state<=READ_WAIT;
    READ_WAIT:if(rd_valid)begin
     if(rd_data[25]&&(rd_data[11:0]<x0||rd_data[11:0]>x1||
                      rd_data[24:12]<y0||rd_data[24:12]>y1))state<=REJECT;
     else begin
      if(rd_data[25]&&
        (hn==0||hx[hn-1'b1]!=rd_data[11:0]||hy[hn-1'b1]!=rd_data[24:12]))begin
       hx[hn]<=rd_data[11:0];hy[hn]<=rd_data[24:12];hn<=hn+1'b1;
      end
      if(ridx==31)state<=PREP;
      else begin ridx<=ridx+1'b1;state<=READ_REQ;end
     end
    end
    PREP:begin
     // The last cyclic extremum may repeat the first one.
     if(hn>1&&hx[hn-1'b1]==hx[0]&&hy[hn-1'b1]==hy[0])hn<=hn-1'b1;
     width<=x1-x0;height<=y1-y0;
     scale<=((x1-x0)>(y1-y0))?(x1-x0):(y1-y0);
     tol<=2+((((x1-x0)>(y1-y0))?(x1-x0):(y1-y0))*2)/100;
     epsilon<=((((x1-x0)>(y1-y0))?(x1-x0):(y1-y0))*2/100<1)?1:
      (((x1-x0)>(y1-y0))?(x1-x0):(y1-y0))*2/100;
     line_tol<=((((x1-x0)>(y1-y0))?(x1-x0):(y1-y0))*3/100<1)?1:
      (((x1-x0)>(y1-y0))?(x1-x0):(y1-y0))*3/100;
     strip<=y0>>2;
     if(hn<3||(((x1-x0)<(y1-y0))?(x1-x0):(y1-y0))*100<
        (((x1-x0)>(y1-y0))?(x1-x0):(y1-y0))*20)state<=REJECT;
     else state<=PROFILE_REQ;
    end
    PROFILE_REQ:state<=PROFILE_WAIT;
    PROFILE_WAIT:if(rd_valid)begin
     if(!rd_data[24])state<=REJECT;
     else begin
      left<=rd_data[23:12];right<=rd_data[11:0];
      low<=((strip<<2)<y0)?y0:(strip<<2);
      high<=((strip<<2)+3>y1)?y1:(strip<<2)+3;
      idx<=0;edge_high<=0;profile_seen<=0;state<=PROFILE_EDGE;
     end
    end
    PROFILE_EDGE:begin
     if(vertex_out||crossing_out)state<=REJECT;
     else begin
      if(vertex_in||crossing)profile_seen<=1;
      if(!edge_high)edge_high<=1;
      else if(idx==hn-1'b1)begin
       if(!profile_seen&&!vertex_in&&!crossing)state<=REJECT;
       else if(strip==(y1>>2))state<=SIM_INIT;
       else begin strip<=strip+1'b1;state<=PROFILE_REQ;end
      end else begin idx<=idx+1'b1;edge_high<=0;end
     end
    end
    SIM_INIT:begin
     pn<=hn;idx<=0;best_i<=0;best_num<={44{1'b1}};best_den<=1;
     for(j=0;j<32;j=j+1)begin px[j]<=hx[j];py[j]<=hy[j];end
     state<=SIM_SCAN;
    end
    SIM_SCAN:begin
     scan_num<=sim_num;scan_den<=sim_den;state<=SIM_PRODUCTS;
    end
    SIM_PRODUCTS:begin
     scan_lhs<=sim_lhs;scan_rhs<=sim_rhs;state<=SIM_COMPARE;
    end
    SIM_COMPARE:begin
     if(scan_den!=0&&(best_num=={44{1'b1}}||scan_lhs<scan_rhs))begin
      best_num<=scan_num;best_den<=scan_den;best_i<=idx;
     end
     if(idx==pn-1'b1)state<=SIM_DECIDE;
     else begin idx<=idx+1'b1;state<=SIM_SCAN;end
    end
    SIM_DECIDE:begin
     if(pn>3&&best_num<=epsilon*epsilon*best_den)begin
      for(j=0;j<31;j=j+1)if(j>=best_i)begin px[j]<=px[j+1];py[j]<=py[j+1];end
      pn<=pn-1'b1;idx<=0;best_i<=0;best_num<={44{1'b1}};best_den<=1;
      state<=SIM_SCAN;
     end else if(pn==4)begin idx<=0;short_count<=0;short_idx<=0;state<=SHORT_SCAN;end
     else if(pn==3)begin idx<=0;ridx<=0;line_hit<=0;state<=LINE_CAPTURE;end
     else state<=CURVE_INIT;
    end
    SHORT_SCAN:begin
     if(len<144)begin short_count<=short_count+1'b1;short_idx<=idx[1:0];end
     if(idx==3)begin
      if(short_count+(len<144)==1)begin
       px[0]<=({1'b0,px[ci]}+{1'b0,px[ci1]})>>1;
       py[0]<=({1'b0,py[ci]}+{1'b0,py[ci1]})>>1;
       px[1]<=px[ci2];py[1]<=py[ci2];
       px[2]<=px[ci3];py[2]<=py[ci3];
       pn<=3;
      end
      idx<=0;ridx<=0;line_hit<=0;state<=LINE_CAPTURE;
     end else idx<=idx+1'b1;
    end
    LINE_CAPTURE:begin
     line_residual_reg<=residual;line_den_reg<=line_den;
     state<=LINE_PRODUCTS;
    end
    LINE_PRODUCTS:begin
     line_residual2_reg<=residual2;line_limit_reg<=line_limit;
     state<=LINE_CHECK;
    end
    LINE_CHECK:begin
     if(line_residual2_reg<=line_limit_reg)line_hit<=1;
     if(idx==pn-1'b1||line_residual2_reg<=line_limit_reg)begin
      if(!line_hit&&line_residual2_reg>line_limit_reg)state<=REJECT;
      else if(ridx==hn-1'b1)begin idx<=0;state<=SIDE_CAPTURE;end
      else begin ridx<=ridx+1'b1;idx<=0;line_hit<=0;state<=LINE_CAPTURE;end
     end else begin idx<=idx+1'b1;state<=LINE_CAPTURE;end
    end
    SIDE_CAPTURE:begin
     side_len<=len;side_nlen<=nlen;side_olen<=olen;
     side_dot<=dot;side_parallel<=parallel;
     state<=SIDE_PRODUCTS;
    end
    SIDE_PRODUCTS:begin
     side_perpendicular_lhs<=perpendicular_lhs;
     side_perpendicular_rhs<=perpendicular_rhs;
     side_parallel_lhs<=parallel_lhs;
     side_parallel_rhs<=parallel_rhs;
     state<=SIDE_CHECK;
    end
    SIDE_CHECK:begin
     if(side_len<144||
       (pn==4&&(side_perpendicular_lhs>side_perpendicular_rhs||
                 side_parallel_lhs>side_parallel_rhs)))state<=REJECT;
     else if(idx==pn-1'b1)begin accepted_cls<=(pn==3)?3:2;state<=ACCEPT;end
     else begin idx<=idx+1'b1;state<=SIDE_CAPTURE;end
    end
    CURVE_INIT:begin
     if(scale*100>((width<height)?width:height)*135)state<=REJECT;
     else begin
      w2<=width*width;h2<=height*height;
      target<=width*width*height*height;
      idx<=0;state<=CURVE_POINT;
     end
    end
    CURVE_POINT:begin
     cx2<=rx2;cy2<=ry2;state<=CURVE_MUL;
    end
    CURVE_MUL:begin
     radial_reg<=radial;state<=CURVE_COMPARE;
    end
    CURVE_COMPARE:begin
     radial_diff_reg<=radial_diff;state<=CURVE_TEST;
    end
    CURVE_TEST:begin
     curve_radial_lhs<=radial_lhs;
     curve_radial_limit<=radial_limit;
     state<=CURVE_DECIDE;
    end
    CURVE_DECIDE:begin
     if(curve_radial_lhs>curve_radial_limit)state<=REJECT;
     else if(idx==hn-1'b1)begin strip<=y0>>2;state<=CURVE_REQ;end
     else begin idx<=idx+1'b1;state<=CURVE_POINT;end
    end
    CURVE_REQ:state<=CURVE_WAIT;
    CURVE_WAIT:if(rd_valid)begin
     if(!rd_data[24])state<=REJECT;
     else begin
      left<=rd_data[23:12];right<=rd_data[11:0];
      low<=((strip<<2)<y0)?y0:(strip<<2);
      high<=((strip<<2)+3>y1)?y1:(strip<<2)+3;
      scan_y<=((strip<<2)<y0)?y0:(strip<<2);
      min_ys<={21{1'b1}};max_ys<=0;curve_right<=0;state<=CURVE_Y;
     end
    end
    CURVE_Y:begin
     if(sy2<min_ys)min_ys<=sy2;
     if(sy2>max_ys)max_ys<=sy2;
     if(scan_y==high)state<=CURVE_EDGE;
     else scan_y<=scan_y+1'b1;
    end
    CURVE_EDGE:begin
     strip_min_reg<=strip_min;strip_max_reg<=strip_max;state<=CURVE_EDGE_CHECK;
    end
    CURVE_EDGE_CHECK:begin
     if(strip_too_far||strip_too_near)state<=REJECT;
     else if(!curve_right)begin curve_right<=1;state<=CURVE_EDGE;end
     else if(strip==(y1>>2))begin accepted_cls<=1;state<=ACCEPT;end
     else begin strip<=strip+1'b1;state<=CURVE_REQ;end
    end
    ACCEPT:begin done<=1;valid<=1;cls<=accepted_cls;state<=IDLE;end
    REJECT:begin done<=1;valid<=0;cls<=0;state<=IDLE;end
    default:state<=IDLE;
   endcase
  end
 end
endmodule

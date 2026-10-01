`timescale 1ns/1ps
// Characterize the existing eight-slot limit with full-size 720p frames.
// Clean and six-noise cases must recognize exactly. 2026-10-02 fault grading:
// with eight simultaneous junk contours the target's first spans can lose the
// slot race, but the frame must still commit (fault=0), keep the R1 source
// record and report the target -- at most with its top edge clipped by the
// spans that lost the race. A blank frame is no longer accepted for this
// limit.
module tb_shp_clutter;
 reg clk=0,rst_n=0,in_vs=0,in_de=0;
 reg [11:0] in_x=0;reg [12:0] in_y=0;reg [7:0] in_d=0;
 always #5 clk=~clk;
 wire [71:0] bx0,bx1;wire [77:0] by0,by1;
 wire [17:0] bcls;wire [5:0] bval;wire [9:0] cnt;wire [15:0] ovf;
 wire fault,frame_valid;
 wire [3:0] reason;
 wire [31:0] slot_total,fifo_total;
 shp_detect dut(.clk(clk),.rst_n(rst_n),.cfg_en(1'b1),
  .cfg_min_size(8'd24),.cfg_max_boxes(3'd6),.cfg_fill_th(10'd875),
  .cfg_max_area(7'd50),.in_vs(in_vs),.in_de(in_de),.in_x(in_x),.in_y(in_y),.in_d(in_d),
  .o_bx0(bx0),.o_bx1(bx1),.o_by0(by0),.o_by1(by1),
  .o_bcls(bcls),.o_bval(bval),.o_cnt(cnt),.o_ovf(ovf),
  .o_last_fault(fault),.o_last_reason(reason),.o_frame_valid(frame_valid),
  .o_slot_drop_total(slot_total),.o_fifo_full_total(fifo_total));
 integer x,y,i,dx,dy,n,scene=2,shape_class=2,no_clutter=0,noise_count;
 integer clipped_ok;
 integer drops=0,slots=0,late=0,bad=0,max_queue=0,spans=0;
 reg edge_pixel;
 always @(posedge clk)if(rst_n)begin
  if(dut.span_end)spans=spans+1;
  if(dut.span_end&&!dut.push_ok)drops=drops+1;
  if(dut.no_slot_drop)slots=slots+1;
  if(dut.vs_edge&&dut.pending_edges!=0)late=late+1;
  if(dut.malformed_retire)bad=bad+1;
  if(dut.f_cnt>max_queue)max_queue=dut.f_cnt;
 end
 initial begin
  if(!$value$plusargs("SCENE=%d",scene))scene=2;
  if($test$plusargs("NO_CLUTTER"))no_clutter=1;
  noise_count=(scene>=2)?8:6;
  if($value$plusargs("NOISE=%d",noise_count))begin end
  repeat(5)@(negedge clk);rst_n=1;
  if(scene==3)shape_class=3;
  for(y=0;y<750;y=y+1)begin
   for(x=0;x<1650;x=x+1)begin
    if(scene==3)begin
     edge_pixel=(y>=200&&y<360&&
                (x==600-(y-200)/2||x==600+(y-200)/2)) ||
                (y==360&&x>=520&&x<=680);
    end else begin
     edge_pixel=(x>=520&&x<=680&&y>=200&&y<=360&&
                 (x==520||x==680||y==200||y==360));
    end
    // Six or eight separate 6x6 contours per band. They are too small to be
    // reported, separated from each other and from the real rectangle.
    if(scene!=0 && !no_clutter && y>=200&&y<360)begin
     dy=(y-200)%16;
     for(i=0;i<noise_count;i=i+1)begin
      dx=x-(60+i*64);
      if(dx>=0&&dx<=5&&dy<=5&&
         (dx==0||dx==5||dy==0||dy==5))edge_pixel=1;
     end
    end
    @(negedge clk);in_x=x;in_y=y;in_de=(x<1280&&y<720);
    in_d=edge_pixel?8'hff:0;
   end
  end
  @(negedge clk);in_de=0;in_d=0;in_vs=1;
  @(negedge clk);in_vs=0;
  repeat(100000)@(negedge clk);
  n=0;
  clipped_ok=(scene>=2 && !no_clutter && noise_count>=8);
  $display("CLUTTER_BOXES cnt=%0d fault=%0d reason=%h ovf=%0d slots=%0d drops=%0d max_queue=%0d",
           cnt,fault,reason,ovf,slots,drops,max_queue);
  for(i=0;i<6;i=i+1)if(bval[i])
   $display("CLUTTER_BOX slot=%0d cls=%0d bx=%0d..%0d by=%0d..%0d",
            i,bcls[i*3+:3],bx0[i*12+:12],bx1[i*12+:12],by0[i*13+:13],by1[i*13+:13]);
  for(i=0;i<6;i=i+1)if(bval[i])begin
   n=n+1;
   if(bcls[i*3+:3]!=shape_class || bx0[i*12+:12]!=520 || bx1[i*12+:12]!=680 ||
      by1[i*13+:13]!=360 ||
      (clipped_ok ? (by0[i*13+:13]<200 || by0[i*13+:13]>=360)
                  : (by0[i*13+:13]!=200)))
    $fatal(1,"unexpected detected object slot %0d cls=%0d bx=%0d..%0d by=%0d..%0d",
           i,bcls[i*3+:3],bx0[i*12+:12],bx1[i*12+:12],
           by0[i*13+:13],by1[i*13+:13]);
  end
  $display("CLUTTER scene=%0d spans=%0d fifo_drops=%0d slot_drops=%0d late=%0d bad=%0d max_queue=%0d cnt=%0d fault=%0d reason=%h ovf=%0d",
           scene,spans,drops,slots,late,bad,max_queue,cnt,fault,reason,ovf);
  if(!frame_valid||drops!=0||late!=0||bad!=0)
   $fatal(1,"FAIL unrelated stream or retirement fault in clutter test");
  if(scene>=2 && !no_clutter && noise_count>=8)begin
   // 故障分级：槽位耗尽只作局部损失。R1 来源与独立计数必须一致，
   // 真目标必须仍然提交；顶边允许因丢掉的首批游程而裁短。
   if(fault||cnt!=1||n!=1||reason!=4'h1||slots==0||
      slot_total!==slots||fifo_total!==32'd0)
    $fatal(1,"FAIL slot-exhaustion frame must commit the target and keep the R1 record");
   $display("SHAPE_TEST_PASS tb_shp_clutter eight-slot overload committed with R1 record");
  end else begin
   if(fault||reason!=0||n!=1||cnt!=1||ovf!=0)
    $fatal(1,"FAIL isolated target lost with light or no clutter");
   $display("SHAPE_TEST_PASS tb_shp_clutter target with light or no clutter");
  end
  $finish_and_return(0);
 end
endmodule

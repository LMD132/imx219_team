`timescale 1ns/1ps
// A full 720p source frame must contain both slot exhaustion and a bad
// captured input span while still delivering its real VS marker intact.
// 2026-10-02 fault grading: those two local faults must no longer void the
// whole frame; the R3 rectangle still commits while reason=3 records both
// sources, so the test keeps the independent S/Q markers and requires CNT=1.
module tb_shp_r3_pressure;
 reg clk=0,rst_n=0,in_vs=0,in_de=0;
 reg [11:0] in_x=0;
 reg [12:0] in_y=0;
 reg [7:0] in_d=0;
 always #5 clk=~clk;
 wire [71:0] bx0,bx1;
 wire [77:0] by0,by1;
 wire [17:0] bcls;
 wire [5:0] bval;
 wire [9:0] cnt;
 wire [15:0] ovf;
 wire fault,frame_valid;
 wire [3:0] reason;
 wire [31:0] slot_total,fifo_total;
 integer x,y,i,dx,dy;
 integer pressure=1;
 integer slot_events=0,full_events=0,bad_marker_in=0,bad_marker_out=0;
 integer lost_markers=0,max_pending=0,max_queue=0;
 reg edge_pixel;

 shp_detect #(.W(1280),.H(720),.NB(8),.FQ(24)) dut(
  .clk(clk),.rst_n(rst_n),.cfg_en(1'b1),
  .cfg_min_size(8'd24),.cfg_max_boxes(3'd6),.cfg_fill_th(10'd875),
  .cfg_max_area(7'd50),.in_vs(in_vs),.in_de(in_de),
  .in_x(in_x),.in_y(in_y),.in_d(in_d),
  .o_bx0(bx0),.o_bx1(bx1),.o_by0(by0),.o_by1(by1),
  .o_bcls(bcls),.o_bval(bval),.o_cnt(cnt),.o_ovf(ovf),
  .o_last_fault(fault),.o_last_reason(reason),.o_frame_valid(frame_valid),
  .o_slot_drop_total(slot_total),.o_fifo_full_total(fifo_total));

 always @(posedge clk) if(rst_n) begin
  if(dut.no_slot_drop) slot_events=slot_events+1;
  if(dut.span_end && dut.f_full) full_events=full_events+1;
  if(dut.push_ok && dut.vs_edge && dut.capture_fault)
   bad_marker_in=bad_marker_in+1;
  if(dut.marker_read && dut.f_dout[38])
   bad_marker_out=bad_marker_out+1;
  if(dut.lost_boundary) lost_markers=lost_markers+1;
  if(dut.pending_edges>max_pending) max_pending=dut.pending_edges;
  if(dut.f_cnt>max_queue) max_queue=dut.f_cnt;
 end

 initial begin
  #30000000;
  $fatal(1,"timeout waiting for 720p R3 pressure frame");
 end

 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  // +NO_PRESSURE preserves the known R1/Q0 contrast case; the default
  // one-line alternating stripe fills the production 24-entry span FIFO.
  if($test$plusargs("NO_PRESSURE"))pressure=0;
  for(y=0;y<750;y=y+1)begin
   for(x=0;x<1650;x=x+1)begin
    edge_pixel=(x>=520&&x<=680&&y>=200&&y<=360&&
                (x==520||x==680||y==200||y==360));
    if(y>=200&&y<360)begin
     dy=(y-200)%16;
     for(i=0;i<8;i=i+1)begin
      dx=x-(60+i*64);
      if(dx>=0&&dx<=5&&dy<=5&&
         (dx==0||dx==5||dy==0||dy==5))edge_pixel=1;
     end
    end
    if(pressure && y==100 && x>=100 && x<900 && ((x-100)%2)==0)
     edge_pixel=1;
    @(negedge clk);in_x=x;in_y=y;in_de=(x<1280&&y<720);
    in_d=edge_pixel?8'hff:0;
   end
  end
  @(negedge clk);in_de=0;in_d=0;in_vs=1;
  @(negedge clk);in_vs=0;
  repeat(100000)@(negedge clk);
  $display("R3_PRESSURE P=%0d S=%0d/%0d Q=%0d/%0d marker_bad=%0d/%0d lost=%0d pending=%0d maxQ=%0d CNT=%0d F=%0d R=%h OV=%0d",
           pressure,slot_total,slot_events,fifo_total,full_events,
           bad_marker_in,bad_marker_out,lost_markers,max_pending,max_queue,
           cnt,fault,reason,ovf);
  for(i=0;i<6;i=i+1)if(bval[i])
   $display("R3_BOX slot=%0d cls=%0d bx=%0d..%0d by=%0d..%0d",
            i,bcls[i*3+:3],bx0[i*12+:12],bx1[i*12+:12],by0[i*13+:13],by1[i*13+:13]);
  // The committed frame must contain exactly the real R3 rectangle; its top
  // edge may be clipped by the dropped first spans, never stretched.
  if(bcls[2:0]!=3'd2 || bx0[11:0]!=12'd520 || bx1[11:0]!=12'd680 ||
     by1[12:0]!=13'd360 || by0[12:0]<13'd200 || by0[12:0]>=13'd360 ||
     bval[5:1]!=5'd0 || !bval[0])
   $fatal(1,"FAIL committed R3 box must be the single clipped rectangle");
  if(!frame_valid || fault || reason!==4'h3 || cnt!==10'd1 ||
     slot_total===32'd0 || fifo_total===32'd0 ||
     slot_total!==slot_events || fifo_total!==full_events ||
     bad_marker_in!=1 || bad_marker_out!=1 || lost_markers!=0 ||
     dut.pending_edges!=0)
   $fatal(1,"FAIL exact R3 must record both sources and still commit the rectangle");
  $display("SHAPE_TEST_PASS tb_shp_r3_pressure exact R3 without whole-frame void");
  $finish_and_return(0);
 end
endmodule

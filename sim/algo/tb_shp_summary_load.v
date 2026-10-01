`timescale 1ns/1ps
// Six close, independent 40x40 square outlines on a real 1650x750 raster.
// The middle 39 rows deliver twelve runs in 326 source pixel clocks; a
// throughput improvement must preserve both the frame and its classification.
module tb_shp_summary_load;
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
 integer x,y,i,dx,slot_events=0,full_events=0;
 integer markers_in=0,markers_out=0,lost_markers=0,commits=0;
 integer max_queue=0,cycles,n,found;
 reg edge_pixel;
 reg [5:0] seen;

 shp_detect #(.W(1280),.H(720),.NB(8),.FQ(24)) dut(
  .clk(clk),.rst_n(rst_n),.cfg_en(1'b1),
  .cfg_min_size(8'd24),.cfg_max_boxes(3'd6),.cfg_fill_th(10'd875),
  .cfg_max_area(7'd50),.in_vs(in_vs),.in_de(in_de),
  .in_x(in_x),.in_y(in_y),.in_d(in_d),
  .o_bx0(bx0),.o_bx1(bx1),.o_by0(by0),.o_by1(by1),
  .o_bcls(bcls),.o_bval(bval),.o_cnt(cnt),.o_ovf(ovf),
  .o_last_fault(fault),.o_last_reason(reason),.o_frame_valid(frame_valid),
  .o_slot_drop_total(slot_total),.o_fifo_full_total(fifo_total));

 // Count the independent pixel-domain events, including the real boundary.
 always @(posedge clk) if(rst_n) begin
  if(dut.no_slot_drop) slot_events=slot_events+1;
  if(dut.span_end && dut.f_full) full_events=full_events+1;
  if(dut.push_ok && dut.vs_edge) markers_in=markers_in+1;
  if(dut.marker_read) markers_out=markers_out+1;
  if(dut.lost_boundary) lost_markers=lost_markers+1;
  if(dut.state==13) commits=commits+1;
  if(dut.f_cnt>max_queue) max_queue=dut.f_cnt;
 end

 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  for(y=0;y<750;y=y+1)begin
   for(x=0;x<1650;x=x+1)begin
    edge_pixel=0;
    if(y>=200 && y<=240)begin
     for(i=0;i<6;i=i+1)begin
      dx=x-(100+i*57); // 16 empty pixels separate the inclusive boxes.
      if(dx>=0 && dx<=40 &&
         (y==200 || y==240 || dx==0 || dx==40)) edge_pixel=1;
     end
    end
    @(negedge clk);
    in_x=x;in_y=y;in_de=(x<1280 && y<720);
    in_d=edge_pixel?8'hff:0;
   end
  end
  @(negedge clk);in_de=0;in_d=0;in_vs=1;
  @(negedge clk);in_vs=0;
  cycles=0;
  while(commits==0 && cycles<100000)begin
   @(negedge clk);cycles=cycles+1;
  end
  if(commits==1) repeat(3)@(negedge clk);
  $display("SUMMARY_LOAD S=%0d/%0d Q=%0d/%0d markers=%0d/%0d lost=%0d commits=%0d pending=%0d maxQ=%0d CNT=%0d F=%0d R=%h OV=%0d BVAL=%b",
           slot_total,slot_events,fifo_total,full_events,
           markers_in,markers_out,lost_markers,commits,
           dut.pending_edges,max_queue,cnt,fault,reason,ovf,bval);
  if(commits!=1 || !frame_valid || markers_in!=1 || markers_out!=1 ||
     lost_markers!=0 || dut.pending_edges!=0)
   $fatal(1,"FAIL one intact 720p frame boundary and commit required");
  if(slot_total!==slot_events || fifo_total!==full_events)
   $fatal(1,"FAIL S/Q disagree with independent per-event monitors");
  if(slot_total!==32'd0 || fifo_total!==32'd0 || fault!==1'b0 ||
     reason!==4'd0 || ovf!==16'd0 || cnt!==10'd6)
   $fatal(1,"FAIL close-six-square load damaged the frame");

  n=0;seen=0;
  for(i=0;i<6;i=i+1) if(bval[i])begin
   n=n+1;found=-1;
   for(x=0;x<6;x=x+1)
    if(bx0[i*12+:12]==(100+x*57) && bx1[i*12+:12]==(140+x*57) &&
       by0[i*13+:13]==200 && by1[i*13+:13]==240) found=x;
   if(found<0 || bcls[i*3+:3]!==3'd2)
    $fatal(1,"FAIL wrong square class or bounds in slot %0d",i);
   if(seen[found]) $fatal(1,"FAIL duplicate square in slot %0d",i);
   seen[found]=1'b1;
  end
  if(n!=6 || seen!==6'b111111)
   $fatal(1,"FAIL lost valid square: boxes=%0d seen=%b",n,seen);
  $display("SHAPE_TEST_PASS tb_shp_summary_load six classified squares without S/Q loss");
  $finish_and_return(0);
 end
endmodule

`timescale 1ns/1ps
// Directed state-unit checks complement the real-summary and full-stream tests.
// These seed the post-simplification polygon intentionally; they do NOT assert
// that every seeded polygon is a supported physical shape.
module tb_shp_corner_unit;
 reg clk=0,rst_n=0,start=0;
 always #5 clk=~clk;
 wire ready,done,valid,rd_req;
 wire [2:0] cls,rd_slot;
 wire [7:0] rd_index;
 shp_geometry dut(.clk(clk),.rst_n(rst_n),.start(start),.slot(3'd0),
  .bbox_x0(12'd100),.bbox_x1(12'd200),.bbox_y0(13'd100),.bbox_y1(13'd200),
  .bad(1'b0),.start_ready(ready),.done(done),.valid(valid),.cls(cls),
  .rd_req(rd_req),.rd_slot(rd_slot),.rd_index(rd_index),
  .rd_valid(1'b0),.rd_data(26'd0));
 integer vx[0:4],vy[0:4];
 integer i,rotation,shift,cycles,checks;

 task seed_five;
  input integer short_length,rotation,shift;
  begin
   @(negedge clk);
   vx[0]=100;vy[0]=100;vx[1]=100+short_length;vy[1]=100;
   vx[2]=180;vy[2]=120;vx[3]=180;vy[3]=200;vx[4]=100;vy[4]=200;
   for(i=0;i<5;i=i+1)begin
    dut.px[i]=vx[(i+rotation)%5]+shift;
    dut.py[i]=vy[(i+rotation)%5]+shift/2;
   end
   dut.pn=5;dut.idx=0;dut.short_count=0;dut.short_idx=0;
   dut.recovered_quad=0;dut.state=dut.SHORT_SCAN;
  end
 endtask
 task finish_scan;
  begin
   cycles=0;
   while(dut.state==dut.SHORT_SCAN&&cycles<6)begin
    @(negedge clk);cycles=cycles+1;
   end
   if(cycles!=5)$fatal(1,"FAIL five-side scan cycles %0d",cycles);
  end
 endtask
 task check_failure_route;
  input integer line_check,recovered;
  begin
   @(negedge clk);
   dut.recovered_quad=recovered;dut.pn=4;dut.idx=3;dut.ridx=0;dut.hn=5;
   dut.line_hit=0;dut.line_residual2_reg=5;dut.line_limit_reg=4;
   dut.side_len=144;dut.side_perpendicular_lhs=2;dut.side_perpendicular_rhs=1;
   dut.side_parallel_lhs=0;dut.side_parallel_rhs=1;
   dut.state=line_check?dut.LINE_CHECK:dut.SIDE_CHECK;
   @(negedge clk);
   if(dut.state!==(recovered?dut.CURVE_INIT:dut.REJECT))
    $fatal(1,"FAIL fallback line%0d recovered%0d state%0d",line_check,recovered,dut.state);
   checks=checks+1;
  end
 endtask
 initial begin
  checks=0;repeat(3)@(negedge clk);rst_n=1;
  // Every short-edge index, including index 4 wrapping to vertex 0. The second
  // translation catches a midpoint sum accidentally narrowed to 11 bits.
  for(shift=0;shift<=1000;shift=shift+1000)
   for(rotation=0;rotation<5;rotation=rotation+1)begin
    seed_five(11,rotation,shift);finish_scan;
    if(dut.pn!=4||!dut.recovered_quad||dut.state!=dut.LINE_CAPTURE)
     $fatal(1,"FAIL short-corner recovery rotation%0d shift%0d",rotation,shift);
    if(dut.px[0]!=105+shift||dut.py[0]!=100+shift/2)
     $fatal(1,"FAIL midpoint rotation%0d shift%0d",rotation,shift);
    for(i=1;i<4;i=i+1)
     if(dut.px[i]!=vx[i+1]+shift||dut.py[i]!=vy[i+1]+shift/2)
      $fatal(1,"FAIL retained vertex rotation%0d vertex%0d",rotation,i);
    checks=checks+1;
   end
  // Strict length boundary: 11 pixels merges, 12 and 13 do not.
  for(rotation=0;rotation<5;rotation=rotation+1)begin
   seed_five(12,rotation,0);finish_scan;
   if(dut.pn!=5||dut.recovered_quad||dut.state!=dut.CURVE_INIT)
    $fatal(1,"FAIL exact 144 length boundary rotation%0d",rotation);
   checks=checks+1;
  end
  seed_five(13,0,0);finish_scan;
  if(dut.pn!=5||dut.recovered_quad||dut.state!=dut.CURVE_INIT)
   $fatal(1,"FAIL longer edge must not merge");
  checks=checks+1;
  seed_five(5,0,0);dut.px[2]=110;dut.py[2]=105;finish_scan;
  if(dut.pn!=5||dut.recovered_quad||dut.state!=dut.CURVE_INIT)
   $fatal(1,"FAIL two short sides must not merge");
  checks=checks+1;
  // Preserve the existing flat-apex triangle path; do not cascade 5->4->3.
  @(negedge clk);
  dut.px[0]=100;dut.py[0]=100;dut.px[1]=108;dut.py[1]=100;
  dut.px[2]=180;dut.py[2]=180;dut.px[3]=20;dut.py[3]=180;
  dut.pn=4;dut.idx=0;dut.short_count=0;dut.short_idx=0;
  dut.recovered_quad=0;dut.state=dut.SHORT_SCAN;
  repeat(4)@(negedge clk);
  if(dut.pn!=3||dut.recovered_quad||dut.state!=dut.LINE_CAPTURE||dut.px[0]!=104)
   $fatal(1,"FAIL existing flat-apex path");
  checks=checks+1;
  check_failure_route(1,1);check_failure_route(1,0);
  check_failure_route(0,1);check_failure_route(0,0);
  // A reused classifier must not inherit recovery fallback from the last object.
  @(negedge clk);dut.state=dut.IDLE;dut.recovered_quad=1;start=1;
  @(negedge clk);start=0;
  if(dut.recovered_quad)$fatal(1,"FAIL recovery flag survives next start");
  checks=checks+1;
  $display("SHAPE_TEST_PASS tb_shp_corner_unit %0d directed checks",checks);
  $finish_and_return(0);
 end
endmodule

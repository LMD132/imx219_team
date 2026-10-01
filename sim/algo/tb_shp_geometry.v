`timescale 1ns/1ps
module tb_shp_geometry;
 reg clk=0,rst_n=0,start=0;
 always #5 clk=~clk;
 reg [2:0] slot=0;
 reg [11:0] bbox_x0=0,bbox_x1=0;
 reg [12:0] bbox_y0=0,bbox_y1=0;
 reg bad=0,rd_valid=0;
 reg [25:0] rd_data=0,words[0:211];
 wire start_ready,done,valid,rd_req;
 wire [2:0] cls,rd_slot;
 wire [7:0] rd_index;
 shp_geometry dut(.clk(clk),.rst_n(rst_n),.start(start),
  .start_ready(start_ready),.slot(slot),.bbox_x0(bbox_x0),
  .bbox_x1(bbox_x1),.bbox_y0(bbox_y0),.bbox_y1(bbox_y1),.bad(bad),
  .done(done),.valid(valid),.cls(cls),.rd_req(rd_req),
  .rd_slot(rd_slot),.rd_index(rd_index),.rd_valid(rd_valid),
  .rd_data(rd_data));
 always @(posedge clk)begin
  rd_valid<=rd_req;
  if(rd_req)rd_data<=words[rd_index];
 end
 integer fd,n,i,j,expect_cls,x0,x1,y0,y1,is_bad,word,cycles,rc,focus;
 reg [8*300-1:0] vector_path;
 always @(negedge clk) if(focus>=0 && i==focus && dut.state==31)
  $display("  radial idx=%0d point=(%0d,%0d) radial=%0d target=%0d lhs=%0d limit=%0d",
    dut.idx,dut.hx[dut.idx],dut.hy[dut.idx],dut.radial_reg,dut.target,
    dut.curve_radial_lhs,dut.curve_radial_limit);
 initial begin
  if(!$value$plusargs("VECTORS=%s",vector_path))
   vector_path="outflow/diagnostics/shape_geometry_vectors.txt";
  fd=$fopen(vector_path,"r");
  if(!fd)$fatal(1,"FAIL geometry vectors missing");
  rc=$fscanf(fd,"%d",n);
  if(rc!=1||n<7)$fatal(1,"FAIL geometry vector count");
  if(!$value$plusargs("CASE=%d",focus))focus=-1;
  repeat(5)@(negedge clk);rst_n=1;
  for(i=0;i<n;i=i+1)begin
   rc=$fscanf(fd,"%d %d %d %d %d %d",expect_cls,x0,x1,y0,y1,is_bad);
   if(rc!=6)$fatal(1,"FAIL geometry metadata %0d",i);
   for(j=0;j<212;j=j+1)begin
    rc=$fscanf(fd,"%h",word);
    if(rc!=1)$fatal(1,"FAIL geometry word %0d/%0d",i,j);
    words[j]=word[25:0];
   end
   if(focus>=0&&i!=focus)continue;
   @(negedge clk);while(!start_ready)@(negedge clk);
   bbox_x0=x0;bbox_x1=x1;bbox_y0=y0;bbox_y1=y1;bad=is_bad;start=1;
   @(negedge clk);start=0;
   cycles=0;
   while(!done&&cycles<100000)begin @(negedge clk);cycles=cycles+1;end
   if(!done)$fatal(1,"FAIL geometry timeout case%0d",i);
   if(valid!==(expect_cls!=0)||cls!==expect_cls[2:0])begin
    $display("  debug case=%0d bounds=(%0d,%0d)-(%0d,%0d) hn=%0d pn=%0d idx=%0d target=%0d",
      i,x0,y0,x1,y1,dut.hn,dut.pn,dut.idx,dut.target);
    for(j=0;j<dut.hn;j=j+1)
     $display("  support[%0d]=(%0d,%0d)",j,dut.hx[j],dut.hy[j]);
    $fatal(1,"FAIL geometry case%0d got valid%0d cls%0d expected%0d",
      i,valid,cls,expect_cls);
   end
  end
  $fclose(fd);
  if(focus>=0)$display("SHAPE_TEST_PASS tb_shp_geometry focused case %0d",focus);
  else $display("SHAPE_TEST_PASS tb_shp_geometry %0d golden cases",n);
  $finish_and_return(0);
 end
endmodule

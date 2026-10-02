`timescale 1ns/1ps
// Raster runs generated from clean rotations and clipped-corner regressions.
// Every source run is driven at its real x coordinate.  A 370-clock horizontal
// blanking interval gives the normal 1650-pixel line budget without spending
// simulation time on unused columns outside each small ROI.
module tb_shp_stream_matrix;
 reg clk=0,rst_n=0,in_vs=0,in_de=0;
 reg [11:0] in_x=0; reg [12:0] in_y=0; reg [7:0] in_d=0;
 always #5 clk=~clk;
 wire [71:0] bx0,bx1; wire [77:0] by0,by1;
 wire [17:0] bcls; wire [5:0] bval; wire [9:0] cnt; wire [15:0] ovf;
 shp_detect #(.W(1280),.H(720)) dut(
  .clk(clk),.rst_n(rst_n),.cfg_en(1'b1),.cfg_min_size(8'd24),
  .cfg_max_boxes(3'd6),.cfg_fill_th(10'd875),.cfg_max_area(7'd50),
  .in_vs(in_vs),.in_de(in_de),.in_x(in_x),.in_y(in_y),.in_d(in_d),
  .o_bx0(bx0),.o_bx1(bx1),.o_by0(by0),.o_by1(by1),
  .o_bcls(bcls),.o_bval(bval),.o_cnt(cnt),.o_ovf(ovf));
 integer run_y[0:2047],run_l[0:2047],run_r[0:2047];
 integer fd,rv,ncase,cid,expected,x0,y0,x1,y1,nrun,ridx;
 integer c,x,y,k,commits=0,cycles,nvalid,got;
 reg [1023:0] path;
 always @(posedge clk) if(rst_n && dut.state==13) commits=commits+1;
 initial begin
  if(!$value$plusargs("VECTORS=%s",path))$fatal(1,"missing stream vectors");
  fd=$fopen(path,"r");
  if(fd==0)$fatal(1,"cannot open stream vectors");
  rv=$fscanf(fd,"%d",ncase);
  if(rv!=1||ncase<1||ncase>4096)$fatal(1,"bad stream case count %0d",ncase);
  for(c=0;c<ncase;c=c+1)begin
   rv=$fscanf(fd,"%d %d %d %d %d %d %d",cid,expected,x0,y0,x1,y1,nrun);
   if(rv!=7||cid!=c||nrun<1||nrun>2048)$fatal(1,"bad case header %0d",c);
   for(k=0;k<nrun;k=k+1)begin
    rv=$fscanf(fd,"%d %d %d",run_y[k],run_l[k],run_r[k]);
    if(rv!=3)$fatal(1,"bad run %0d case %0d",k,c);
   end
   // Reset each fixture so one rejection cannot hide a later acceptance.
   @(negedge clk);rst_n=0;in_de=0;in_vs=0;in_d=0;
   repeat(5)@(negedge clk);
   rst_n=1;commits=0;
   repeat(8)@(negedge clk);
   ridx=0;
   for(y=y0;y<=y1;y=y+1)begin
    for(x=x0-8;x<=x1+8;x=x+1)begin
     @(negedge clk);
     in_de=1;in_x=x;in_y=y;
     in_d=(ridx<nrun && run_y[ridx]==y &&
           x>=run_l[ridx] && x<=run_r[ridx]) ? 8'hff : 8'h00;
     if(ridx<nrun && run_y[ridx]==y && x==run_r[ridx])ridx=ridx+1;
    end
    @(negedge clk);in_de=0;in_d=0;
    repeat(370)@(negedge clk);
   end
   if(ridx!=nrun)$fatal(1,"unconsumed runs case %0d",c);
   @(negedge clk);in_de=0;in_d=0;in_vs=1;
   @(negedge clk);in_vs=0;
   cycles=0;
   while(commits==0 && cycles<100000)begin @(negedge clk);cycles=cycles+1;end
   if(commits!=1)$fatal(1,"missing commit case %0d",c);
   repeat(3)@(negedge clk);
   nvalid=0;got=0;
   for(k=0;k<6;k=k+1)if(bval[k])begin
    nvalid=nvalid+1;got=bcls[k*3 +: 3];
   end
   if(ovf!=0 || (expected==0 && (nvalid!=0||cnt!=0)) ||
      (expected!=0 && (nvalid!=1||cnt!=1||got!=expected)))
    $fatal(1,"stream case %0d expected %0d got %0d valid %0d cnt %0d ovf %0d",
           c,expected,got,nvalid,cnt,ovf);
  end
  $fclose(fd);
  $display("SHAPE_TEST_PASS tb_shp_stream_matrix %0d cases",ncase);
  $finish_and_return(0);
 end
endmodule

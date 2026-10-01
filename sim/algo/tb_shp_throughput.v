`timescale 1ns/1ps
// Six independent 80-pixel squares on a standard 1650x750 720p raster.
// Twelve vertical edge runs per active row must not overflow the run queue.
module tb_shp_throughput;
 reg clk=0,rst_n=0,in_vs=0,in_de=0;
 reg [11:0] in_x=0;reg [12:0] in_y=0;reg [7:0] in_d=0;
 always #5 clk=~clk;
 wire [71:0] bx0,bx1;wire [77:0] by0,by1;
 wire [17:0] bcls;wire [5:0] bval;wire [9:0] cnt;wire [15:0] ovf;
 shp_detect dut(.clk(clk),.rst_n(rst_n),.cfg_en(1'b1),
  .cfg_min_size(8'd24),.cfg_max_boxes(3'd6),.cfg_fill_th(10'd875),
  .cfg_max_area(7'd50),.in_vs(in_vs),.in_de(in_de),.in_x(in_x),.in_y(in_y),.in_d(in_d),
  .o_bx0(bx0),.o_bx1(bx1),.o_by0(by0),.o_by1(by1),
  .o_bcls(bcls),.o_bval(bval),.o_cnt(cnt),.o_ovf(ovf));
 integer x,y,i,n,dx;
 reg pixel_edge;
 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  for(y=0;y<750;y=y+1)begin
   for(x=0;x<1650;x=x+1)begin
    pixel_edge=0;
    if(x<1280&&y<720)begin
     for(i=0;i<6;i=i+1)begin
      dx=x-(100+i*200);
      if(y>=200&&y<=280&&dx>=0&&dx<=80&&
         (y==200||y==280||dx==0||dx==80))pixel_edge=1;
     end
    end
    @(negedge clk);in_x=x;in_y=y;in_de=(x<1280&&y<720);in_d=pixel_edge?8'hff:0;
   end
  end
  @(negedge clk);in_de=0;in_d=0;in_vs=1;
  @(negedge clk);in_vs=0;
  repeat(100000)@(negedge clk);
  n=0;
  for(i=0;i<6;i=i+1)if(bval[i])begin
   n=n+1;
   if(bcls[i*3+:3]!=2)$fatal(1,"FAIL wrong class slot%0d cls%0d",i,bcls[i*3+:3]);
  end
  if(ovf!=0)$fatal(1,"FAIL standard raster overflow %0d",ovf);
  if(n!=6||cnt!=6)$fatal(1,"FAIL six targets n%0d cnt%0d",n,cnt);
  // Deliberately overrun the 24-run queue. A damaged frame must blank the
  // previous detections rather than publish partially assembled geometry.
  for(y=0;y<750;y=y+1)begin
   for(x=0;x<1650;x=x+1)begin
    pixel_edge=(y>=100&&y<140&&x<1280&&x%2==0);
    @(negedge clk);in_x=x;in_y=y;in_de=(x<1280&&y<720);in_d=pixel_edge?8'hff:0;
   end
  end
  @(negedge clk);in_de=0;in_d=0;in_vs=1;
  @(negedge clk);in_vs=0;
  repeat(100000)@(negedge clk);
  if(ovf==0)$fatal(1,"FAIL dense texture did not report overload");
  if(bval!=0||cnt!=0)$fatal(1,"FAIL damaged frame published result bval%h cnt%0d",bval,cnt);
  $display("SHAPE_TEST_PASS tb_shp_throughput six targets and overload reject");
  $finish_and_return(0);
 end
endmodule

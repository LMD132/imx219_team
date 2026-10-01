`timescale 1ns/1ps
// Legacy no-horizontal-blanking stress.  Unlike the 1650-column acceptance
// raster, this source allows only 1280 clocks/row; either all six clean
// squares must be reported or overload must explicitly invalidate the frame.
module tb_shp_no_blank;
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
 reg edge_pixel;
 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  for(y=0;y<720;y=y+1)for(x=0;x<1280;x=x+1)begin
   edge_pixel=0;
   for(i=0;i<6;i=i+1)begin
    dx=x-(100+i*200);
    if(y>=200&&y<=280&&dx>=0&&dx<=80&&
       (y==200||y==280||dx==0||dx==80))edge_pixel=1;
   end
   @(negedge clk);in_x=x;in_y=y;in_de=1;in_d=edge_pixel?8'hff:0;
  end
  @(negedge clk);in_de=0;in_d=0;in_vs=1;
  @(negedge clk);in_vs=0;
  repeat(100000)@(negedge clk);
  n=0;
  for(i=0;i<6;i=i+1)if(bval[i])begin
   n=n+1;
   if(bcls[i*3+:3]!=2)$fatal(1,"wrong no-blank class %0d",i);
  end
  if(ovf==0 && (n!=6||cnt!=6))
   $fatal(1,"silent no-blank loss n%0d cnt%0d",n,cnt);
  if(ovf!=0 && (n!=0||cnt!=0))
   $fatal(1,"partial no-blank classification n%0d cnt%0d ovf%0d",n,cnt,ovf);
  $display("SHAPE_TEST_PASS tb_shp_no_blank boxes=%0d ovf=%0d",n,ovf);
  $finish_and_return(0);
 end
endmodule

`timescale 1ns/1ps
module tb_shp_spacing;
 reg clk=0,rst_n=0,in_vs=0,in_de=0;
 reg [11:0] in_x=0;reg [12:0] in_y=0;reg [7:0] in_d=0;
 always #5 clk=~clk;
 wire [71:0] bx0,bx1;wire [77:0] by0,by1;
 wire [17:0] bcls;wire [5:0] bval;wire [9:0] cnt;wire [15:0] ovf;
 shp_detect #(.W(512),.H(128)) dut(
  .clk(clk),.rst_n(rst_n),.cfg_en(1'b1),.cfg_min_size(8'd24),
  .cfg_max_boxes(3'd6),.cfg_fill_th(10'd875),.cfg_max_area(7'd50),
  .in_vs(in_vs),.in_de(in_de),.in_x(in_x),.in_y(in_y),.in_d(in_d),
  .o_bx0(bx0),.o_bx1(bx1),.o_by0(by0),.o_by1(by1),
  .o_bcls(bcls),.o_bval(bval),.o_cnt(cnt),.o_ovf(ovf));
 integer x,y,gap,i,n,x2;
 reg pixel_edge;
 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  for(gap=2;gap<=32;gap=gap*2)begin
   x2=101+gap;
   for(y=0;y<135;y=y+1)begin
    for(x=0;x<640;x=x+1)begin
     pixel_edge=0;
     if(y>=40&&y<=80)begin
      if(x>=60&&x<=100&&(x==60||x==100||y==40||y==80))pixel_edge=1;
      if(x>=x2&&x<=x2+40&&(x==x2||x==x2+40||y==40||y==80))pixel_edge=1;
     end
     @(negedge clk);in_x=x;in_y=y;in_de=(x<512&&y<128);in_d=pixel_edge?8'hff:0;
    end
   end
   @(negedge clk);in_de=0;in_d=0;in_vs=1;
   @(negedge clk);in_vs=0;
   repeat(10000)@(negedge clk);
   n=0;
   for(i=0;i<6;i=i+1)if(bval[i])begin
    n=n+1;
    if(bcls[i*3+:3]!=2)$fatal(1,"FAIL gap%0d unexpected class%0d",gap,bcls[i*3+:3]);
   end
   $display("spacing gap=%0d boxes=%0d ovf=%0d",gap,n,ovf);
   if(gap<=4&&n!=0)$fatal(1,"FAIL gap%0d merged two boxes into a false known shape",gap);
   if(gap>=8&&n!=2)$fatal(1,"FAIL gap%0d should separate two boxes, got%0d",gap,n);
   if(ovf!=0)$fatal(1,"FAIL gap%0d overflow%0d",gap,ovf);
  end
  $display("SHAPE_TEST_PASS tb_shp_spacing 2/4/8/16/32 pixel gaps");
  $finish_and_return(0);
 end
endmodule

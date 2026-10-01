`timescale 1ns/1ps
module tb_shp_lifecycle;
 reg clk=0,rst_n=0,cfg_en=1,in_vs=0,in_de=0;
 reg [11:0] in_x=0;reg [12:0] in_y=0;reg [7:0] in_d=0;
 always #5 clk=~clk;
 wire [71:0] bx0,bx1;wire [77:0] by0,by1;
 wire [17:0] bcls;wire [5:0] bval;wire [9:0] cnt;wire [15:0] ovf;
 shp_detect #(.W(256),.H(128),.HOLD(2)) dut(
  .clk(clk),.rst_n(rst_n),.cfg_en(cfg_en),.cfg_min_size(8'd24),
  .cfg_max_boxes(3'd6),.cfg_fill_th(10'd875),.cfg_max_area(7'd50),
  .in_vs(in_vs),.in_de(in_de),.in_x(in_x),.in_y(in_y),.in_d(in_d),
  .o_bx0(bx0),.o_bx1(bx1),.o_by0(by0),.o_by1(by1),
  .o_bcls(bcls),.o_bval(bval),.o_cnt(cnt),.o_ovf(ovf));
 integer x,y,i,n,frame_id;
 reg pixel_edge;
 task frame;
 input integer shape;
 begin
  for(y=0;y<135;y=y+1)begin
   for(x=0;x<300;x=x+1)begin
    pixel_edge=0;
    if(shape==1&&x>=70&&x<=110&&y>=40&&y<=80)
     pixel_edge=(x==70||x==110||y==40||y==80);
    if(shape==2&&x>=70&&x<=110&&y>=40&&y<=80)
     pixel_edge=((x>=87&&x<=93)||(y>=57&&y<=63));
    @(negedge clk);in_x=x;in_y=y;in_de=(x<256&&y<128);in_d=pixel_edge?8'hff:0;
   end
  end
  @(negedge clk);in_de=0;in_d=0;in_vs=1;
  @(negedge clk);in_vs=0;
  repeat(10000)@(negedge clk);
 end endtask
 function integer count_boxes;
 input [5:0] val;
 integer k;
 begin count_boxes=0;for(k=0;k<6;k=k+1)if(val[k])count_boxes=count_boxes+1;end
 endfunction
 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  frame(1);
  if(count_boxes(bval)!=1||bcls[2:0]!=2)$fatal(1,"FAIL initial square n%0d cls%0d",count_boxes(bval),bcls[2:0]);
  frame(0);
  frame(0);
  if(count_boxes(bval)!=0)$fatal(1,"FAIL stale rectangle after two empty frames");
  frame(2);
  if(count_boxes(bval)!=0)$fatal(1,"FAIL cross was accepted");
  frame(1);
  if(count_boxes(bval)!=1)$fatal(1,"FAIL re-detect after empty");
  n=ovf;
  force dut.recent_bad=8'hff;
  frame(1);
  release dut.recent_bad;
  if(cnt!=0)$fatal(1,"FAIL invalid recent-run summary was classified");
  if(ovf<=n)$fatal(1,"FAIL recent-run summary anomaly not counted");
  @(negedge clk);cfg_en=0;
  repeat(2)@(negedge clk);
  if(count_boxes(bval)!=0)$fatal(1,"FAIL disable not immediate");
  @(negedge clk);cfg_en=1;
  frame(0);
  if(count_boxes(bval)!=0)$fatal(1,"FAIL stale state after enable");
  $display("SHAPE_TEST_PASS tb_shp_lifecycle bounded hold disable reject reset");
  $finish_and_return(0);
 end
endmodule

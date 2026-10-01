`timescale 1ns/1ps
module tb_shp_connect;
 reg clk=0,rst_n=0,vs=0,de=0; always #5 clk=~clk;
 reg [11:0] x=0;reg [12:0] y=0;reg [7:0] d=0;
 wire [71:0] x0,x1;wire [77:0] y0,y1;wire [17:0] cls;wire [5:0] valid;
 wire [9:0] cnt;wire [15:0] ovf;
 shp_detect dut(.clk(clk),.rst_n(rst_n),.cfg_en(1'b1),.cfg_min_size(8'd16),.cfg_max_boxes(3'd6),
 .cfg_fill_th(10'd875),.cfg_max_area(7'd50),.in_vs(vs),.in_de(de),.in_x(x),.in_y(y),.in_d(d),
 .o_bx0(x0),.o_bx1(x1),.o_by0(y0),.o_by1(y1),.o_bcls(cls),.o_bval(valid),.o_cnt(cnt),.o_ovf(ovf));
 integer xx,yy,i,n,outer_seen,inner_seen;
 function edge_at;
 input integer xx,yy;
 begin edge_at=((xx>=100&&xx<=300&&yy>=100&&yy<=300)&&
 (xx==100||xx==300||yy==100||yy==300))||
 ((xx>=160&&xx<=240&&yy>=160&&yy<=240)&&
 (xx==160||xx==240||yy==160||yy==240));end
 endfunction
 initial begin
  repeat(5)@(negedge clk);rst_n=1;repeat(10)@(negedge clk);
  for(yy=0;yy<720;yy=yy+1)begin
   for(xx=0;xx<1280;xx=xx+1)begin @(negedge clk);de=1;x=xx;y=yy;d=edge_at(xx,yy)?255:0;end
   @(negedge clk);de=0;d=0;repeat(370)@(negedge clk);
  end
  @(negedge clk);vs=1;repeat(4)@(negedge clk);vs=0;
  repeat(30000)@(negedge clk);
  n=0;outer_seen=0;inner_seen=0;
  for(i=0;i<6;i=i+1)if(valid[i])begin
   n=n+1;
   if(cls[i*3+:3]!==2)$fatal(1,"FAIL connect non-rectangle");
   if(x0[i*12+:12]==100&&x1[i*12+:12]==300)outer_seen=outer_seen+1;
   if(x0[i*12+:12]==160&&x1[i*12+:12]==240)inner_seen=inner_seen+1;
  end
  if(n!=2||outer_seen!=1||inner_seen!=1||ovf!=0)$fatal(1,"FAIL disconnected nested rectangles n%0d outer%0d inner%0d ovf%0d",n,outer_seen,inner_seen,ovf);
  $display("SHAPE_TEST_PASS tb_shp_connect historical bbox overlap stays separate");$finish_and_return(0);
 end
endmodule

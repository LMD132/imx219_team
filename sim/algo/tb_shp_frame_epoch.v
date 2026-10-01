`timescale 1ns/1ps
// Two frame edges while run work is queued must not collapse into one commit.
module tb_shp_frame_epoch;
 reg clk=0,rst_n=0,in_vs=0,in_de=0;
 reg [11:0] in_x=0;reg [12:0] in_y=0;reg [7:0] in_d=0;
 always #5 clk=~clk;
 wire [71:0] bx0,bx1;wire [77:0] by0,by1;
 wire [17:0] bcls;wire [5:0] bval;wire [9:0] cnt;wire [15:0] ovf;
 shp_detect #(.W(256),.H(128)) dut(.clk(clk),.rst_n(rst_n),.cfg_en(1'b1),
  .cfg_min_size(8'd24),.cfg_max_boxes(3'd6),.cfg_fill_th(10'd875),
  .cfg_max_area(7'd50),.in_vs(in_vs),.in_de(in_de),.in_x(in_x),.in_y(in_y),.in_d(in_d),
  .o_bx0(bx0),.o_bx1(bx1),.o_by0(by0),.o_by1(by1),
  .o_bcls(bcls),.o_bval(bval),.o_cnt(cnt),.o_ovf(ovf));
 integer commits=0,cycles,k;
 always @(posedge clk) if(rst_n && dut.state==13) commits=commits+1;
 task frame_edge;
 begin
  @(negedge clk);in_vs=1;
  @(negedge clk);in_vs=0;
 end endtask
 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  // Small burst leaves several source runs in the FIFO, but does not fill it.
  for(k=0;k<4;k=k+1)begin
   @(negedge clk);in_x=20+k*40;in_y=50;in_de=1;in_d=8'hff;
   @(negedge clk);in_x=21+k*40;in_d=0;
  end
  @(negedge clk);in_de=0;
  frame_edge();
  frame_edge();
  cycles=0;
  while(commits<2 && cycles<100000)begin @(negedge clk);cycles=cycles+1;end
  if(commits!=2)$fatal(1,"FAIL frame edges coalesced: commits=%0d",commits);
  if(ovf==0)$fatal(1,"FAIL missed-boundary deadline not reported");
  if(bval!=0||cnt!=0)$fatal(1,"FAIL late frame published labels");
  // A boundary arriving while the queue is full must still cause an invalid
  // commit after queued spans drain, rather than vanishing entirely.
  @(negedge clk);rst_n=0;in_de=0;in_vs=0;in_d=0;
  repeat(5)@(negedge clk);rst_n=1;commits=0;
  for(k=0;k<50;k=k+1)begin
   @(negedge clk);in_x=20+k*2;in_y=60;in_de=1;in_d=8'hff;
   @(negedge clk);in_x=21+k*2;in_d=0;
  end
  @(negedge clk);in_de=0;
  frame_edge();
  cycles=0;
  while(commits<1 && cycles<100000)begin @(negedge clk);cycles=cycles+1;end
  if(commits!=1)$fatal(1,"FAIL full-queue boundary lost: commits=%0d",commits);
  if(ovf==0||bval!=0||cnt!=0)
   $fatal(1,"FAIL full-queue frame not invalidated ovf=%0d bval=%0h cnt=%0d",ovf,bval,cnt);
  if(dut.sync_lost!==1'b1)
   $fatal(1,"FAIL capture resumed without a real recovery boundary");
  for(k=0;k<8;k=k+1)begin
   @(negedge clk);in_x=20+k*2;in_y=70;in_de=1;in_d=8'hff;
   @(negedge clk);in_x=21+k*2;in_d=0;
  end
  @(negedge clk);in_de=0;
  if(dut.f_cnt!=0)$fatal(1,"FAIL partial recovery frame entered queue");
  frame_edge();
  cycles=0;
  while(commits<2 && cycles<100000)begin @(negedge clk);cycles=cycles+1;end
  if(commits!=2||bval!=0||cnt!=0)
   $fatal(1,"FAIL recovery frame was not invalidated");

  // A's end marker can be processing while B fills the FIFO.  B's damage
  // must stay attached to B after A commits, even if B's VS comes later.
  @(negedge clk);rst_n=0;in_de=0;in_vs=0;in_d=0;
  repeat(5)@(negedge clk);rst_n=1;commits=0;
  for(k=0;k<8;k=k+1)begin
   @(negedge clk);in_x=20+k*30;in_y=20;in_de=1;in_d=8'hff;
   @(negedge clk);in_x=21+k*30;in_d=0;
  end
  @(negedge clk);in_de=0;
  frame_edge(); // frame A
  for(k=0;k<50;k=k+1)begin
   @(negedge clk);in_x=20+k*2;in_y=60;in_de=1;in_d=8'hff;
   @(negedge clk);in_x=21+k*2;in_d=0;
  end
  @(negedge clk);in_de=0;
  if(ovf==0||commits!=0)$fatal(1,"FAIL B did not overflow while A was pending");
  cycles=0;
  while((commits<1 || dut.f_cnt!=0 || dut.state!=0) && cycles<100000)begin
   @(negedge clk);cycles=cycles+1;
  end
  if(cycles==100000)$fatal(1,"FAIL A/B backlog did not drain");
  k=dut.f_wp;
  @(negedge clk);in_vs=1;
  @(posedge clk);#1;
  if(dut.fifo[k][38]!==1'b1)
   $fatal(1,"FAIL B overflow not carried by B's boundary marker");
  @(negedge clk);in_vs=0;
  cycles=0;
  while(commits<2 && cycles<100000)begin @(negedge clk);cycles=cycles+1;end
  if(commits!=2||bval!=0||cnt!=0)$fatal(1,"FAIL B partial frame published");
  $display("SHAPE_TEST_PASS tb_shp_frame_epoch boundaries and deadline");
  $finish_and_return(0);
 end
endmodule

`timescale 1ns/1ps
module tb_shp_recent;
 reg clk=0,rst_n=0,cmd_valid=0,query_start=0;
 always #5 clk=~clk;
 reg [1:0] cmd_op=0;
 reg [2:0] cmd_slot=0,cmd_other=0;
 reg [11:0] cmd_x0=0,cmd_x1=0,query_x0=0,query_x1=0;
 reg [12:0] cmd_y=0,query_y=0;
 wire cmd_ready,query_ready,query_done;
 wire [7:0] o_matches,bad;
 shp_recent dut(.clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),
  .cmd_ready(cmd_ready),.cmd_op(cmd_op),.cmd_slot(cmd_slot),
  .cmd_other(cmd_other),.cmd_x0(cmd_x0),.cmd_x1(cmd_x1),.cmd_y(cmd_y),
  .query_start(query_start),.query_ready(query_ready),
  .query_x0(query_x0),.query_x1(query_x1),.query_y(query_y),
  .query_done(query_done),.o_matches(o_matches),.bad(bad));
 task command;
 input [1:0] op;input [2:0] slot,other;
 input [12:0] y;input [11:0] x0,x1;
 begin
  @(negedge clk);while(!cmd_ready)@(negedge clk);
  cmd_op=op;cmd_slot=slot;cmd_other=other;
  cmd_y=y;cmd_x0=x0;cmd_x1=x1;cmd_valid=1;
  @(negedge clk);cmd_valid=0;
  while(!cmd_ready)@(negedge clk);
 end endtask
 task check_query;
 input [12:0] y;input [11:0] x0,x1;input [7:0] expected;
 integer cycles;
 begin
  @(negedge clk);while(!query_ready)@(negedge clk);
  query_y=y;query_x0=x0;query_x1=x1;query_start=1;
  @(negedge clk);query_start=0;
  cycles=0;
  while(!query_done&&cycles<300)begin @(negedge clk);cycles=cycles+1;end
  if(!query_done)$fatal(1,"FAIL recent query timeout");
  if(o_matches!==expected)$fatal(1,"FAIL recent query y%0d x%0d-%0d got%h expected%h",
    y,x0,x1,o_matches,expected);
 end endtask
 integer i;
 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  command(0,0,0,0,0,0);command(0,1,0,0,0,0);
  command(1,0,0,100,100,110);command(1,0,0,100,200,210);
  check_query(104,100,110,8'b00000001);
  check_query(104,150,160,0);
  command(1,1,0,104,300,310);
  command(2,1,0,104,0,0);
  check_query(104,200,210,8'b00000011);
  check_query(105,200,210,0);
  command(0,0,0,0,0,0);
  check_query(104,200,210,8'b00000010);
  for(i=0;i<17;i=i+1)command(1,1,0,104,400+i*8,404+i*8);
  if(!bad[1])$fatal(1,"FAIL recent capacity not marked bad");
  command(0,1,0,0,0,0);
  if(bad[1])$fatal(1,"FAIL recent clear did not clear bad");
  check_query(104,200,210,0);
  $display("SHAPE_TEST_PASS tb_shp_recent scan merge gap and capacity");
  $finish_and_return(0);
 end
endmodule

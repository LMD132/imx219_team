`timescale 1ns/1ps
module tb_shp_summary;
 reg clk=0,rst_n=0;
 always #5 clk=~clk;
 reg cmd_valid=0; wire cmd_ready;
 reg [1:0] cmd_op=0;
 reg [2:0] cmd_slot=0,cmd_other=0;
 reg [11:0] cmd_x0=0,cmd_x1=0; reg [12:0] cmd_y=0;
 reg rd_req=0; wire rd_ready,rd_valid; reg [2:0] rd_slot=0;
 reg [7:0] rd_index=0; wire [25:0] rd_data; wire [7:0] bad;
 shp_summary dut(.clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
  .cmd_op(cmd_op),.cmd_slot(cmd_slot),.cmd_other(cmd_other),.cmd_x0(cmd_x0),.cmd_x1(cmd_x1),.cmd_y(cmd_y),
  .rd_req(rd_req),.rd_ready(rd_ready),.rd_slot(rd_slot),.rd_index(rd_index),.rd_valid(rd_valid),.rd_data(rd_data),.bad(bad));
 integer fd,n,phase,nops,bmask,op,slot,other,y,x0,x1,rc,i,j,errors=0,waited;
 reg [25:0] expected;
 task wait_idle;
 begin
  waited=0;
  while(!cmd_ready)begin @(negedge clk);waited=waited+1;if(waited>3000)$fatal(1,"FAIL summary command timeout");end
 end endtask
 initial begin
  repeat(4)@(negedge clk);rst_n=1;
  fd=$fopen("outflow/diagnostics/shape_summary_vectors.txt","r");
  if(!fd)$fatal(1,"FAIL missing summary goldens");
  rc=$fscanf(fd,"%d\n",n);
  for(phase=0;phase<n;phase=phase+1)begin
   rc=$fscanf(fd,"%d %d\n",nops,bmask);
   for(i=0;i<nops;i=i+1)begin
    rc=$fscanf(fd,"%d %d %d %d %d %d\n",op,slot,other,y,x0,x1);
    if(rc!=6)$fatal(1,"FAIL truncated summary commands");
    wait_idle();cmd_op=(op==3)?1:op;cmd_slot=slot;cmd_other=other;cmd_y=y;cmd_x0=x0;cmd_x1=x1;cmd_valid=1;
    @(negedge clk);cmd_valid=0;
    if(op==3)begin
     // Interrupt a real update before it can finish, then prove logical empty.
     repeat(2)@(negedge clk);rst_n=0;repeat(2)@(negedge clk);rst_n=1;
    end
    wait_idle();
   end
   if(bad!==bmask[7:0])begin $display("FAIL phase %0d bad %h expected %h",phase,bad,bmask);errors=errors+1;end
   for(i=0;i<8;i=i+1)for(j=0;j<212;j=j+1)begin
    rc=$fscanf(fd,"%h\n",expected);if(rc!=1)$fatal(1,"FAIL truncated summary words");
    @(negedge clk);rd_slot=i;rd_index=j;rd_req=1;
    if(!rd_ready)$fatal(1,"FAIL read not ready while idle");
    @(posedge clk);#1;
    if(!rd_valid || rd_data!==expected)begin
     if(errors<10)$display("FAIL summary phase %0d slot%0d index%0d got%h expected%h valid%0d",phase,i,j,rd_data,expected,rd_valid);
     errors=errors+1;
    end
    @(negedge clk);rd_req=0;
   end
  end
  $fclose(fd);
  if(errors)$fatal(1,"FAIL summary %0d errors",errors);
  $display("SHAPE_TEST_PASS tb_shp_summary %0d phases",n);$finish_and_return(0);
 end
 initial begin #20000000;$fatal(1,"FAIL summary global timeout");end
endmodule

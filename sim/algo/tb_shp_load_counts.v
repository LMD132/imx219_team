`timescale 1ns/1ps
// Counters must report actual pixel-domain events, not infer them from R/OV.
module tb_shp_load_counts;
 reg clk=0,rst_n=0,cfg_en=1,in_vs=0,in_de=0;
 reg [11:0] in_x=0;
 reg [12:0] in_y=0;
 reg [7:0] in_d=0;
 always #5 clk=~clk;
 wire [71:0] bx0,bx1;
 wire [77:0] by0,by1;
 wire [17:0] bcls;
 wire [5:0] bval;
 wire [9:0] cnt;
 wire [15:0] ovf;
 wire fault,frame_valid;
 wire [3:0] reason;
 wire [31:0] slot_total,fifo_total;
 integer expected_s=0,expected_q=0,vs_nonfull=0;
 integer i,j;
 reg [31:0] held_s,held_q;

 shp_detect #(.W(128),.H(64),.FQ(2)) dut(
  .clk(clk),.rst_n(rst_n),.cfg_en(cfg_en),
  .cfg_min_size(8'd24),.cfg_max_boxes(3'd6),.cfg_fill_th(10'd875),
  .cfg_max_area(7'd50),.in_vs(in_vs),.in_de(in_de),
  .in_x(in_x),.in_y(in_y),.in_d(in_d),
  .o_bx0(bx0),.o_bx1(bx1),.o_by0(by0),.o_by1(by1),
  .o_bcls(bcls),.o_bval(bval),.o_cnt(cnt),.o_ovf(ovf),
  .o_last_fault(fault),.o_last_reason(reason),.o_frame_valid(frame_valid),
  .o_slot_drop_total(slot_total),.o_fifo_full_total(fifo_total));

 // Independent pre-edge scoreboard: the events are not derived from DUT counters.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin expected_s=0; expected_q=0; vs_nonfull=0; end
  else if(cfg_en) begin
   if(dut.no_slot_drop) expected_s=expected_s+1;
   if(dut.span_end && dut.f_full) expected_q=expected_q+1;
   if(dut.span_end && dut.vs_edge && !dut.f_full)
    vs_nonfull=vs_nonfull+1;
  end
 end

 task check_totals;
  begin
   @(negedge clk);
   if(slot_total !== expected_s || fifo_total !== expected_q)
    $fatal(1,"counter mismatch S=%h/%0d Q=%h/%0d",slot_total,expected_s,
           fifo_total,expected_q);
  end
 endtask

 task paced_run;
  input integer x0;
  integer k;
  begin
   for(k=0;k<4;k=k+1)begin
    @(negedge clk);in_de=1;in_d=8'hff;in_x=x0+k;in_y=13'd10;
   end
   @(negedge clk);in_de=1;in_d=0;in_x=x0+4;
   repeat(300)@(negedge clk);
  end
 endtask

 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  repeat(5)@(negedge clk);

  // VS and span-end in one cycle, with an empty FIFO: old reason bit 1
  // marks bad input, but Q must not count it as queue-full.
  @(negedge clk);in_de=1;in_d=8'hff;in_x=12'd10;in_y=13'd4;
  @(negedge clk);in_d=0;in_x=12'd11;in_vs=1;
  @(negedge clk);in_de=0;in_vs=0;
  repeat(3000)@(negedge clk);
  check_totals();
  if(vs_nonfull!=1 || fifo_total!==32'd0 || !frame_valid ||
     !fault || reason!==4'h2 || cnt!==10'd0 || ovf!==16'd1)
   $fatal(1,"VS collision misclassified F=%b R=%h OV=%h VS=%0d",fault,
          reason,ovf,vs_nonfull);

  // Dense spans exceed FQ=2 while the existing state machine drains slowly.
  for(i=0;i<48;i=i+1)begin
   @(negedge clk);in_de=1;in_d=8'hff;in_x=i*2;in_y=13'd12;
   @(negedge clk);in_de=1;in_d=0;in_x=i*2+1;
  end
  @(negedge clk);in_de=0;in_d=0;
  repeat(500)@(negedge clk);
  check_totals();
  if(expected_q==0 || fifo_total===32'd0)
   $fatal(1,"stimulus failed to fill FIFO");

  held_s=slot_total;held_q=fifo_total;
  @(negedge clk);cfg_en=0;
  for(i=0;i<12;i=i+1)begin
   @(negedge clk);in_de=1;in_d=8'hff;in_x=i*2;in_y=13'd20;
   @(negedge clk);in_d=0;in_x=i*2+1;
  end
  @(negedge clk);in_de=0;in_d=0;
  repeat(20)@(negedge clk);
  check_totals();
  if(slot_total!==held_s || fifo_total!==held_q)
   $fatal(1,"counters changed while shape disabled");

  // Re-enable clears working blobs, not cumulative diagnostics. Nine
  // widely separated, fully processed runs must exhaust eight slots.
  @(negedge clk);cfg_en=1;
  repeat(10)@(negedge clk);
  for(j=0;j<9;j=j+1) paced_run(j*12);
  check_totals();
  if(expected_s==0 || slot_total<=held_s || fifo_total!==held_q)
   $fatal(1,"paced slot exhaustion not isolated S=%h Q=%h",slot_total,fifo_total);
  $display("LOAD_COUNTS before reset S=%0d Q=%0d VS_NONFULL=%0d OV=%0d",
           slot_total,fifo_total,vs_nonfull,ovf);

  @(negedge clk);rst_n=0;
  repeat(4)@(negedge clk);
  if(slot_total!==32'd0 || fifo_total!==32'd0 || ovf!==16'd0)
   $fatal(1,"hardware reset did not clear diagnostics");
  $display("LOAD_COUNTS hardware reset S=%0d Q=%0d",slot_total,fifo_total);
  $display("SHAPE_TEST_PASS tb_shp_load_counts");
  $finish_and_return(0);
 end
endmodule

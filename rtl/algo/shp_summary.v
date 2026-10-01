// Rotation summary storage. One synchronous read port, one write port;
// exact NB*(32+ceil(H/4)) depth, no full-frame cache, no RAM reset loop.
// External reads are accepted only when rd_ready; cmd has priority.
module shp_summary #(
 parameter integer W=1280,H=720,NB=8
)(
 input wire clk,rst_n,
 input wire cmd_valid,output wire cmd_ready,
 input wire [1:0] cmd_op,input wire [2:0] cmd_slot,cmd_other,
 input wire [11:0] cmd_x0,cmd_x1,input wire [12:0] cmd_y,
 input wire rd_req,output wire rd_ready,input wire [2:0] rd_slot,
 input wire [7:0] rd_index,output reg rd_valid,output wire [25:0] rd_data,
 output reg [NB-1:0] bad
);
 localparam integer ENTRIES=32+(H+3)/4,DEPTH=NB*ENTRIES;
 localparam IDLE=0,CLEAR=1,DST_READ=2,SRC_READ=3,WRITE=4;
 reg [2:0] state;
 reg [1:0] op;
 reg [2:0] slot,other;
 reg [7:0] index;
 reg [11:0] x0,x1;reg [12:0] y;
 reg [NB-1:0] live;
 reg [25:0] destination;
 reg [25:0] memory[0:DEPTH-1];
 reg [25:0] memory_data;
 reg [10:0] ra,wa;reg re,we;reg [25:0] wd;
 reg visible_read;
 wire [25:0] old_word=(op==2)?destination:memory_data;
 assign cmd_ready=(state==IDLE);
 assign rd_ready=(state==IDLE)&&!cmd_valid;
 assign rd_data=visible_read?memory_data:26'd0;

 // Generated from frozen shape_params.json Q8 directions. Signed ten bits.
 function signed [9:0] dx;
 input [4:0] k;
 begin case(k)
  0:dx=256;1:dx=251;2:dx=237;3:dx=213;4:dx=181;5:dx=142;6:dx=98;7:dx=50;
  8:dx=0;9:dx=-50;10:dx=-98;11:dx=-142;12:dx=-181;13:dx=-213;14:dx=-237;15:dx=-251;
  16:dx=-256;17:dx=-251;18:dx=-237;19:dx=-213;20:dx=-181;21:dx=-142;22:dx=-98;23:dx=-50;
  24:dx=0;25:dx=50;26:dx=98;27:dx=142;28:dx=181;29:dx=213;30:dx=237;31:dx=251;
 endcase end endfunction
 wire signed [9:0] cx=dx(index[4:0]),cy=dx(index[4:0]-5'd8);
 wire [11:0] span_x=(cx>0)?x1:x0;
 wire [25:0] candidate=(op==2)?(live[other]?memory_data:26'd0):{1'b1,y,span_x};
 wire signed [23:0] projection_old=$signed({1'b0,old_word[11:0]})*cx+$signed({1'b0,old_word[24:12]})*cy;
 wire signed [23:0] projection_new=$signed({1'b0,candidate[11:0]})*cx+$signed({1'b0,candidate[24:12]})*cy;
 wire take_point=candidate[25]&&(!old_word[25]||projection_new>projection_old||
  (projection_new==projection_old&&candidate[24:0]<old_word[24:0]));
 wire [25:0] strip_source=(op==2)?(live[other]?memory_data:26'd0):{1'b0,1'b1,x0,x1};
 wire [11:0] strip_left=(!old_word[24]||strip_source[23:12]<old_word[23:12])?strip_source[23:12]:old_word[23:12];
 wire [11:0] strip_right=(!old_word[24]||strip_source[11:0]>old_word[11:0])?strip_source[11:0]:old_word[11:0];

 always @* begin
  re=0;we=0;ra=0;wa=slot*ENTRIES+index;wd=0;
  if(state==IDLE&&rd_req&&rd_ready&&rd_slot<NB&&rd_index<ENTRIES)begin re=1;ra=rd_slot*ENTRIES+rd_index;end
  if(state==CLEAR)begin we=1;wd=0;end
  if(state==DST_READ)begin re=1;ra=slot*ENTRIES+index;end
  if(state==SRC_READ)begin re=1;ra=other*ENTRIES+index;end
  if(state==WRITE)begin
   we=1;
   if(index<32)wd=take_point?candidate:old_word;
   else wd=strip_source[24]?{1'b0,1'b1,strip_left,strip_right}:old_word;
  end
 end
 // No asynchronous reset on RAM, so the array remains inferable as BRAM.
 always @(posedge clk)begin
  if(re)memory_data<=memory[ra];
  if(we&&rst_n)memory[wa]<=wd;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;live<=0;bad<=0;rd_valid<=0;visible_read<=0;
   slot<=0;other<=0;op<=0;index<=0;x0<=0;x1<=0;y<=0;destination<=0;
  end else begin
   rd_valid<=rd_req&&rd_ready;
   if(rd_req&&rd_ready)visible_read<=rd_slot<NB&&rd_index<ENTRIES&&live[rd_slot];
   case(state)
    IDLE:if(cmd_valid)begin
     slot<=cmd_slot;other<=cmd_other;op<=cmd_op;index<=0;
     x0<=cmd_x0;x1<=cmd_x1;y<=cmd_y;
     if(cmd_slot<NB)begin
      if(cmd_op==0)begin state<=CLEAR;live[cmd_slot]<=0;bad[cmd_slot]<=0;end
      else if(!live[cmd_slot]||cmd_op==3||
       (cmd_op==1&&(cmd_y>=H||cmd_x0>cmd_x1||cmd_x1>=W))||
       (cmd_op==2&&(cmd_other>=NB||cmd_other==cmd_slot)))bad[cmd_slot]<=1;
      else begin
       if(cmd_op==2)bad[cmd_slot]<=bad[cmd_slot]|bad[cmd_other];
       state<=DST_READ;
      end
     end
    end
    CLEAR:if(index==ENTRIES-1)begin live[slot]<=1;state<=IDLE;end else index<=index+1'b1;
    DST_READ:state<=(op==2)?SRC_READ:WRITE;
    SRC_READ:begin destination<=memory_data;state<=WRITE;end
    WRITE:begin
     if(op==1)begin
      if(index==32+(y>>2))state<=IDLE;
      else begin index<=(index==31)?32+(y>>2):index+1'b1;state<=DST_READ;end
     end else if(index==ENTRIES-1)state<=IDLE;
     else begin index<=index+1'b1;state<=DST_READ;end
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule

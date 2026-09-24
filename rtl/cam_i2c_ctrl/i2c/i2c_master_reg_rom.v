module i2c_master_reg_rom #(

    parameter ROM_SIZE                     = 25,   
    parameter TOTAL_ROM_DEPTH              = 128, // 6*7
    parameter ADDR_WIDTH                   = 6   // alt_clogb2(42) 
) (
    input  wire                  clock,
    input  wire [ADDR_WIDTH-1:0] addr_ptr,
    output wire [ROM_SIZE-1:0]   rdata_out
);

reg  [ROM_SIZE-1:0]   ROM [0:TOTAL_ROM_DEPTH-1];
wire [ROM_SIZE-1:0]   DATAA = {ROM_SIZE{1'b0}};
wire [ADDR_WIDTH-1:0] RADDR;
   
initial begin
		//9134				//addr /data/read_en[1]
    ROM[8'h00] = {16'h3002, 8'h01,1'b1 } ;////master start	
    ROM[8'h01] = {16'h30eb, 8'h05,1'b0 };
    ROM[8'h02] = {16'h30eb, 8'h0c,1'b0 };
    ROM[8'h03] = {16'h300a, 8'hff,1'b0 };									
    ROM[8'h04] = {16'h300b, 8'hff,1'b0 };			
    ROM[8'h05] = {16'h30eb, 8'h05,1'b0 };												
    ROM[8'h06] = {16'h30eb, 8'h09,1'b0 };
    ROM[8'h07] = {16'h0114, 8'h01,1'b0 }; 
    ROM[8'h08] = {16'h0128, 8'h00,1'b0 }; 							    
    ROM[8'h09] = {16'h012a, 8'h18,1'b0 }; 
    ROM[8'h0a] = {16'h012b, 8'h00,1'b0 }; 
    ROM[8'h0b] = {16'h0160, 8'h04,1'b0 };
    ROM[8'h0c] = {16'h0161, 8'h59,1'b0 };// fROM length
    ROM[8'h0d] = {16'h0162, 8'h0d,1'b0 };//1920*1080
    ROM[8'h0e] = {16'h0163, 8'h78,1'b0 };
    ROM[8'h0f] = {16'h0164, 8'h00,1'b0 }; //x start position [15:8]
    ROM[8'h10] = {16'h0165, 8'h20,1'b0 }; //x start position [7 :0]
    ROM[8'h11] = {16'h0166, 8'h07,1'b0 }; //x end position [15:0]
    ROM[8'h12] = {16'h0167, 8'ha0,1'b0 }; //x end position [7:0] x_end - x_start = 1920
    ROM[8'h13] = {16'h0168, 8'h00,1'b0 }; //y start [15:8] 
    ROM[8'h14] = {16'h0169, 8'h00,1'b0 }; //y start [7:0]
    ROM[8'h15] = {16'h016a, 8'h04,1'b0 }; //y end [15:8] y_end - y_start = 1080 
    ROM[8'h16] = {16'h016b, 8'h38,1'b0 }; //y end [7 :0]
    ROM[8'h17] = {16'h016c, 8'h07,1'b0 }; //output image size x-direction [15:8]
    ROM[8'h18] = {16'h016d, 8'h80,1'b0 }; //output image size x-direction [7:0]
    ROM[8'h19] = {16'h016e, 8'h04,1'b0 }; //output image size (Y-direction)[15:8]
    ROM[8'h1a] = {16'h016f, 8'h38,1'b0 }; //output image size (Y-direction)[7:0]
    ROM[8'h1b] = {16'h0170, 8'h01,1'b0 };//Increment for odd pixels 1, 3 我理解如果是odd num.shoud compolimation to even num
    ROM[8'h1c] = {16'h0171, 8'h01,1'b0 };
    ROM[8'h1d] = {16'h0174, 8'h00,1'b0 };
    ROM[8'h1e] = {16'h0175, 8'h00,1'b0 };
    ROM[8'h1f] = {16'h018c, 8'h0a,1'b0 }; //raw10
    ROM[8'h20] = {16'h018d, 8'h0a,1'b0 };
    ROM[8'h21] = {16'h0301, 8'h05,1'b0 };
    ROM[8'h22] = {16'h0303, 8'h01,1'b0 };
    ROM[8'h23] = {16'h0304, 8'h03,1'b0 };
    ROM[8'h24] = {16'h0305, 8'h03,1'b0 };
    ROM[8'h25] = {16'h0306, 8'h00,1'b0 };
    ROM[8'h26] = {16'h0307, 8'h60,1'b0 };
    ROM[8'h27] = {16'h0309, 8'h0a,1'b0 };
    ROM[8'h28] = {16'h030b, 8'h01,1'b0 };
    ROM[8'h29] = {16'h030c, 8'h00,1'b0 };
    ROM[8'h2a] = {16'h030d, 8'h72,1'b0 };
    ROM[8'h2b] = {16'h0309, 8'h0a,1'b0 };
    ROM[8'h2c] = {16'h030b, 8'h01,1'b0 };
    ROM[8'h2d] = {16'h030c, 8'h00,1'b0 };
    ROM[8'h2e] = {16'h030d, 8'h72,1'b0 };
    ROM[8'h2f] = {16'h0100, 8'h01,1'b0 };
    ROM[8'h30] = {16'h0157, 8'hd0,1'b0 };
    ROM[8'h31] = {16'h0158, 8'h02,1'b0 };
    ROM[8'h32] = {16'h0159, 8'h00,1'b0 };
    ROM[8'h33] = {16'h0160, 8'h05,1'b0 };//07
    ROM[8'h34] = {16'h0161, 8'hc8,1'b0 };//90 // fROM length
    ROM[8'h35] = {16'h0162, 8'h0d,1'b0 };//0d
    ROM[8'h36] = {16'h0163, 8'h78,1'b0 };//78
    ROM[8'h37] = {16'h015a, 8'h04,1'b0 };
    ROM[8'h38] = {16'h015b, 8'h6c,1'b0 };
    ROM[8'h39] = {16'h025a, 8'h04,1'b0 };
    ROM[8'h3a] = {16'h025b, 8'h6c,1'b0 };
    ROM[8'h3b] = {16'h0172, 8'h03,1'b0 };
    ROM[8'h3c] = {16'hffff, 8'hff,1'b0 };
      
end 

// write is unused
wire [ADDR_WIDTH-1:0] ADDRA = {ADDR_WIDTH{1'b0}}; 
wire                  WEA   = 1'b0; 
always @ (posedge clock)
begin
    if (WEA) begin
        ROM[ADDRA] <= DATAA;
    end
end
   
assign RADDR = addr_ptr;
   
reg [ROM_SIZE-1:0] RDATA;
always @ (posedge clock)
begin
     RDATA <= ROM[RADDR];
end

assign rdata_out = RDATA;
   
endmodule			      
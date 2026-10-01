`timescale 1ns/1ps

// Regression: the public diagnostics retain the fault result of the latest
// committed frame, even though the internal frame_fault flag is then cleared.
module tb_shp_diag;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    wire [5:0] bval;
    wire [9:0] cnt;
    wire [15:0] ovf;
    wire last_fault;
    wire [3:0] last_reason;
    wire frame_valid;
    integer errors = 0;

    shp_detect #(.W(64), .H(64), .NB(8), .NBX(6), .FQ(24)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_en(1'b1), .cfg_min_size(8'd8), .cfg_max_boxes(3'd6),
        .cfg_fill_th(10'd875), .cfg_max_area(7'd50),
        .in_vs(1'b0), .in_de(1'b0), .in_x(12'd0), .in_y(13'd0), .in_d(8'd0),
        .o_bx0(), .o_bx1(), .o_by0(), .o_by1(), .o_bcls(), .o_bval(bval),
        .o_cnt(cnt), .o_ovf(ovf),
        .o_last_fault(last_fault), .o_last_reason(last_reason),
        .o_frame_valid(frame_valid)
    );

    task check;
        input condition;
        input [255:0] what;
        begin
            if (!condition) begin
                $display("FAIL %0s", what);
                errors = errors + 1;
            end
        end
    endtask

    task commit;
        input fault;
        input [3:0] reason;
        input [9:0] accepted;
        begin
            @(negedge clk);
            force dut.state = 5'd13; // S_COMMIT
            force dut.frame_fault = fault;
            force dut.frame_reason = reason;
            force dut.f_cnt_cur = accepted;
            @(posedge clk);
            #1;
            release dut.state;
            release dut.frame_fault;
            release dut.frame_reason;
            release dut.f_cnt_cur;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        check(frame_valid === 1'b0, "no frame is valid after reset");
        check(last_fault === 1'b0, "reset fault is clear");
        check(last_reason === 4'b0, "reset reason is clear");
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        commit(1'b0, 4'h0, 10'd3);
        check(frame_valid === 1'b1, "normal commit sets frame valid");
        check(last_fault === 1'b0, "normal commit records F0");
        check(cnt === 10'd3, "normal commit records CNT003");
        check(last_reason === 4'h0, "normal commit records R0");

        @(negedge clk);
        force dut.o_bval = 6'b111111;
        #1;
        release dut.o_bval;
        commit(1'b1, 4'h5, 10'd4);
        check(last_fault === 1'b1, "fault commit records F1");
        check(cnt === 10'd0, "fault commit suppresses accepted count");
        check(last_reason === 4'h5, "fault commit records exact source bits");
        check(bval === 6'b000000, "fault commit suppresses all boxes");

        commit(1'b0, 4'h0, 10'd2);
        check(last_fault === 1'b0, "next normal commit clears F1");
        check(cnt === 10'd2, "next normal count is visible");
        check(last_reason === 4'h0, "next normal commit clears source bits");

        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        check(frame_valid === 1'b0, "reset invalidates last frame");
        if (errors != 0) $finish_and_return(1);
        $display("SHAPE_TEST_PASS tb_shp_diag committed fault and count");
        $finish;
    end
endmodule

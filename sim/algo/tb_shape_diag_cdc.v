`timescale 1ns/1ps

// Regression: async clocks may observe either source tuple, never mixed bits;
// resetting either side must invalidate the previous connection's snapshot.
module tb_shape_diag_cdc;
    reg clk_src = 1'b0;
    reg clk_dst = 1'b0;
    reg rst_src_n = 1'b0;
    reg rst_dst_n = 1'b0;
    reg req = 1'b0;
    reg phase = 1'b0;
    always #7 clk_src = ~clk_src;
    always #11 clk_dst = ~clk_dst;
    always @(posedge clk_src or negedge rst_src_n)
        if (!rst_src_n) phase <= 1'b0;
        else phase <= ~phase;

    wire [9:0] cnt;
    wire [15:0] ovf;
    wire fault, frame_valid, sample_valid, busy;
    wire [3:0] reason;
    wire [31:0] slot_total, fifo_total;
    integer errors = 0;
    integer k;

    alg_shape_diag_cdc dut (
        .clk_src(clk_src), .rst_src_n(rst_src_n),
        .i_cnt(phase ? 10'd844 : 10'd155),
        .i_ovf(phase ? 16'hAAAA : 16'h5555),
        .i_fault(phase), .i_reason(phase ? 4'h8 : 4'h1),
        .i_frame_valid(1'b1),
        .i_slot_drop_total(phase ? 32'h02468ACE : 32'h13579BDF),
        .i_fifo_full_total(phase ? 32'hFDB97531 : 32'h2468ACE0),
        .clk_dst(clk_dst), .rst_dst_n(rst_dst_n), .i_req(req),
        .o_cnt(cnt), .o_ovf(ovf), .o_fault(fault), .o_reason(reason),
        .o_slot_drop_total(slot_total), .o_fifo_full_total(fifo_total),
        .o_frame_valid(frame_valid), .o_sample_valid(sample_valid),
        .o_busy(busy)
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

    task request_one;
        integer n;
        begin
            @(negedge clk_dst); req = 1'b1;
            @(negedge clk_dst); req = 1'b0;
            check(busy === 1'b1, "request enters busy state");
            n = 0;
            while (busy !== 1'b0 && n < 100) begin
                @(negedge clk_dst);
                n = n + 1;
            end
            check(n < 100, "request receives acknowledgement");
            check(sample_valid === 1'b1, "completed snapshot is valid");
            check(frame_valid === 1'b1, "source frame-valid crosses intact");
            check(({cnt,ovf,fault,reason,frame_valid,slot_total,fifo_total} ===
                   {10'd155,16'h5555,1'b0,4'h1,1'b1,32'h13579BDF,32'h2468ACE0}) ||
                  ({cnt,ovf,fault,reason,frame_valid,slot_total,fifo_total} ===
                   {10'd844,16'hAAAA,1'b1,4'h8,1'b1,32'h02468ACE,32'hFDB97531}),
                  "complete 96-bit tuple never tears");
        end
    endtask

    initial begin
        repeat (4) @(negedge clk_dst);
        check(sample_valid === 1'b0, "initial sample is invalid");
        rst_src_n = 1'b1;
        rst_dst_n = 1'b1;
        repeat (6) @(negedge clk_dst);

        for (k = 0; k < 20; k = k + 1) request_one();

        // A pulse while busy must not schedule another transfer.
        @(negedge clk_dst); req = 1'b1;
        @(negedge clk_dst); req = 1'b1;
        @(negedge clk_dst); req = 1'b0;
        check(busy === 1'b1, "busy request remains single transaction");
        while (busy !== 1'b0) @(negedge clk_dst);
        repeat (20) begin
            @(negedge clk_dst);
            check(busy === 1'b0, "busy pulse was ignored, not queued");
        end

        @(negedge clk_dst); rst_src_n = 1'b0;
        #1;
        check(sample_valid === 1'b0, "source-only reset invalidates snapshot");
        check(busy === 1'b0, "source-only reset clears pending handshake");
        check({cnt,ovf,fault,reason,frame_valid,slot_total,fifo_total} === 96'd0,
              "source reset clears prior 96-bit tuple");
        repeat (3) @(negedge clk_dst);
        rst_src_n = 1'b1;
        repeat (6) @(negedge clk_dst);
        request_one();

        @(negedge clk_dst); rst_dst_n = 1'b0;
        #1;
        check(sample_valid === 1'b0, "destination-only reset invalidates snapshot");
        check({cnt,ovf,fault,reason,frame_valid,slot_total,fifo_total} === 96'd0,
              "destination reset clears prior 96-bit tuple");
        repeat (3) @(negedge clk_dst);
        rst_dst_n = 1'b1;
        repeat (6) @(negedge clk_dst);
        request_one();

        // Interrupt a pending request from either domain; no old sample may
        // survive or be delivered after that side comes back from reset.
        @(negedge clk_dst); req = 1'b1;
        @(negedge clk_dst); req = 1'b0;
        check(busy === 1'b1, "source-reset transaction became pending");
        @(negedge clk_src); rst_src_n = 1'b0;
        #1;
        check(sample_valid === 1'b0 && busy === 1'b0,
              "source in-flight reset invalidates transaction");
        repeat (3) @(negedge clk_src);
        rst_src_n = 1'b1;
        repeat (6) @(negedge clk_dst);
        request_one();

        @(negedge clk_dst); req = 1'b1;
        @(negedge clk_dst); req = 1'b0;
        check(busy === 1'b1, "destination-reset transaction became pending");
        @(negedge clk_dst); rst_dst_n = 1'b0;
        #1;
        check(sample_valid === 1'b0 && busy === 1'b0,
              "destination in-flight reset invalidates transaction");
        repeat (3) @(negedge clk_dst);
        rst_dst_n = 1'b1;
        repeat (6) @(negedge clk_dst);
        request_one();

        if (errors != 0) $finish_and_return(1);
        $display("SHAPE_TEST_PASS tb_shape_diag_cdc 20 async tuples and independent resets");
        $finish;
    end
endmodule

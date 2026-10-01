module tb_runner_pass;
    reg [3:0] observed;
    initial begin
        observed = 4'd3;
        #1;
        if (observed != 4'd3) $finish_and_return(1);
        $display("SHAPE_TEST_PASS");
        $finish_and_return(0);
    end
endmodule

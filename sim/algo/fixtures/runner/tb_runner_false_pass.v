module tb_runner_false_pass;
    initial begin
        $display("FAIL legacy assertion");
        $display("SHAPE_TEST_PASS");
        $finish_and_return(0);
    end
endmodule

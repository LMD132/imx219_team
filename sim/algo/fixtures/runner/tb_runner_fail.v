module tb_runner_fail;
    initial begin
        $display("FAIL intended assertion");
        $finish_and_return(1);
    end
endmodule

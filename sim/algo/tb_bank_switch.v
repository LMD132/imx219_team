//=============================================================================
// tb_bank_switch.v -- bank_switch 轮换自检 (FB_NUM = 4 / 3 / 2)
//
//  为什么单独测它:
//    时域降噪要用"上一帧", 而上一帧的读地址 rd_start_addr_prev 完全由 bank_switch
//    的轮换决定。轮换一旦算错, 表现是画面撕裂/花屏, 仿真里看不出来, 只有上板才发现。
//    所以这里把不变量逐拍查死。
//
//  检查项(每一条都在下面的 monitor 里, 有错就 $display 并把 errors 加 1):
//    A. wr_bank != rd_bank                    -- 写端不能碰正在读的 bank  (FB_NUM>=2)
//    D. wr_bank 不属于 {rd_bank, rd_bank-1}    -- 也不能碰"上一帧"那个 bank (FB_NUM==4)
//    B. 每次读侧滚动, 读到的 bank 里必须是"最新写满的那一帧"
//       (用 seq[] 给每个 bank 记"最后一次写满的帧号", 在写侧切走 bank 时置位)
//    C. FB_NUM==4: rd_start_addr_prev == addr_of(rd_bank-1), 且两帧的帧号正好差 1
//       -> 这就是"上一帧同位置像素"能对齐的依据
//
//  激励: 写侧周期 10 拍(等效相机 30fps), 读侧周期 5 拍(等效显示 60fps),
//        两者相位对齐 -> 每 10 拍必然同拍请求一次, 专门压那条"待处理请求"路径。
//=============================================================================
`timescale 1ns/1ps

module tb_one #(
    parameter integer FB_NUM = 4,
    parameter integer TSTOP  = 4000,
    // 只有最后一个实例叫 $finish, 否则先跑完的那个会把其它实例的 RESULT 行截断
    parameter integer FINISH = 1
)();
    // (640*720*32/8 + 512) = 1843712 -> 向上取整到 4096 = 1847296
    localparam [31:0] FL = 32'd1847296;

    function [31:0] addr_of;
        input [1:0] b;
        begin
            case( b )
                2'd0:    addr_of = 32'd0;
                2'd1:    addr_of = FL;
                2'd2:    addr_of = FL*2;
                default: addr_of = FL*3;
            endcase
        end
    endfunction

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    reg  wr_sw = 1'b0;
    reg  rd_sw = 1'b0;
    wire [1:0]  wr_bank, rd_bank;
    wire [31:0] rd_addr, wr_addr, rd_addr_prev;
    wire        rd_ack, wr_ack;

    bank_switch #(
        .FB_NUM         (FB_NUM),
        .MAX_VID_WIDTH  (640),
        .MAX_VID_HIGHT  (720),
        .START_ADDR     (32'h0),
        .VID_DATA_WIDTH (32),
        .AXI_DATA_WIDTH (512)
    ) dut (
        .ddr_clk( clk ), .rst_n( rst_n ),
        .wr_sw( wr_sw ), .rd_sw( rd_sw ),
        .wr_bank( wr_bank ), .rd_bank( rd_bank ),
        .rd_sw_ack( rd_ack ), .wr_sw_ack( wr_ack ),
        .rd_start_addr( rd_addr ), .wr_start_addr( wr_addr ),
        .rd_start_addr_prev( rd_addr_prev )
    );

    integer t = 0;
    always #5 clk = ~clk;
    always @( posedge clk ) t <= t + 1;

    initial begin
        #1;
        repeat ( 8 ) @( posedge clk );
        rst_n = 1'b1;
    end

    // 写侧 10 拍一次, 读侧 5 拍一次; t%10==0 时两者同拍 -> 压同拍请求
    always @( posedge clk ) begin
        wr_sw <= ( t % 10 == 0 );
        rd_sw <= ( t % 5  == 0 );
    end

    //--------------------------------------------------------------- monitor
    integer seq [0:3];
    integer frame_ctr = 0;
    integer errors    = 0;
    integer wr_sw_cnt = 0;
    integer rd_sw_cnt = 0;
    integer chk_cnt   = 0;
    reg [1:0] wr_bank_d = 2'd0;
    reg [1:0] rd_bank_d = 2'd1;
    integer   k;

    task fail;
        input [255:0] msg;
        begin
            errors = errors + 1;
            if ( errors <= 20 ) $display("[FAIL] t=%0d %0s", t, msg);
        end
    endtask

    initial begin
        for ( k = 0; k < 4; k = k + 1 ) seq[k] = -1;
    end

    // 在 negedge 采样(此时 DUT 的寄存器已经稳定), 用"上一拍的值"判断有没有切换
    always @( negedge clk ) begin
        if ( rst_n ) begin
            // 写侧切走 -> 刚离开的那个 bank 里是一帧写满的数据
            if ( wr_bank !== wr_bank_d ) begin
                wr_sw_cnt = wr_sw_cnt + 1;
                frame_ctr = frame_ctr + 1;
                seq[wr_bank_d] = frame_ctr;
            end

            // 读侧滚动
            if ( rd_bank !== rd_bank_d ) begin
                rd_sw_cnt = rd_sw_cnt + 1;
                if ( frame_ctr >= 3 ) begin
                    chk_cnt = chk_cnt + 1;
                    // B: 读到的必须是刚写满的那一帧
                    if ( seq[rd_bank] != frame_ctr ) begin
                        $display("[FAIL] t=%0d rd_bank=%0d seq=%0d frame_ctr=%0d",
                                 t, rd_bank, seq[rd_bank], frame_ctr);
                        errors = errors + 1;
                    end
                    if ( FB_NUM == 4 ) begin
                        // C: 上一帧地址 + 帧号差 1
                        if ( rd_addr_prev != addr_of(rd_bank - 2'd1) ) begin
                            $display("[FAIL] t=%0d rd_addr_prev=%0d expect=%0d",
                                     t, rd_addr_prev, addr_of(rd_bank - 2'd1));
                            errors = errors + 1;
                        end
                        if ( seq[rd_bank] != seq[rd_bank - 2'd1] + 1 ) begin
                            $display("[FAIL] t=%0d prev bank seq=%0d cur seq=%0d",
                                     t, seq[rd_bank-2'd1], seq[rd_bank]);
                            errors = errors + 1;
                        end
                    end
                end
            end

            // A / D: 地址与 bank 号一致, 且写端不能碰读端 / 上一帧
            if ( rd_addr !== addr_of(rd_bank) ) begin
                $display("[FAIL] t=%0d rd_addr=%0d rd_bank=%0d", t, rd_addr, rd_bank);
                errors = errors + 1;
            end
            if ( wr_addr !== addr_of(wr_bank) ) begin
                $display("[FAIL] t=%0d wr_addr=%0d wr_bank=%0d", t, wr_addr, wr_bank);
                errors = errors + 1;
            end
            if ( FB_NUM >= 2 ) begin
                if ( wr_bank == rd_bank ) begin
                    $display("[FAIL] t=%0d wr_bank == rd_bank == %0d", t, wr_bank);
                    errors = errors + 1;
                end
            end
            if ( FB_NUM == 4 ) begin
                if ( wr_bank == (rd_bank - 2'd1) ) begin
                    $display("[FAIL] t=%0d wr_bank == prev bank == %0d", t, wr_bank);
                    errors = errors + 1;
                end
            end

            wr_bank_d <= wr_bank;
            rd_bank_d <= rd_bank;
        end
    end

    initial begin
        @( posedge rst_n );
        repeat ( TSTOP ) @( posedge clk );
        $display("--- FB_NUM=%0d : wr_sw=%0d rd_sw=%0d chk=%0d errors=%0d",
                 FB_NUM, wr_sw_cnt, rd_sw_cnt, chk_cnt, errors);
        if ( errors == 0 && wr_sw_cnt > 5 && rd_sw_cnt > 5 && chk_cnt > 5 )
            $display("BANK_SWITCH_%0d_RESULT PASS", FB_NUM);
        else
            $display("BANK_SWITCH_%0d_RESULT FAIL", FB_NUM);
        if ( FINISH ) $finish;
    end
endmodule

module tb_bank_switch;
    tb_one #( .FB_NUM(4), .TSTOP(4000), .FINISH(0) ) u4();
    tb_one #( .FB_NUM(3), .TSTOP(4300), .FINISH(0) ) u3();
    tb_one #( .FB_NUM(2), .TSTOP(4600), .FINISH(1) ) u2();
endmodule

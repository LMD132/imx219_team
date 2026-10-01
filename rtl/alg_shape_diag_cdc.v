// Bundled-data handshake for the low-rate shape diagnostic snapshot.
// The source holds its captured tuple until the next acknowledged request;
// only the request and acknowledgement toggles cross synchronizers.
module alg_shape_diag_cdc (
    input wire clk_src,
    input wire rst_src_n,
    input wire [9:0] i_cnt,
    input wire [15:0] i_ovf,
    input wire i_fault,
    input wire [3:0] i_reason,
    input wire i_frame_valid,
    input wire [31:0] i_slot_drop_total,
    input wire [31:0] i_fifo_full_total,
    input wire clk_dst,
    input wire rst_dst_n,
    input wire i_req,
    output reg [9:0] o_cnt,
    output reg [15:0] o_ovf,
    output reg o_fault,
    output reg [3:0] o_reason,
    output reg o_frame_valid,
    output reg [31:0] o_slot_drop_total,
    output reg [31:0] o_fifo_full_total,
    output reg o_sample_valid,
    output wire o_busy
);
    // A reset on either side abandons the in-flight exchange on both sides.
    wire rst_link_n = rst_src_n & rst_dst_n;
    reg [1:0] src_ready;
    reg [1:0] dst_ready;
    reg req_toggle;
    reg ack_toggle;
    (* async_reg = "true" *) reg [1:0] req_sync;
    (* async_reg = "true" *) reg [1:0] ack_sync;
    reg [95:0] held_tuple;
    reg pending;

    assign o_busy = pending;

    always @(posedge clk_src or negedge rst_link_n) begin
        if (!rst_link_n) begin
            src_ready <= 2'b00;
            req_sync <= 2'b00;
            ack_toggle <= 1'b0;
            held_tuple <= 96'b0;
        end else begin
            src_ready <= {src_ready[0], 1'b1};
            req_sync <= {req_sync[0], req_toggle};
            if (src_ready[1] && (req_sync[1] != ack_toggle)) begin
                held_tuple <= {i_cnt, i_ovf, i_fault, i_reason, i_frame_valid,
                               i_slot_drop_total, i_fifo_full_total};
                ack_toggle <= req_sync[1];
            end
        end
    end

    always @(posedge clk_dst or negedge rst_link_n) begin
        if (!rst_link_n) begin
            dst_ready <= 2'b00;
            ack_sync <= 2'b00;
            req_toggle <= 1'b0;
            pending <= 1'b0;
            o_cnt <= 10'b0;
            o_ovf <= 16'b0;
            o_fault <= 1'b0;
            o_reason <= 4'b0;
            o_frame_valid <= 1'b0;
            o_slot_drop_total <= 32'b0;
            o_fifo_full_total <= 32'b0;
            o_sample_valid <= 1'b0;
        end else begin
            dst_ready <= {dst_ready[0], 1'b1};
            ack_sync <= {ack_sync[0], ack_toggle};
            if (dst_ready[1]) begin
                if (pending && (ack_sync[1] == req_toggle)) begin
                    {o_cnt, o_ovf, o_fault, o_reason, o_frame_valid,
                     o_slot_drop_total, o_fifo_full_total} <= held_tuple;
                    o_sample_valid <= 1'b1;
                    pending <= 1'b0;
                end else if (!pending && i_req) begin
                    req_toggle <= ~req_toggle;
                    pending <= 1'b1;
                end
            end
        end
    end
endmodule

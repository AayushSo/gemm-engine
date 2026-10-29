`default_nettype none
/*
	Weight Controller
	Used to control RW signals for weight buffers
	Also generates w_latch signal
*/
// inst: gemm_top.sv
module weight_controller
import gemm_v1_pkg::*;
(
	input clk,rst,
	input w_valid, // weight data bus valid
	output w_stall,
	// top->weight controller bus DVS
	input wcmd_t wcmd_data,
	input wcmd_valid,
	output wcmd_stall,
	// abort logic
	input abort_req,
	output dummy_a_first,
	// systolic contorl signals
	output reg w_latch,
	output reg weight_stall,
	output w0_wen, w1_wen,
	output w0_ren, w1_ren,
	output logic w0_zero, w1_zero,
	output logic [W_AW-1:0] w0_waddr_out,w0_raddr_out,
	output logic [W_AW-1:0] w1_waddr_out,w1_raddr_out,
	input ld_go
	);



localparam PEND_DEPTH=4;

logic [W_AW:0] wptr,rptr, wptr_next; // one extra bit for parity
logic [W_AW:0] w_used;			// rows written, not yet read by bank R (0..W_DEPTH)
// The FIFO entry holds the tile's row count (ks):
// the active load needs ks for the edge-tile read window.
logic [SIZE_W:0] pend_cmd_rdata__ks;	// 1..16

// Entry is {ks, tag}
logic [SIZE_W+$bits(tag_t):0] pend_cmd_rdata;
tag_t pend_cmd_rdata__tag;

logic [$clog2(T):0] w0_ctr;		// 0 = idle, 1..16 = cycle of the current load
logic [$clog2(T):0] w0_ctr_next;
logic [S-1:0] w0_ren_dly;		// bank L read enables of the last S cycles
logic [S-1:0] w0_zero_dly;		// bank L zero's of the last S cycles
logic [W_AW:0] w_rows_avail;		// rows written, not yet read by bank L
wire ld_start;

wire pend_cmd_ren, pend_cmd_full, pend_cmd_empty;

logic [W_AW:0] w0_waddr,w1_waddr;
logic [W_AW:0] w0_raddr,w1_raddr;
logic [W_AW:0] w0_waddr_next,w1_waddr_next;
logic [W_AW:0] w0_raddr_next,w1_raddr_next;

logic [SIZE_W:0] wcmd_data__k_size;
logic abort_sig_hold_w;


sync_fifo #(.W(SIZE_W+1 + $bits(tag_t)), .DEPTH(PEND_DEPTH))
u_pend_cmd_fifo (
            .clk(clk),
            .rst(rst),
            .clr(abort_req),
            .ren(pend_cmd_ren),
            .rdata(pend_cmd_rdata),
            .wen(wcmd_valid && !wcmd_stall),
            .wdata({wcmd_data__k_size,wcmd_data.tag}),
            .full(pend_cmd_full),
            .empty(pend_cmd_empty),
            .count()
            );

assign pend_cmd_rdata__tag = pend_cmd_rdata[$bits(tag_t)-1:0];
assign pend_cmd_rdata__ks = pend_cmd_rdata[SIZE_W+$bits(tag_t):$bits(tag_t)];
assign pend_cmd_ren = (w0_ctr_next==T);	// pop out cmd
assign wcmd_data__k_size[SIZE_W] = wcmd_data.k_size == 'd0 ? 1'b1 : 1'b0; 
assign wcmd_data__k_size[SIZE_W-1:0] = wcmd_data.k_size; 

assign w0_waddr_out = w0_waddr[W_AW-1:0];
assign w1_waddr_out = w1_waddr[W_AW-1:0];
assign w0_raddr_out = w0_raddr[W_AW-1:0];
assign w1_raddr_out = w1_raddr[W_AW-1:0];

assign wcmd_stall = pend_cmd_full;

assign w_used = wptr - w1_raddr;

// Write whenever a slot is free (a beat transfers on valid & ~stall)
assign w0_wen = w_valid && !w_stall;
assign w1_wen = w_valid && !w_stall;
assign rptr = w0_raddr;

assign w_stall = (w_used == W_DEPTH) || abort_sig_hold_w;

always@(posedge clk) begin
	if (rst || abort_req) begin
		w0_ctr <= 'd0;
		w0_ren_dly <= 'd0;
		w0_zero_dly <= 'd0;
		w0_zero <= 'd0;
		wptr <= 'd0;
		w0_waddr <= 'd0;
		w1_waddr <= 'd0;
		w0_raddr <= 'd0;
		w1_raddr <= 'd0;
		w_latch <= 'd0;
		weight_stall <= 'd0;
	end
	else begin
		w0_ctr <= w0_ctr_next;
		w0_zero <= (w0_ctr_next !=0) && !w0_ren;
		w0_ren_dly <= {w0_ren_dly[S-2:0], w0_ren};
		w0_zero_dly <= {w0_zero_dly[S-2:0], w0_zero};
		wptr   <= wptr_next;
		w0_waddr <= w0_waddr_next;
		w1_waddr <= w1_waddr_next;
		w0_raddr <= w0_raddr_next;
		w1_raddr <= w1_raddr_next;
		weight_stall <= weight_stall ? ~ld_go : (w0_ctr_next == T);
		w_latch <= (w0_ctr == T);
	end
end

always@(posedge clk) begin
	if (rst) abort_sig_hold_w <= 'd0;
	else abort_sig_hold_w <= abort_sig_hold_w ? ~wcmd_valid : abort_req;
end

assign w_rows_avail = wptr - rptr;
assign ld_start = (~weight_stall || ld_go) && !pend_cmd_empty && (w_rows_avail >= pend_cmd_rdata__ks);
assign dummy_a_first = weight_stall && abort_req && (w0_ctr!=T);

assign w0_ctr_next = (w0_ctr=='d0 || w0_ctr==T) ?
			( ld_start ? 'd1 : 'd0)
			: w0_ctr+1'b1;


assign wptr_next = w0_wen ? wptr + 1'b1 : wptr;

always @* begin
	w0_waddr_next = w0_waddr;
	w1_waddr_next = w1_waddr;
	w0_raddr_next = w0_raddr;
	w1_raddr_next = w1_raddr;
	if (w0_wen) w0_waddr_next = w0_waddr + 1'b1;
	if (w1_wen) w1_waddr_next = w1_waddr + 1'b1;
	if (w0_ren) w0_raddr_next = w0_raddr + 1'b1;
	if (w1_ren) w1_raddr_next = w1_raddr + 1'b1;
end

assign w0_ren = (w0_ctr_next != 'd0) && (w0_ctr_next > T - pend_cmd_rdata__ks);
assign w1_ren = w0_ren_dly[S-1];
assign w1_zero = w0_zero_dly[S-1];


endmodule

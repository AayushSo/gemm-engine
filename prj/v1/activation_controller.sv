/*
	Activation Controller
	Used to control RW signals for act buffers
	Also generates a_first signal
*/

// inst: gemm_top.sv
module activation_controller
import gemm_v1_pkg::*;
(
	input clk,rst,
	// abort signalling
	input abort_req,
	input dummy_a_first, // WC sent out w_latch alrady, we need to send out a dummy a_first to prevent deadlock
	input a_valid, // act data bus valid/stall
	output a_stall,
	// top->act controller bus DVS
	input acmd_t acmd_data,
	input acmd_valid,
	output acmd_stall,
	// act->out controller bus DV
	output ocmd_t ocmd_data,
	output ocmd_valid,
	// systolic control signals
 	output logic [T-1:0] a_first_next,
	input weight_stall, // weights loaded
	output ld_go,
	// RAM connections
	output a0_wen, a1_wen,
	output a0_ren, a1_ren,
	output logic [A_AW-1:0] a0_waddr_out,a0_raddr_out,
	output logic [A_AW-1:0] a1_waddr_out,a1_raddr_out
	);



localparam PEND_DEPTH=4;

logic [A_AW:0] wptr,rptr, wptr_next; // one extra bit for parity
logic [A_AW:0] a_used;			// rows written, not yet read by bank B (0..A_DEPTH)
// The FIFO entry holds the tile's row count (ms):
// the active load needs ms for the edge-tile read window.
logic [SIZE_W:0] pend_cmd_rdata__ms;	// 1..16
logic ld_start;
// Entry is {ms, tag}
acmd_t pend_cmd_rdata;
tag_t pend_cmd_rdata__tag;

logic [A_AW-1:0] a0_ctr;		// 0 = idle, 1..16 = cycle of the current load
logic [A_AW-1:0] a0_ctr_next;
logic [S-1:0] a0_ren_dly;		// bank T read enables of the last S cycles
logic [A_AW:0] a_rows_avail;		// rows written, not yet read by bank T
logic [T-1:0] a_first;

wire pend_cmd_ren, pend_cmd_full, pend_cmd_empty;
wire a_first_accept;

logic [A_AW:0] a0_waddr,a1_waddr;
logic [A_AW:0] a0_raddr,a1_raddr;
logic [A_AW:0] a0_waddr_next,a1_waddr_next;
logic [A_AW:0] a0_raddr_next,a1_raddr_next;

logic [SIZE_W:0] acmd_data__m_size;
logic abort_sig_hold_a;

sync_fifo #(.W(ACMD_W), .DEPTH(PEND_DEPTH))
u_pend_cmd_fifo (
            .clk(clk),
            .rst(rst),
            .clr(abort_req),
            .ren(pend_cmd_ren),
            .rdata(pend_cmd_rdata),
            .wen(acmd_valid && !acmd_stall),
            .wdata(acmd_data),
            .full(pend_cmd_full),
            .empty(pend_cmd_empty),
            .count()
            );

assign pend_cmd_rdata__tag = pend_cmd_rdata.tag;
assign pend_cmd_rdata__ms[SIZE_W]     = pend_cmd_rdata.m_size == 'd0 ? 1'b1 : 1'b0; 
assign pend_cmd_rdata__ms[SIZE_W-1:0] = pend_cmd_rdata.m_size; 
assign ocmd_data                      = pend_cmd_rdata[OCMD_W-1:0];
assign ocmd_valid = ld_start;
assign pend_cmd_ren = (a0_ctr_next==T);	// pop out cmd

assign a0_waddr_out = a0_waddr[A_AW-1:0];
assign a1_waddr_out = a1_waddr[A_AW-1:0];
assign a0_raddr_out = a0_raddr[A_AW-1:0];
assign a1_raddr_out = a1_raddr[A_AW-1:0];

assign acmd_stall = pend_cmd_full;

assign a_used = wptr - a1_raddr;

// Write whenever a slot is free (a beat transfers on valid & ~stall)
assign a0_wen = a_valid && !a_stall;
assign a1_wen = a_valid && !a_stall;
assign rptr = a0_raddr;

assign a_stall = (a_used == A_DEPTH) || abort_sig_hold_a;


always@(posedge clk) begin
	if (rst || abort_req) begin
		a0_ctr <= 'd0;
		a0_ren_dly <= 'd0;
		wptr <= 'd0;
		a0_waddr <= 'd0;
		a1_waddr <= 'd0;
		a0_raddr <= 'd0;
		a1_raddr <= 'd0;
	end
	else begin
		a0_ctr <= a0_ctr_next;
		a0_ren_dly <= {a0_ren_dly[S-2:0], a0_ren};
		wptr   <= wptr_next;
		a0_waddr <= a0_waddr_next;
		a1_waddr <= a1_waddr_next;
		a0_raddr <= a0_raddr_next;
		a1_raddr <= a1_raddr_next;
	end
end

// abort signal handling
always@(posedge clk) begin
	if (rst) begin
		a_first <= 'd0;
		abort_sig_hold_a <= 'd0;
	end
	else  begin
		a_first <= a_first_next; // not cleared on abort; should flush out pending a_firsts/ dummy firsts to prevent SA deadlocking
		abort_sig_hold_a <= abort_sig_hold_a ? !acmd_valid : abort_req;
	end
end

assign a_first_accept = ld_start;
assign a_first_next = {a_first[T-2:0],a_first_accept || dummy_a_first};


assign ld_go = a_first_accept;
assign ld_start = weight_stall & !pend_cmd_empty & (a_rows_avail >= pend_cmd_rdata__ms) & (a0_ctr=='d0 || a0_ctr==T) & !abort_req;
assign a_rows_avail = wptr - rptr;

assign a0_ctr_next = (a0_ctr=='d0 || a0_ctr==T) ?
			( ld_start ? 'd1 : 'd0)
			: a0_ctr+1'b1;


assign wptr_next = a0_wen ? wptr + 1'b1 : wptr;

always @* begin
	a0_waddr_next = a0_waddr;
	a1_waddr_next = a1_waddr;
	a0_raddr_next = a0_raddr;
	a1_raddr_next = a1_raddr;
	if (a0_wen) a0_waddr_next = a0_waddr + 1'b1;
	if (a1_wen) a1_waddr_next = a1_waddr + 1'b1;
	if (a0_ren) a0_raddr_next = a0_raddr + 1'b1;
	if (a1_ren) a1_raddr_next = a1_raddr + 1'b1;
end

assign a0_ren = (a0_ctr_next != 'd0) && (a0_ctr_next <=  pend_cmd_rdata__ms);
assign a1_ren = a0_ren_dly[S-1];



endmodule

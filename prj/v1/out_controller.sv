/*
	Output Controller
	Used to control RW signals for accumulator buffers
	Also generates c_valid signal
*/

// inst: gemm_top.sv
module out_controller
import gemm_v1_pkg::*;
(
	input clk,rst,
	input abort_req,
	// AC->OC DV bus intf
	input ocmd_t ocmd_data,
	input ocmd_valid,
	// Output valid
	output reg c0_valid,
	output reg c1_valid,
	// out ack
	output out_ack,
	output reg c0_first, c1_first, // psum = SA_out + (cX_first ? 'd0 : SRAM_out);
	output reg c0_oen, c1_oen, // write out to upsteam buffers
	// SRAM intf
	output reg c0_wen, c1_wen,
	output c0_ren, c1_ren,
	output [ACC_AW-1:0] c0_waddr,c0_raddr,
	output [ACC_AW-1:0] c1_waddr,c1_raddr
	);

localparam PEND_DEPTH=4;

ocmd_t pend_cmd_rdata, c1_pend_ocmd;
wire pend_cmd_ren, pend_cmd_full, pend_cmd_empty;
wire ld_start;

reg [OC_RD_START-1:0] go_dly;
logic [$clog2(T):0] c0_ctr,c0_ctr_next;
logic [S-1:0] c0_ren_dly;

logic [ACC_AW-1:0] c0_row, c1_row;		// read-stage row index
logic [ACC_AW-1:0] c0_row_q, c1_row_q;		// sum-stage row index (ACC write address)
logic c0_oen_rd, c1_oen_rd;			// read stage: this row is an output row
logic c0_ack_rd, c1_ack_rd;			// read stage: last output row of the GEMM
logic c0_ack_q, c1_ack_q;
reg   out_ack_q;

//function automatic logic row_in(input size_t m, input logic [ACC_AW-1:0] x);
//	return (m == 'd0) || (x < m);		// row x < m-size
//endfunction
//function automatic logic n_hi(input size_t n);
//	return ((n == 'd0) || (n > S));		// n-size > S: bank 1 has output columns
//endfunction

sync_fifo #(.W(OCMD_W), .DEPTH(PEND_DEPTH))
u_pend_cmd_fifo (
            .clk(clk),
            .rst(rst),
            .clr(abort_req),
            .ren(pend_cmd_ren),
            .rdata(pend_cmd_rdata),
            .wen(ocmd_valid),
            .wdata(ocmd_data),
            .full(pend_cmd_full),
            .empty(pend_cmd_empty),
            .count()
            );

assign pend_cmd_ren = c0_ctr_next ==T;

always@(posedge clk) begin
	if (rst || abort_req) begin
		go_dly <= 'd0;
		c1_pend_ocmd <= 'd0;
		c0_ctr <= 'd0;
		c0_ren_dly <= 'd0;
		c0_wen <= 'd0;
		c1_wen <= 'd0;
		c0_valid <= 'd0;
		c1_valid <= 'd0;
		c1_row <= 'd0;
		c0_row_q <= 'd0;
		c1_row_q <= 'd0;
		c0_first <= 'd0;
		c1_first <= 'd0;
		c0_oen <= 'd0;
		c1_oen <= 'd0;
		c0_ack_q <= 'd0;
		c1_ack_q <= 'd0;
		out_ack_q <= 'd0;
	end
	else begin
		go_dly <= {go_dly[OC_RD_START-2:0],ocmd_valid};
		c1_pend_ocmd <= c0_ctr_next==S ? pend_cmd_rdata : c1_pend_ocmd;
		c0_ctr <= c0_ctr_next;
		c0_ren_dly <= {c0_ren_dly[S-2:0],c0_ren};
		c0_wen <= ~pend_cmd_rdata.last && c0_ren;
		c1_wen <= c1_ren && ~c1_pend_ocmd.last;
		c0_valid <= c0_oen;
		c1_valid <= c1_oen;
		// read stage -> sum stage
		c0_row_q <= c0_row;
		c1_row_q <= c1_row;
		c0_first <= pend_cmd_rdata.first;
		c1_first <= c1_pend_ocmd.first;
		c0_oen   <= c0_oen_rd;
		c1_oen   <= c1_oen_rd;
		c0_ack_q <= c0_ack_rd;
		c1_ack_q <= c1_ack_rd;
		out_ack_q <= c0_ack_q || c1_ack_q;	
		c1_row <= c1_row + c1_ren;
	end
end

assign c0_row    = ACC_AW'(c0_ctr_next - 1'b1);	// c0_ctr_next = 1..16 in the read stage
//assign c0_oen_rd = c0_ren && pend_cmd_rdata.last && row_in(pend_cmd_rdata.m_size, c0_row);
assign c0_oen_rd = c0_ren 
			&& pend_cmd_rdata.last 
			&& ((pend_cmd_rdata.m_size == 'd0) || (c0_row < pend_cmd_rdata.m_size));
//assign c0_ack_rd = c0_oen_rd && pend_cmd_rdata.gemm_last && !n_hi(pend_cmd_rdata.n_size)
//		&& (c0_row == ACC_AW'(pend_cmd_rdata.m_size - 1'b1));
assign c0_ack_rd = c0_oen_rd 
		&& pend_cmd_rdata.gemm_last 
		&& !((pend_cmd_rdata.n_size == 'd0) || (pend_cmd_rdata.n_size > S)) 
		&&  (c0_row == ACC_AW'(pend_cmd_rdata.m_size - 1'b1));
//assign c1_oen_rd = c1_ren && c1_pend_ocmd.last && row_in(c1_pend_ocmd.m_size, c1_row) && n_hi(c1_pend_ocmd.n_size);
assign c1_oen_rd = c1_ren 
		&& c1_pend_ocmd.last 
		&& ((c1_pend_ocmd.m_size == 'd0) || (c1_row < c1_pend_ocmd.m_size))
		&& ((c1_pend_ocmd.n_size == 'd0) || (c1_pend_ocmd.n_size > S)); 
		//&& n_hi(c1_pend_ocmd.n_size);
assign c1_ack_rd = c1_oen_rd 
		&& c1_pend_ocmd.gemm_last
		&& (c1_row == ACC_AW'(c1_pend_ocmd.m_size - 1'b1));

assign ld_start = go_dly[OC_RD_START-1];
assign c0_ctr_next = (c0_ctr=='d0 || c0_ctr==T) ?
                        ( ld_start ? 'd1 : 'd0)
                        : c0_ctr+1'b1;

assign out_ack = out_ack_q;

assign c0_ren = (c0_ctr_next != 'd0);
assign c1_ren = c0_ren_dly[S-1];
assign c0_raddr = c0_row;
assign c1_raddr = c1_row;
assign c0_waddr = c0_row_q;
assign c1_waddr = c1_row_q;

endmodule

/*
	Top Controller
	Controls sub controllers:
	* Weight Contorller
	* Act Contorller
	* Out Controller
Command list:
	1. Load weights : weight size
Responses (spec §9.6):
	* accept : {ID, 0, warnings}, sent when the descriptor is taken
	* end    : {ID, 1, OK} on out_ack (in order), or {ID, 1, ABORTED} for every outstanding ID on abort
	Outstanding IDs (running + issued, waiting for out_ack) are held in a FIFO, pushed at accept.
*/

// inst gemm_top.sv
module top_controller
import gemm_v1_pkg::*;
(
	input clk,rst,
	// command input bus DVS
	input cmd_t cmd_data,
	input cmd_valid,
	output cmd_stall,
	// weight controller bus DVS
	output wcmd_t wcmd_data,
	output reg wcmd_valid,
	input wcmd_stall,
	// act controller bus DVS
	output acmd_t acmd_data,
	output reg acmd_valid,
	input acmd_stall,
	// ack bus DV
	output resp_t resp_data,
	output reg resp_valid,
	input abort_req,
	// out controller bus
	input out_ack
	//input id_t out_id
	);


// parameters
localparam ST_INIT = 3'd0, ST_M = 3'd1, ST_N = 3'd2, ST_K = 3'd3,
		ST_ABORT = 3'd4;
localparam PEND_DEPTH = 4;	// max outstanding GEMMs (running + waiting for out_ack)

reg [TILE_CNT_W-1:0] cmd_N,cmd_N_next; // one extra for overflow bit already accounted for in TILE_CNT_W
reg [TILE_CNT_W-1:0] cmd_M,cmd_M_next;
reg [TILE_CNT_W-1:0] cmd_K,cmd_K_next;

reg [2:0] state, state_next;
wire loop_k_end, loop_n_end, loop_m_end;
wire loop_k_end_gt0, loop_n_end_gt0, loop_m_end_gt0;

reg  resp_valid_next;

tag_t tag,tag_next;
cmd_t cmd_r,cmd_r_next;
resp_t resp_data_next;

wire pend_ren;
id_t pend_rdata;
reg  pend_wen;
wire pend_full;
wire pend_empty;

reg ack_hold;		// out_ack that collided with an accept, sent one cycle later
wire ack_req, ack_go;
resp_t ack_resp;

always@(posedge clk) begin
	if (rst) begin
		state <= ST_INIT;
		cmd_N <= 'd0;
		cmd_M <= 'd0;
		cmd_K <= 'd0;
		cmd_r <= 'd0;
		tag   <= 'd0;
	end
	else begin
		state <= state_next;
		cmd_N <= cmd_N_next;
		cmd_M <= cmd_M_next;
		cmd_K <= cmd_K_next;
		cmd_r <= cmd_r_next;
		tag   <= tag_next;
	end
end

always@* begin
	state_next = state;
	cmd_N_next = cmd_N;
	cmd_M_next = cmd_M;
	cmd_K_next = cmd_K;
	cmd_r_next = cmd_r;
	tag_next   = tag;
	wcmd_valid = 1'b0;
	acmd_valid = 1'b0;
	pend_wen   = 1'b0;
	resp_data_next.id = cmd_r.id;
	resp_data_next.done = 'd0;
	resp_data_next.info = 'd0;
	resp_valid_next = 1'b0;
	case(state)
		ST_INIT : begin
				if (cmd_valid && !pend_full) begin // pend_full is part of cmd_stall
					state_next = ST_K;
					cmd_r_next = cmd_data;
					cmd_M_next = 'd1;
					cmd_N_next = 'd1;
					cmd_K_next = 'd1; // optimization -> we can jump directly to ST_K since ST_M/N just initialize those 2 counters to 1
					resp_data_next.info[RESP__INFO_WARN_M] =~|cmd_data.m;
					resp_data_next.info[RESP__INFO_WARN_N] =~|cmd_data.n;
					resp_data_next.info[RESP__INFO_WARN_K] =~|cmd_data.k;
					resp_data_next.id = cmd_data.id;
					resp_valid_next = 1'b1;
					pend_wen = 1'b1;	// outstanding until out_ack or abort
				end
			end
		ST_M : begin
				state_next = ST_N;
				cmd_N_next = 'd1;
			end
		ST_N : begin
				state_next = ST_K;
				cmd_K_next = 'd1;
			end
		ST_K : begin
				wcmd_valid = 1'b1;
				acmd_valid = 1'b1;
				if (!wcmd_stall &~ acmd_stall) begin
					tag_next   = tag + 1'b1;
					cmd_K_next = cmd_K + 'd1;
					if (loop_k_end) begin // inner loop completed
						// check second loop
						cmd_N_next = cmd_N + 1'b1;
						state_next = ST_N;
						if (loop_n_end) begin // second loop completed
							cmd_M_next = cmd_M + 1'b1;
							state_next = ST_M;
							if (loop_m_end)  begin // GEMM completed (end response comes on out_ack)
								state_next = ST_INIT;
							end
						end
					end // inner loop
				end // if !wcmd_stall
			end
		ST_ABORT : begin // one aborted response per outstanding ID, one per cycle, in order
				cmd_r_next = 'd0;
				if (pend_empty) state_next = ST_INIT;
				else begin
					resp_data_next.done = 1'b1;
					resp_data_next.info = RESP__INFO_ST_ABORTED; // aborted
					resp_data_next.id = pend_rdata;
					resp_valid_next = 1'b1;
				end
			end
		default : state_next = ST_INIT;
	endcase
	// a descriptor accepted in the abort cycle is aborted too
	if (abort_req & (!pend_empty | pend_wen)) state_next = ST_ABORT;
end


assign cmd_stall = (state != ST_INIT)|| pend_full;

// loop end flags

assign loop_k_end_gt0 =  ( (cmd_K == TILE_CNT_W'(cmd_r.k>>SIZE_W))  &~ (|cmd_r.k[SIZE_W-1:0])  )
			|| (cmd_K > TILE_CNT_W'(cmd_r.k>>SIZE_W));

assign loop_n_end_gt0 =  ( (cmd_N == TILE_CNT_W'(cmd_r.n>>SIZE_W))  &~ (|cmd_r.n[SIZE_W-1:0])  )
			|| (cmd_N > TILE_CNT_W'(cmd_r.n>>SIZE_W));
assign loop_m_end_gt0 = ( (cmd_M == TILE_CNT_W'(cmd_r.m>>SIZE_W))  &~ (|cmd_r.m[SIZE_W-1:0])  )
			|| (cmd_M > TILE_CNT_W'(cmd_r.m>>SIZE_W));

assign loop_k_end = (cmd_r.k=='d0) ? cmd_K[TILE_CNT_W-1]==1'b1 : loop_k_end_gt0;
assign loop_n_end = (cmd_r.n=='d0) ? cmd_N[TILE_CNT_W-1]==1'b1 : loop_n_end_gt0;
assign loop_m_end = (cmd_r.m=='d0) ? cmd_M[TILE_CNT_W-1]==1'b1 : loop_m_end_gt0;

// output packet formation

assign wcmd_data.k_size = loop_k_end  ? cmd_r.k[SIZE_W-1:0] : 'd0;
assign wcmd_data.n_size = loop_n_end  ? cmd_r.n[SIZE_W-1:0] : 'd0;
assign wcmd_data.tag = tag;

assign acmd_data.k_size = loop_k_end  ? cmd_r.k[SIZE_W-1:0] : 'd0;
assign acmd_data.m_size = loop_m_end  ? cmd_r.m[SIZE_W-1:0] : 'd0;
assign acmd_data.tag = tag;
// added ocmd packets
assign acmd_data.first = cmd_K==1;
assign acmd_data.last = loop_k_end;
assign acmd_data.gemm_last = loop_k_end && loop_m_end && loop_n_end;
assign acmd_data.n_size = loop_n_end  ? cmd_r.n[SIZE_W-1:0] : 'd0;
assign acmd_data.id = cmd_r.id;
assign acmd_data.r_first = cmd_M == 'd1;
assign acmd_data.r_last  = loop_m_end;
assign acmd_data.n_first = cmd_N == 'd1;
assign acmd_data.n_last  = loop_n_end;

// Pending response FIFO: IDs of outstanding GEMMs, oldest at the head

/* verilator lint_off PINCONNECTEMPTY */
sync_fifo #(.W(ID_W),.DEPTH(PEND_DEPTH))
u_pend_resp_fifo (
	.clk(clk),
	.rst(rst),
	.clr(1'b0),
	.ren(pend_ren),
	.rdata(pend_rdata),
	.wen(pend_wen),
	.wdata(cmd_data.id),
	.full(pend_full),
	.empty(pend_empty),
	.count()
	);
/* verilator lint_on PINCONNECTEMPTY */

// Response packing
// FSM responses (accept, aborted) take the bus first. An out_ack that collides with an accept is
// held one cycle (accepts are only taken in ST_INIT, so the next cycle is free). out_ack during the
// abort drain is ignored: the head is reported as aborted instead.
assign ack_req = (out_ack || ack_hold) && (state != ST_ABORT);
assign ack_go  = ack_req && !resp_valid_next;

assign ack_resp.id   = pend_rdata;
assign ack_resp.done = 1'b1;
assign ack_resp.info = RESP__INFO_ST_OK;

// pop in the same cycle the head is reported
assign pend_ren = ack_go || (state == ST_ABORT && !pend_empty);

always@(posedge clk) begin
	if (rst) begin
		resp_data <= 'd0;
		resp_valid <= 'd0;
		ack_hold <= 'd0;
	end
	else begin
		resp_valid <= resp_valid_next || ack_go;
		if (resp_valid_next) resp_data <= resp_data_next;
		else if (ack_go)     resp_data <= ack_resp;
		ack_hold <= ack_req && resp_valid_next;
	end
end

`ifndef SYNTHESIS
always@(posedge clk) begin
	if (!rst) begin
		if (pend_wen && (~|cmd_data.m || ~|cmd_data.k || ~|cmd_data.n))
			$warning("top_controller: GEMM %0d accepted with a 0 field (runs as 65536): M=%0d K=%0d N=%0d",
				cmd_data.id, cmd_data.m, cmd_data.k, cmd_data.n);
		if (out_ack && state != ST_ABORT && pend_empty)
			$error("top_controller: out_ack with no outstanding GEMM");
		if (out_ack && ack_hold)
			$error("top_controller: out_ack while the previous one is still held");
	end
end
`endif

endmodule

/*
Sync FIFO - single-clock FIFO, flop-based

For small control queues (a few entries). Large data buffers use ram_1r1w.

Input :
	clk, rst
	clr        : synchronous flush (drops all entries)
	write port : wen, wdata
	read port  : ren

Output :
	rdata, full, empty, count (entries held)

Behaviour:
	1. Write when wen & !full, read (pop) when ren & !empty; both may happen in the same cycle.
	   A write while full and a read while empty are ignored.
	2. First-word fall-through: rdata shows the head entry whenever empty = 0 (no read latency);
	   ren pops it. rdata is undefined while empty = 1.
	3. full and empty come from registered state: no combinational path from wen or ren.
	   A full FIFO therefore ignores a write even in a cycle that reads.
	4. Any DEPTH >= 1: pointers wrap explicitly, so DEPTH need not be a power of 2.
	5. clr has priority over write and read. rst and clr clear pointers and count only; the
	   storage has no reset.
*/


module sync_fifo
# (
	W     = 8,				// entry width (bits)
	DEPTH = 4,				// entries
	AW    = (DEPTH > 1) ? $clog2(DEPTH) : 1,	// pointer width - derived, do not override
	CW    = $clog2(DEPTH+1)		// count width - derived, do not override
	)
(
	input clk, rst,
	input clr,
	// write port
	input			wen,
	input	   [W-1:0]	wdata,
	output			full,
	// read port
	input			ren,
	output	   [W-1:0]	rdata,
	output			empty,
	output reg [CW-1:0]	count
);

`ifndef SYNTHESIS
initial if (DEPTH < 1) $fatal(1, "sync_fifo: DEPTH must be >= 1 (got %0d)", DEPTH);
`endif

reg [W-1:0]  mem [0:DEPTH-1];
reg [AW-1:0] wptr, rptr;

wire push = wen & ~full;
wire pop  = ren & ~empty;

assign full  = (count == CW'(DEPTH));
assign empty = (count == 'd0);
assign rdata = mem[rptr];

function automatic [AW-1:0] ptr_inc(input [AW-1:0] p);
	ptr_inc = (p == AW'(DEPTH-1)) ? 'd0 : p + 1'b1;
endfunction

// storage
always@(posedge clk) begin
	if (push) mem[wptr] <= wdata;
end

// pointers and count
always@(posedge clk) begin
	if (rst || clr) begin
		wptr  <= 'd0;
		rptr  <= 'd0;
		count <= 'd0;
	end
	else begin
		if (push) wptr <= ptr_inc(wptr);
		if (pop)  rptr <= ptr_inc(rptr);
		case ({push,pop})
			2'b10   : count <= count + 1'b1;
			2'b01   : count <= count - 1'b1;
			default : ;
		endcase
	end
end

endmodule

/*
RAM 1R1W - simple dual-port memory wrapper (behavioral model)

One write port and one read port, both on clk. Every buffer in the design
instantiates this module, so that the behavioral model can later be swapped
for an SRAM macro (e.g. sky130 OpenRAM 1RW+1R: RW port used as write-only)
without touching the instantiating logic.

Input :
	clk
	write port : we, waddr, wmask (per element), wdata
	read port  : re, raddr

Output :
	rdata (registered, valid one cycle after re)

Behaviour:
	1. Synchronous read, 1-cycle latency: re/raddr at edge t -> rdata valid after edge t+1.
	   rdata holds its value while re = 0.
	2. A word is NE elements of EW bits. wmask[i] = 1 writes element i of the word;
	   masked-off elements keep their old value. Use NE=1 for plain whole-word writes.
	3. Read-during-write to the same address (re & we & raddr==waddr, any wmask bit set):
	   RDW_X = 0 : rdata returns the OLD data (read-first)
	   RDW_X = 1 : rdata returns X (simulation only) - use to prove the design never
	               depends on read-during-write, as a real macro may leave it undefined.
	4. No reset: contents and rdata start as X, like a real SRAM. Preload in simulation
	   with INIT_FILE ($readmemh) or by backdoor through the hierarchy (u_ram.mem[a]).
	5. Out-of-range addresses (DEPTH not a power of 2): writes are dropped, reads return X.

Assumptions:
	1. Single clock domain for both ports.
*/


module ram_1r1w
# (
	EW        = 8,			// element width (bits)
	NE        = 8,			// elements per word
	DEPTH     = 256,		// words
	RDW_X     = 0,			// read-during-write: 0 = old data, 1 = X
	INIT_FILE = "",			// optional $readmemh preload (simulation)
	DW        = EW*NE,		// word width - derived, do not override
	AW        = (DEPTH > 1) ? $clog2(DEPTH) : 1	// address width - derived, do not override
	)
(
	input clk,
	// write port
	input			we,
	input	   [AW-1:0]	waddr,
	input	   [NE-1:0]	wmask,
	input	   [DW-1:0]	wdata,
	// read port
	input			re,
	input	   [AW-1:0]	raddr,
	output reg [DW-1:0]	rdata
);

reg [DW-1:0] mem [0:DEPTH-1];

wire rdw_hit = re & we & (|wmask) & (raddr == waddr);

initial begin
	if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
end

// write port
integer i;
always@(posedge clk) begin
	if (we) begin
		for (i=0;i<NE;i++) begin
			if (wmask[i]) mem[waddr][i*EW +: EW] <= wdata[i*EW +: EW];
		end
	end
end

// read port
always@(posedge clk) begin
	if (re) rdata <= (RDW_X != 0 && rdw_hit) ? {DW{1'bx}} : mem[raddr];
end

endmodule

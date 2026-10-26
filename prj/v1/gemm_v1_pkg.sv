/*
GEMM engine v1 - project package

Project-wide constants for v1 (see docs/spec.md). Import it in prj/v1 modules
and pass the values down to rtl/ modules as parameters; nothing in rtl/ may
import this package.

Fixed v1 configuration:
	* int8 x int8 inputs, int32 accumulator / C output (spec §3)
	* one 16x16 array, handled as two 8-lane halves (spec §5)
	* R = 16 rows per pass, accumulator depth = R (spec §8)
	* A/B bank depth 32 rows (spec §7.2)
	* descriptor, pass-command and status encodings (spec §9.2, §9.3, §9.6)
*/


package gemm_v1_pkg;

// ---- data widths ----
localparam int IN_W  = 8;		// A, B element width (signed)
localparam int ACC_W = 32;		// accumulator / C element width (signed)

// ---- array geometry ----
localparam int S     = 8;		// core size 
localparam int GRID  = 2;		// cores per side
localparam int NBANK = 2;		// banks per path
localparam int T     = GRID*S;		// logical array size
localparam int LANES = S;		// lanes per bank

// ---- pass / accumulator ----
localparam int R         = 16;		// rows of A per pass
localparam int ACC_DEPTH = R;		// accumulator words per bank

// ---- input banks (ring buffers, one row per word) ----
// 25 rows is the floor for full rate (16 + 8 for the late bank's read offset, +1 since a slot
// can't be rewritten in the cycle it is read); 32 adds pause margin and wraps without a compare.
localparam int W_DEPTH = 32;			// B (weight) rows per bank
localparam int W_AW    = $clog2(W_DEPTH);	// 5
localparam int A_DEPTH = 32;			// A (activation) rows per bank
localparam int A_AW    = $clog2(A_DEPTH);	// 5

// ---- psum widths ----
// Exact signed width for a D-deep column of IN_W x IN_W products:
// worst case D*(-2^(IN_W-1))^2 = D*2^(2*IN_W-2)  ->  2*IN_W + floor(log2 D) bits.
function automatic int psum_w(input int depth);
	return 2*IN_W + $clog2(depth+1) - 1;	// $clog2(D+1)-1 = floor(log2 D)
endfunction

//localparam int PSUM_TOP_W = psum_w(S);	// 19: top cores, 8-deep
//localparam int PSUM_BOT_W = psum_w(T);	// 20: bottom cores, 16-deep
localparam int PSUM_W = psum_w(T);	// worst case width

// ---- overflow bound ----
// |C| <= K*2^(2*IN_W-2) must fit in ACC_W-bit signed: K <= 131071 for int8/int32.
// The DIM_W-bit K field (max 2^DIM_W = 65536) stays below it (spec §9.2).
localparam longint K_MAX = ((64'sd1 <<< (ACC_W-1)) - 1) / (64'sd1 <<< (2*IN_W-2));

// ---- GEMM descriptor (spec §9.2) ----
// M, K, N in elements; a field value of 0 encodes 2^DIM_W.
localparam int DIM_W     = 16;			// M, K, N field width
localparam int SIZE_W    = $clog2(T);		// 4: low bits of a dimension = edge-tile size
localparam int TILE_CNT_W = DIM_W - SIZE_W + 1;	// 13: tile count, up to 2^DIM_W / T = 4096

// ---- pass commands (spec §9.3) ----
// Tile sizes are SIZE_W bits with 0 = T (full tile).
localparam int TAG_W = 3;			// pass index mod 8 (about 4 passes alive)

// ---- cmd / resp field widths ----
localparam int ID_W   = 4;			// host-chosen job tag, echoed in resp
localparam int INFO_W = 3;			// resp info: warnings or status

// ---- field types ----
typedef logic [DIM_W-1:0]  dim_t;		// M, K or N (0 = 2^DIM_W)
typedef logic [SIZE_W-1:0] size_t;		// tile size (0 = T)
typedef logic [TAG_W-1:0]  tag_t;
typedef logic [ID_W-1:0]   id_t;

// ---- bus layouts (packed: first field = MSBs) ----
// cmd bus, DVS in (spec §9.2)
typedef struct packed {
	id_t	id;
	dim_t	m;
	dim_t	k;
	dim_t	n;
} cmd_t;

// resp bus, DV out (spec §9.6)
// done = 0: accept, info = warnings; done = 1: end, info[STATUS_W-1:0] = status
typedef struct packed {
	id_t			id;
	logic			done;
	logic [INFO_W-1:0]	info;
} resp_t;

// TC -> WC pass command (spec §9.3)
typedef struct packed {
	size_t	k_size;		// B tile rows
	size_t	n_size;		// B tile columns
	tag_t	tag;
} wcmd_t;

// TC -> AC pass command
typedef struct packed {
	size_t	k_size;		// A tile columns
	size_t	m_size;		// A tile rows
	tag_t	tag;
} acmd_t;

// TC -> OC pass command (delayed to match the psums)
typedef struct packed {
	logic	first;		// k == 0: no ACC fetch, add 0
	logic	last;		// last k: result to C out, no write-back
	logic	gemm_last;	// final pass of the GEMM: ack TC once its last C row has left
	size_t	m_size;		// rows to output
	size_t	n_size;		// columns to output
	id_t	id;		// GEMM ID, returned on the OC -> TC ack
	tag_t	tag;
} ocmd_t;

localparam int CMD_W  = $bits(cmd_t);		// 52
localparam int RESP_W = $bits(resp_t);		// 8
localparam int OCMD_W = $bits(ocmd_t);		// 18

// accept warnings: bit positions in info
localparam int RESP__INFO_WARN_M = 0;		// M field = 0 (runs as 2^DIM_W)
localparam int RESP__INFO_WARN_K = 1;		// K field = 0
localparam int RESP__INFO_WARN_N = 2;		// N field = 0

// end status: info[STATUS_W-1:0], upper info bits 0
localparam int STATUS_W = 3;
localparam logic [STATUS_W-1:0] RESP__INFO_ST_OK         = 'd0;
// codes 1 and 2 reserved (future error reporting, spec §9.6)
localparam logic [STATUS_W-1:0] RESP__INFO_ST_ABORTED    = 'd3;

// ---- bank word widths ----
localparam int IN_WORD_W  = LANES*IN_W;		// A/B bank word: 64 bits
localparam int ACC_WORD_W = LANES*ACC_W;	// accumulator bank word: 256 bits

// ---- element types ----
typedef logic signed [IN_W-1:0]  in_t;
typedef logic signed [ACC_W-1:0] acc_t;

endpackage

/*
Systolic array
based on PE units matrixed together

Input :
	a (left stream vector, skewed)
	weight (top stream vector, skewed)
	clk, rst
	Contorl signals:
		* a_first
		* w_latch

Output :
	c_out (partial sum output to bottom PE)


Assumptions:
	1. partial sums cannot overflow/ no means to capture overflow
	2. signed integer inputs/outputs
*/


module systolic
# (
	M     = 3,  // sys arr size 
	NA    = 4,  // weight bitlength (per)
	NPIN  = 9   // psum bitlength (per ele)
	)
(
	input clk, rst,
	input signed 	[NA-1:0]	a [M-1:0],
	input signed 	[NA-1:0]	b [M-1:0],
	input signed	[NPIN-1:0]	p [M-1:0], // input partial sum, usually tied to 0
	input		[M-1:0]		a_first,
	input		[M-1:0]		w_latch,
	output signed	[NPIN-1:0]	c [M-1:0]
);

wire signed [NA-1:0] 		a_in 		[M-1:0][M-1:0];
wire        			a_first_in 	[M-1:0][M-1:0];
wire        			w_latch_in 	[M-1:0][M-1:0];
wire signed [NA-1:0]		b_in 		[M-1:0][M-1:0];
wire signed [NPIN-1:0]		p_in 		[M-1:0][M-1:0];
wire signed [NPIN-1:0]		p_out		[M-1:0][M-1:0];
wire signed [NA-1:0]		a_out		[M-1:0][M-1:0];
wire        			a_first_out	[M-1:0][M-1:0];
wire signed [NA-1:0]		b_out 		[M-1:0][M-1:0];
wire        			w_latch_out 	[M-1:0][M-1:0];


genvar i,j;

generate
	for (i=0;i<M;i++) begin // col select
		// output assignment
		assign c[i] = p_out[i][M-1];

		for (j=0;j<M;j++) begin // row select
			assign a_in[i][j] 	= (i==0) ? a[j] : a_out[i-1][j];
			assign a_first_in[i][j]	= (i==0) ? a_first[j] : a_first_out[i-1][j];
			assign w_latch_in[i][j]	= (i==0) ? w_latch[j] : w_latch_out[i-1][j];
			assign b_in[i][j]	= (j==0) ? b[i] : b_out[i][j-1];
			assign p_in[i][j]	= (j==0) ? p[i] : p_out[i][j-1];
			
			pe #(.NA(NA), .NPIN(NPIN), .NPOUT(NPIN))
			u_pe (			// PE [i][j]
				.clk		(clk),
				.rst		(rst),
				.a		(a_in[i][j]),
				.a_first	(a_first_in[i][j]),
				.w_latch	(w_latch_in[i][j]),
				.b		(b_in[i][j]),
				.p_in		(p_in[i][j]),	
				.p_out		(p_out[i][j]),
				.a_out		(a_out[i][j]),
				.a_first_out	(a_first_out[i][j]),
				.b_out		(b_out[i][j]),
				.w_latch_out    (w_latch_out[i][j])
				);
		end
	end
endgenerate


endmodule






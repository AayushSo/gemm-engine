/*
	Skew buffer.
Used to generate increasing / decreasing buffers.
	* Increasing buffer mode : first col has 1 buffer, 2nd has 2 chained, and so on
	* Decreasing buffer mode : last col has 1 buffer, 2nd last has 2 chained and so on
	* When START_Z=1, one less row of buffers is instantiated (firt col has 0 , 2nd has 1 etc. in INCR mode,  last col has 0, 2nd last has 1 when INCR=0)
Each buffer is N-bit wide.

*/

module skew #(
	parameter N=8, // number of columns
	parameter W=8, // bitwidth per element
	parameter INCR=1, // buffers are increasing
	parameter START_Z=1 // if ==1 -> first col has 0 bufferm next has 1 and so on (each col has 1 less buffer)
	)
(
	input clk, rst,
	input [W-1:0]  x [N-1:0],
	output [W-1:0] y [N-1:0]
	);


genvar j;
generate
	if (INCR) begin : gen_skew_incr
		for (j=0;j<N;j++) 
			delay_line #(.D(j+1-START_Z), .W(W))
				u_d (. clk(clk), .rst(rst), .x(x[j]), .y(y[j]));
	end
	else begin : gen_skew_decr
		for (j=0;j<N;j++) 
			delay_line #(.D(N-j-START_Z), .W(W))
				u_d (. clk(clk), .rst(rst), .x(x[j]), .y(y[j]));
	end
endgenerate

endmodule

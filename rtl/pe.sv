/*
PE - Processing element


Input :
        a (left stream vector, skewed)
        weight (top stream vector, skewed)
        p_in (partial sum input from top PE)
        clk, rst
        Contorl signals:
                * a_first
                * w_latch

Output :
        a_out (left steam going to next right-hand PE)
        p_out (partial sum output to bottom PE)
        b_out (weight to bottom PE)
        control signals - a_first_out, w_latch_out

TODO:
	1. [DONE] also to add a secondary weight buffer so we can switch
	   weights on-the-fly.
	2. [DONE] weight update logic - global flag? -> no, use w_latch/ a_first signals that propagate 

Assumptions:
	1. partial sums cannot overflow/ no means to capture overflow
	2. signed integer inputs/outputs
*/


module pe
# (
	NA    = 4,
	NPIN  = 8,
	NPOUT = 8)
(
	input clk, rst,
	input      signed [NA-1:0]    a,	// left streaming input
	input		  	      a_first,	// first straming input of a new matrix
	input		  	      w_latch,	// hols weight signal 
	input      signed [NA-1:0]    b,	// left streaming input
	input      signed [NPIN-1:0]  p_in, 	// partial sum streaming input
	output reg signed [NPOUT-1:0] p_out,	// partial sum output
	output reg signed [NA-1:0]    a_out,	// activation out
	output reg 	  	      a_first_out,	// first flag transfer
	output     signed [NA-1:0]    b_out, 	// weight output 
	output reg	  	      w_latch_out	// hols weight signal out 
);

reg signed [NA-1:0] weight0, weight1;
reg weight_flag;  // which buffer to select?
reg weight_upd;   // which buffer to update?
reg weight_lock;  // should buffer values be held or be updated?

//wire signed [NA-1:0] a_out_next;
wire signed [NPOUT-1:0] p_out_next;
//wire signed [NPOUT-1:0] b_out_valid_next;
wire signed [NA-1:0] weight0_next, weight1_next, weight_opt;
wire signed [NPOUT-1:0] p_mul;
wire weight_flag_next;
wire weight_upd_next;
wire weight_lock_next;

always@(posedge clk) begin
	if (rst) begin
		a_out       <= 'd0;
		a_first_out <= 'd0;
		p_out       <= 'd0;
		weight_flag <= 'b1;
		weight_upd  <= 'b0;
		weight0     <= 'd0;
		weight1     <= 'd0;
		w_latch_out <= 'd0;
		weight_lock <= 'd0;
	end
	else begin
		a_out       <= a;
		a_first_out <= a_first;
		p_out       <= p_out_next;
		weight_flag <= weight_flag_next;
		weight_upd  <= weight_upd_next;
		weight0     <= weight0_next;
		weight1     <= weight1_next;
		w_latch_out <= w_latch;
		weight_lock <= weight_lock_next;
	end
end


////// Weight update logic
// a_first : used to update which buffer to use -> control weight_flag, unlock weights
// w_latch : used to update which buffer to update  -> control weight_upd, lock weights
//
// further : w_latch PAUSES loading weights in the idle buffer
//	   : a_first kick STARTS loading weights in the idle buffer

assign weight_flag_next = a_first ^ weight_flag;
assign weight_upd_next = weight_upd ^ w_latch;
assign weight_lock_next = ~a_first & ( weight_lock | w_latch );

assign weight_opt = weight_flag_next ? weight1 : weight0;

assign weight0_next = (weight_upd_next==1'b0) && ~weight_lock_next? b : weight0;  
assign weight1_next = (weight_upd_next==1'b1) && ~weight_lock_next? b : weight1;  



assign b_out      = weight_upd ? weight1 : weight0;
assign p_mul = a * weight_opt;
assign p_out_next = p_mul + p_in; // opposite flag read 


endmodule







/*
	Activation Controller
	Used to control RW signals for act buffers
	Also generates a_first signal
*/

module activation_controller
# (
	parameter D=8, // address depth
	parameter S=8  // length of a_first signal
	)
(
	input clk,rst,
	input a_valid,
	output a_stall,
	output [S-1:0] a_first,
	output a0_wen, a1_wen,
	output a0_ren, a1_ren,
	output [D-1:0] a0_waddr,a0_raddr,
	output [D-1:0] a1_waddr,a1_raddr
	);

//TODO: Add logic for address/en/latch

assign a0_wen = 'd0;
assign a1_wen = 'd0;
assign a0_ren = 'd0;
assign a1_ren = 'd0;
assign a0_waddr = 'd1;
assign a1_waddr = 'd0;
assign a0_raddr = 'd0;
assign a1_raddr = 'd0;

assign a_stall = a_valid; 
assign a_first = 'd0;

endmodule

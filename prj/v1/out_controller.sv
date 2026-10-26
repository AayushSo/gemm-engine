/*
	Output Controller
	Used to control RW signals for accumulator buffers
	Also generates c_valid signal
*/

module out_controller
# (
	D=8 // address depth
	)
(
	input clk,rst,
	output c0_valid,
	output c1_valid,
	output c0_wen, c1_wen,
	output c0_ren, c1_ren,
	output [D-1:0] c0_waddr,c0_raddr,
	output [D-1:0] c1_waddr,c1_raddr
	);

//TODO: Add logic for address/en/latch

assign c0_wen = 'd0;
assign c1_wen = 'd0;
assign c0_ren = 'd0;
assign c1_ren = 'd0;
assign c0_waddr = 'd1;
assign c1_waddr = 'd0;
assign c0_raddr = 'd0;
assign c1_raddr = 'd0;

assign c0_valid = 'd0;
assign c1_valid = 'd0;

endmodule

/*
	Weight Controller
	Used to control RW signals for weight buffers
	Also generates w_latch signal
*/
// inst: gemm_top.sv
module weight_controller
import gemm_v1_pkg::*;
(
	input clk,rst,
	input w_valid,
	// top->weight controller bus DVS
	input wcmd_t wcmd_data,
	input wcmd_valid,
	output wcmd_stall,
	output w_latch,
	output w0_wen, w1_wen,
	output w0_ren, w1_ren,
	output [W_AW-1:0] w0_waddr,w0_raddr,
	output [W_AW-1:0] w1_waddr,w1_raddr
	);

//TODO: Add logic for address/en/latch

assign w0_wen = 'd0;
assign w1_wen = 'd0;
assign w0_ren = 'd0;
assign w1_ren = 'd0;
assign w0_waddr = 'd1;
assign w1_waddr = 'd0;
assign w0_raddr = 'd0;
assign w1_raddr = 'd0;

assign w_stall = w_valid;
assign w_latch = 'd0;

endmodule

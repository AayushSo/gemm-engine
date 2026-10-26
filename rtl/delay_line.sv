/* 
	D-deep delay line.
	Supports D=0 (creates a simple wire)
*/

module delay_line
#(
	D=1,
	W=8 )
(
/* verilator lint_off UNUSEDSIGNAL */
	input clk, rst,
/* verilator lint_on UNUSEDSIGNAL */
	input [W-1:0] x,
	output [W-1:0] y);

`ifndef SYNTHESIS
initial if (D < 0) $fatal(1, "delay_line: D must be >= 0 (got %0d)", D);
`endif

genvar i;
generate
	if (D==0) begin : gen_D_0
		assign y=x;
	end
	else begin : gen_D
		reg [W-1:0] delay [D-1:0];
		always@(posedge clk) begin
			if (rst) delay[0] <= 'd0;
			else delay[0] <= x;
		end
		for (i=1;i<D;i++) begin
			always@(posedge clk) begin
				if (rst) delay[i] <= 'd0;
				else delay[i] <= delay[i-1];
			end
		end
		assign y = delay[D-1];
	end
endgenerate
endmodule

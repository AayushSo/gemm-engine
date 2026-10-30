`default_nettype none
/*
	GEMM Top wrapper file
	Contains all :
		* Control logic 
		* systolic array
		* buffers
		* Skew/deskew buffers
*/

// package : gemm_v1_pkg.sv
module gemm_top
import gemm_v1_pkg::*;
(
	input clk,rst,
	// input commands
	input cmd_t cmd_data,
	input cmd_valid,
	output cmd_stall,
	// response bus
	output resp_t resp_data,
	output resp_valid,
	input abort_req, // abort signal
	// weight input bus
	input [IN_W-1:0] w_data [T-1:0],
	input w_valid,
	output w_stall,
	// activation input bus
	input [IN_W-1:0] a_data [T-1:0],
	input a_valid,
	output a_stall,
	// resultant output bus
	output signed [ACC_W-1:0] c0_out [S-1:0],
	output signed [ACC_W-1:0] c1_out [S-1:0],
	output c0_valid,
	output c1_valid,
	// output block header DV
	output c_hdr_t c_hdr_data,
	output c_hdr_valid
	);

//parameters
localparam ADDR_D = $clog2(ACC_DEPTH);

// Interfaces

wcmd_t wcmd_data;
acmd_t acmd_data;
ocmd_t ocmd_data;
//resp_t resp_data;

// Regs


// Wires
wire signed [PSUM_W-1:0] psum_in  [T-1:0];
wire signed [IN_W*S-1:0] a0_rdata;
wire signed [IN_W*S-1:0] a1_rdata;
wire        [IN_W-1:0] act0 [S-1:0];
wire        [IN_W-1:0] act1 [S-1:0];
wire signed [IN_W-1:0] a [T-1:0];

wire signed [IN_W*S-1:0] w0_rdata;
wire signed [IN_W*S-1:0] w1_rdata;
wire        [IN_W-1:0] weight0_in [S-1:0];
wire        [IN_W-1:0] weight1_in [S-1:0];
wire        [IN_W-1:0] weight0 [S-1:0];
wire        [IN_W-1:0] weight1 [S-1:0];
wire signed [IN_W-1:0] b [T-1:0];

wire        [PSUM_W-1:0] psum_out0_skew [S-1:0];
wire        [PSUM_W-1:0] psum_out1_skew [S-1:0];
wire signed [PSUM_W-1:0] c [T-1:0];
wire        [PSUM_W-1:0] psum_out0 [S-1:0];
wire        [PSUM_W-1:0] psum_out1 [S-1:0];

//wire signed [ACC_W-1:0] c0_out [S-1:0];
//wire signed [ACC_W-1:0] c1_out [S-1:0];
wire signed [ACC_W-1:0] c0_data [S-1:0];
wire signed [ACC_W-1:0] c1_data [S-1:0];
wire signed [ACC_W-1:0] c0_acc [S-1:0];
wire signed [ACC_W-1:0] c1_acc [S-1:0];
reg  signed [ACC_W-1:0] c0_out_r [S-1:0];
reg  signed [ACC_W-1:0] c1_out_r [S-1:0];
wire c0_first, c1_first, c0_oen, c1_oen;
wire out_ack;

wire signed [IN_W*S-1:0] w0_wdata;
wire signed [IN_W*S-1:0] w1_wdata;

wire signed [IN_W*S-1:0] a0_wdata;
wire signed [IN_W*S-1:0] a1_wdata;

wire signed [ACC_W*S-1:0] c0_wdata;
wire signed [ACC_W*S-1:0] c1_wdata;
wire signed [ACC_W*S-1:0] c0_rdata;
wire signed [ACC_W*S-1:0] c1_rdata;

wire [T-1:0] a_first;
wire w_latch, weight_stall;
wire dummy_a_first;
wire w0_zero, w1_zero;
wire [T-1:0] w_col_mask;

wire        [IN_W-1:0] act0_in [S-1:0];
wire        [IN_W-1:0] act1_in [S-1:0];
wire w0_wen, w0_ren;
wire w1_wen, w1_ren;
wire a0_wen, a0_ren;
wire a1_wen, a1_ren;
wire c0_wen, c0_ren;
wire c1_wen, c1_ren;

wire [W_AW-1:0] w0_waddr, w1_waddr;
wire [A_AW-1:0] a0_waddr, a1_waddr;
wire [ADDR_D-1:0] c0_waddr, c1_waddr;
wire [W_AW-1:0] w0_raddr, w1_raddr;
wire [A_AW-1:0] a0_raddr, a1_raddr;
wire [ADDR_D-1:0] c0_raddr, c1_raddr;

wire wcmd_valid, wcmd_stall;
wire acmd_valid, acmd_stall;
wire ocmd_valid;
wire ld_go;
//wire resp_valid;

// Renvars
genvar i,j;

//////////////////////// Systolic array
// 16x16 for v1

// Assign in p_sum=0
generate
        for (i=0;i<T;i++) begin
                assign psum_in[i] = 'd0;
        end
endgenerate

// Double banked wiring

generate
	for(j=0;j<S;j++) begin
		for(i=0;i<NBANK;i++) begin
			assign a[i*S +j] = (i==0) ? act0[j] : act1[j];
			assign b[i*S +j] = (i==0) ? weight0[j] : weight1[j];
		end
		assign psum_out0_skew[j] = c[j];
		assign psum_out1_skew[j] = c[S+j];
	end
endgenerate

systolic #(.M(T), .NA(IN_W), .NPIN(PSUM_W))
u_systolic (
		.clk	 (clk),	
		.rst	 (rst),
		.a	 (a),	// in activations [IN_W-1:0] , unpacked [T-1:0]
		.b	 (b),	// in weights [IN_W-1:0] , unpacked [T-1:0]
		.p	 (psum_in),	// in p sums, tie-to-0
		.a_first (a_first),	// in a_first flag [T-1:0]
		.w_latch ({T{w_latch}}),// in w_latch 
		.c	 (c)		// out p-sums [PSUM_W-1:0] , unpacked [T-1:0] 
			);

////////////////////////  Skew buffers

// Activations skew
skew #( .N(S), .W(IN_W), .INCR(1), .START_Z(1) )
u_skew_act0
(
	.clk(clk), .rst(rst),
	.x (act0_in),
	.y (act0)
	);

skew #( .N(S), .W(IN_W), .INCR(1), .START_Z(1) )
u_skew_act1
(
	.clk(clk), .rst(rst),
	.x (act1_in),
	.y (act1)
	);

// Weight Skew
skew #( .N(S), .W(IN_W), .INCR(1), .START_Z(1) )
u_skew_wei0
(
	.clk(clk), .rst(rst),
	.x (weight0_in),
	.y (weight0)
	);

skew #( .N(S), .W(IN_W), .INCR(1), .START_Z(1) )
u_skew_wei1
(
	.clk(clk), .rst(rst),
	.x (weight1_in),
	.y (weight1)
	);

// Output Skew
skew #( .N(S), .W(PSUM_W), .INCR(0), .START_Z(1) )
u_skew_out0
(
	.clk(clk), .rst(rst),
	.x (psum_out0_skew),
	.y (psum_out0)
	);

skew #( .N(S), .W(PSUM_W), .INCR(0), .START_Z(1) )
u_skew_out1
(
	.clk(clk), .rst(rst),
	.x (psum_out1_skew),
	.y (psum_out1)
	);


////////////////////////  Weight Buffer

// 2D to 1D alignment
generate
	for(i=0;i<S;i++) begin
		assign w0_wdata[IN_W*(i+1)-1:IN_W*i] = w_data [i];
		assign w1_wdata[IN_W*(i+1)-1:IN_W*i] = w_data [S+i];
		assign weight0_in[i] = w0_zero || w_col_mask[i]   ? 'd0 : w0_rdata[IN_W*(i+1)-1:IN_W*i];
		assign weight1_in[i] = w1_zero || w_col_mask[S+i] ? 'd0 : w1_rdata[IN_W*(i+1)-1:IN_W*i];
	end
endgenerate


ram_1r1w
# ( .EW(IN_W), .NE(S), .DEPTH(W_DEPTH))
u_wei_buf0
(
	.clk(clk),
	.we(w0_wen),	//            
	.waddr(w0_waddr),	//[AW-1:0]    
	.wmask(~'d0),		//[NE-1:0]    
	.wdata(w0_wdata),	//[DW-1:0]    
	.re(w0_ren),	//             
	.raddr(w0_raddr),	//[AW-1:0]    
	.rdata(w0_rdata)	//[DW-1:0]    
	);


ram_1r1w
# ( .EW(IN_W), .NE(S), .DEPTH(W_DEPTH))
u_wei_buf1
(
	.clk(clk),
	.we(w1_wen),	//            
	.waddr(w1_waddr),	//[AW-1:0]    
	.wmask(~'d0),		//[NE-1:0]    
	.wdata(w1_wdata),	//[DW-1:0]    
	.re(w1_ren),	//             
	.raddr(w1_raddr),	//[AW-1:0]    
	.rdata(w1_rdata)	//[DW-1:0]    
	);

////////////////////////  Act Buffer

// 2D to 1D alignment
generate
	for(i=0;i<S;i++) begin
		assign a0_wdata[IN_W*(i+1)-1:IN_W*i] = a_data [i];
		assign a1_wdata[IN_W*(i+1)-1:IN_W*i] = a_data [S+i];
		assign act0_in[i] = a0_rdata[IN_W*(i+1)-1:IN_W*i];
		assign act1_in[i] = a1_rdata[IN_W*(i+1)-1:IN_W*i];
	end
endgenerate

ram_1r1w
# ( .EW(IN_W), .NE(S), .DEPTH(A_DEPTH))
u_act_buf0
(
	.clk(clk),
	.we(a0_wen),	//            
	.waddr(a0_waddr),	//[AW-1:0]    
	.wmask(~'d0),		//[NE-1:0]    
	.wdata(a0_wdata),	//[DW-1:0]    
	.re(a0_ren),	//             
	.raddr(a0_raddr),	//[AW-1:0]    
	.rdata(a0_rdata)	//[DW-1:0]    
	);


ram_1r1w
# ( .EW(IN_W), .NE(S), .DEPTH(A_DEPTH))
u_act_buf1
(
	.clk(clk),
	.we(a1_wen),	//            
	.waddr(a1_waddr),	//[AW-1:0]    
	.wmask(~'d0),		//[NE-1:0]    
	.wdata(a1_wdata),	//[DW-1:0]    
	.re(a1_ren),	//             
	.raddr(a1_raddr),	//[AW-1:0]    
	.rdata(a1_rdata)	//[DW-1:0]    
	);

////////////////////////  PSUM Buffer

// 2D to 1D alignment
generate
	for(i=0;i<S;i++) begin
		assign c0_wdata[ACC_W*(i+1)-1:ACC_W*i] = c0_data [i];
		assign c1_wdata[ACC_W*(i+1)-1:ACC_W*i] = c1_data [i];
		assign c0_out[i] = c0_out_r[i];
		assign c1_out[i] = c1_out_r[i];
	end
endgenerate

ram_1r1w
# ( .EW(ACC_W), .NE(S), .DEPTH(ACC_DEPTH))
u_out_buf0
(
	.clk(clk),
	.we(c0_wen),	//            
	.waddr(c0_waddr),	//[AW-1:0]    
	.wmask(~'d0),		//[NE-1:0]    
	.wdata(c0_wdata),	//[DW-1:0]    
	.re(c0_ren),	//             
	.raddr(c0_raddr),	//[AW-1:0]    
	.rdata(c0_rdata)	//[DW-1:0]    
	);

ram_1r1w
# ( .EW(ACC_W), .NE(S), .DEPTH(ACC_DEPTH))
u_out_buf1
(
	.clk(clk),
	.we(c1_wen),	//            
	.waddr(c1_waddr),	//[AW-1:0]    
	.wmask(~'d0),		//[NE-1:0]    
	.wdata(c1_wdata),	//[DW-1:0]    
	.re(c1_ren),	//             
	.raddr(c1_raddr),	//[AW-1:0]    
	.rdata(c1_rdata)	//[DW-1:0]    
	);

////////////////////////  Accumulator

generate
	for(i=0;i<S;i++) begin
		//assign c0_data[i] = $signed(psum_out0[i]) + c0_out[i];
		//assign c1_data[i] = $signed(psum_out1[i]) + c1_out[i];
		assign c0_acc[i]  = c0_first ? 'sd0 : $signed(c0_rdata[ACC_W*(i+1)-1:ACC_W*i]);
		assign c1_acc[i]  = c1_first ? 'sd0 : $signed(c1_rdata[ACC_W*(i+1)-1:ACC_W*i]);
		assign c0_data[i] = $signed(psum_out0[i]) + c0_acc[i];
		assign c1_data[i] = $signed(psum_out1[i]) + c1_acc[i];
		always@(posedge clk) begin
			if (c0_oen) c0_out_r[i] <= c0_data[i];
			if (c1_oen) c1_out_r[i] <= c1_data[i];
		end
	end
endgenerate



////////////////////////  Weight Controller
// weight_controller.sv
// generate the weight buffer RW signals, 
// w_latch signal
weight_controller 
u_weight_controller
(
	.clk(clk), 
	.rst(rst),
	.abort_req(abort_req),
	.wcmd_data(wcmd_data),
	.wcmd_valid(wcmd_valid &~ acmd_stall),
	.wcmd_stall(wcmd_stall),
	.w_valid(w_valid),
	.w_stall(w_stall),
	.weight_stall(weight_stall),
	.dummy_a_first(dummy_a_first),
	.w_latch(w_latch),
	.w0_zero(w0_zero),
	.w1_zero(w1_zero),
	.w_col_mask(w_col_mask),
	.w0_wen(w0_wen),
	.w1_wen(w1_wen),  
	.w0_ren(w0_ren),  
	.w1_ren(w1_ren),  
	.w0_waddr_out(w0_waddr), 
	.w1_waddr_out(w1_waddr), 
	.w0_raddr_out(w0_raddr), 
	.w1_raddr_out(w1_raddr),
	.ld_go (ld_go)
	);



////////////////////////  Act Controller
// activation_controller.sv
// generate the act buffer RW signals, 
// a_first signal

activation_controller
u_act_controller
(
	.clk(clk), 
	.rst(rst),
	.abort_req(abort_req),
	// input activation data dVS signalling
	.a_valid(a_valid),
	.a_stall(a_stall),
	// SA control signals
	.a_first(a_first),
	.dummy_a_first(dummy_a_first),
	.weight_stall(weight_stall),
	.ld_go(ld_go),
	// top -> acmd intf
	.acmd_data(acmd_data),
	.acmd_valid(acmd_valid &~ wcmd_stall),
	.acmd_stall(acmd_stall),
	// AC -> OC intf
	.ocmd_data(ocmd_data),
	.ocmd_valid(ocmd_valid),
	// activation RAM controls
	.a0_wen(a0_wen),
	.a1_wen(a1_wen),  
	.a0_ren(a0_ren),  
	.a1_ren(a1_ren),  
	.a0_waddr_out(a0_waddr), 
	.a1_waddr_out(a1_waddr), 
	.a0_raddr_out(a0_raddr), 
	.a1_raddr_out(a1_raddr) 
	);

////////////////////////  Out Controller
// out_controller.sv
// generate the act buffer RW signals, 
// a_first signal

out_controller 
u_out_controller
(
	.clk(clk), 
	.rst(rst),
	.abort_req(abort_req),
	// AC-> OC DV bus intf
	.ocmd_data(ocmd_data),
	.ocmd_valid(ocmd_valid),
	// output valid
	.c0_valid(c0_valid),
	.c1_valid(c1_valid),
	// accumulator datapath controls
	.out_ack(out_ack), // GEMM done to TC 
	.c0_first(c0_first),
	.c1_first(c1_first),
	.c0_oen(c0_oen),
	.c1_oen(c1_oen),
	// output block header
	.c_hdr_data(c_hdr_data),
	.c_hdr_valid(c_hdr_valid),
	// OC SRAM intf
	.c0_wen(c0_wen),
	.c1_wen(c1_wen),  
	.c0_ren(c0_ren),  
	.c1_ren(c1_ren),  
	.c0_waddr(c0_waddr), 
	.c1_waddr(c1_waddr), 
	.c0_raddr(c0_raddr), 
	.c1_raddr(c1_raddr) 
	);


////////////////////////  Top Controller
// top_controller.sv
top_controller
u_top_controller
(
	.clk(clk), 
	.rst(rst),
	// Command bus
	.cmd_data(cmd_data),
	.cmd_valid(cmd_valid),
	.cmd_stall(cmd_stall),
	// Response bus
	.resp_data(resp_data),
	.resp_valid(resp_valid),
	// weight controller connection
	.wcmd_data(wcmd_data),
	.wcmd_valid(wcmd_valid),
	.wcmd_stall(wcmd_stall),
	// act controller connection
	.acmd_data(acmd_data),
	.acmd_valid(acmd_valid),
	.acmd_stall(acmd_stall),
	.abort_req(abort_req),
	// end response OK
	.out_ack(out_ack)
	);

endmodule





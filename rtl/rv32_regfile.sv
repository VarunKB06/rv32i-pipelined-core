// 32 x 32-bit register file: two combinational read ports, one write port.
// A read sees the value being written in the same cycle (WB -> ID bypass).
// x0 always reads as zero and is never written.
module rv32_regfile (
  input         clk,
  input         we,
  input  [4:0]  waddr,
  input  [31:0] wdata,
  input  [4:0]  ra1,
  input  [4:0]  ra2,
  output [31:0] rd1,
  output [31:0] rd2
);
  reg [31:0] regs [0:31];
  integer i;

  initial begin
    for (i = 0; i < 32; i = i + 1) regs[i] = 32'd0;
  end

`ifdef BUG_X0_WRITE
  always @(posedge clk) begin
    if (we) regs[waddr] <= wdata;
  end
  assign rd1 = (we && (waddr == ra1)) ? wdata : regs[ra1];
  assign rd2 = (we && (waddr == ra2)) ? wdata : regs[ra2];
`elsif BUG_NO_RF_BYPASS
  always @(posedge clk) begin
    if (we && (waddr != 5'd0)) regs[waddr] <= wdata;
  end
  assign rd1 = (ra1 == 5'd0) ? 32'd0 : regs[ra1];
  assign rd2 = (ra2 == 5'd0) ? 32'd0 : regs[ra2];
`else
  always @(posedge clk) begin
    if (we && (waddr != 5'd0)) regs[waddr] <= wdata;
  end
  assign rd1 = (ra1 == 5'd0) ? 32'd0 : ((we && (waddr == ra1)) ? wdata : regs[ra1]);
  assign rd2 = (ra2 == 5'd0) ? 32'd0 : ((we && (waddr == ra2)) ? wdata : regs[ra2]);
`endif
endmodule

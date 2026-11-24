// Data memory: 1024 words (4 KiB), combinational read, synchronous write with byte enables.
// Addresses wrap modulo 4 KiB; the testbench flags any access at or above 4096.
module rv32_dmem #(
  parameter WORDS = 1024
) (
  input         clk,
  input         we,
  input  [3:0]  be,
  input  [31:0] addr,
  input  [31:0] wdata,
  output [31:0] rdata
);
  reg [31:0] mem [0:WORDS-1];
  reg [31:0] nw;
  integer i;

  initial begin
    for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'd0;
  end

  assign rdata = mem[addr[11:2]];

  always @(posedge clk) begin
    if (we) begin
      nw = mem[addr[11:2]];
      if (be[0]) nw[7:0]   = wdata[7:0];
      if (be[1]) nw[15:8]  = wdata[15:8];
      if (be[2]) nw[23:16] = wdata[23:16];
      if (be[3]) nw[31:24] = wdata[31:24];
      mem[addr[11:2]] <= nw;
    end
  end
endmodule

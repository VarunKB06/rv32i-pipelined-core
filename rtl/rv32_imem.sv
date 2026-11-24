// Instruction memory: 1024 words (4 KiB), combinational read.
// Initialised to NOP; the testbench loads a program with $readmemh.
module rv32_imem #(
  parameter WORDS = 1024
) (
  input  [31:0] addr,
  output [31:0] rdata
);
  reg [31:0] mem [0:WORDS-1];
  integer i;

  initial begin
    for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'h00000013;
  end

  assign rdata = mem[addr[11:2]];
endmodule

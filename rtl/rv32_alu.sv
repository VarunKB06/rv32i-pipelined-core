`include "rv32_defs.vh"

// Combinational ALU. The shift amount is b[4:0].
module rv32_alu (
  input      [31:0] a,
  input      [31:0] b,
  input      [3:0]  op,
  output reg [31:0] y
);
  wire [4:0] sh = b[4:0];

  always @* begin
    case (op)
      `ALU_ADD:  y = a + b;
      `ALU_SUB:  y = a - b;
      `ALU_SLL:  y = a << sh;
`ifdef BUG_SLT_UNSIGNED
      `ALU_SLT:  y = (a < b) ? 32'd1 : 32'd0;
`else
      `ALU_SLT:  y = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
`endif
      `ALU_SLTU: y = (a < b) ? 32'd1 : 32'd0;
      `ALU_XOR:  y = a ^ b;
      `ALU_SRL:  y = a >> sh;
      `ALU_SRA:  y = $signed(a) >>> sh;
      `ALU_OR:   y = a | b;
      `ALU_AND:  y = a & b;
      default:   y = 32'd0;
    endcase
  end
endmodule

`include "rv32_defs.vh"

// Combinational instruction decoder for RV32I (no CSR, no compressed).
// FENCE, ECALL and unknown opcodes decode as "no architectural effect".
module rv32_decoder (
  input      [31:0] insn,
  output     [4:0]  rs1,
  output     [4:0]  rs2,
  output     [4:0]  rd,
  output reg [31:0] imm,
  output reg [3:0]  alu_op,
  output reg [1:0]  a_sel,      // 0 = rs1, 1 = pc, 2 = zero
  output reg        b_imm,      // 1 = immediate, 0 = rs2
  output reg        reg_write,
  output reg        mem_read,
  output reg        mem_write,
  output reg        is_branch,
  output reg        is_jal,
  output reg        is_jalr,
  output reg        uses_rs1,
  output reg        uses_rs2
);
  wire [6:0] opcode = insn[6:0];
  wire [2:0] funct3 = insn[14:12];
  wire       alt    = insn[30];
  wire       is_op  = (opcode == `OPC_OP);   // register-register form (SUB allowed)

  assign rs1 = insn[19:15];
  assign rs2 = insn[24:20];
  assign rd  = insn[11:7];

  wire [31:0] imm_i = {{20{insn[31]}}, insn[31:20]};
  wire [31:0] imm_s = {{20{insn[31]}}, insn[31:25], insn[11:7]};
  wire [31:0] imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
  wire [31:0] imm_u = {insn[31:12], 12'b0};
  wire [31:0] imm_j = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

  // funct3 -> ALU operation
  reg [3:0] f3_alu;

  always @* begin
    case (funct3)
      3'b000:  f3_alu = (is_op && alt) ? `ALU_SUB : `ALU_ADD;
      3'b001:  f3_alu = `ALU_SLL;
      3'b010:  f3_alu = `ALU_SLT;
      3'b011:  f3_alu = `ALU_SLTU;
      3'b100:  f3_alu = `ALU_XOR;
`ifdef BUG_SRA_LOGICAL
      3'b101:  f3_alu = `ALU_SRL;
`else
      3'b101:  f3_alu = alt ? `ALU_SRA : `ALU_SRL;
`endif
      3'b110:  f3_alu = `ALU_OR;
      default: f3_alu = `ALU_AND;
    endcase
  end

  always @* begin
    imm       = imm_i;
    alu_op    = `ALU_ADD;
    a_sel     = 2'd0;
    b_imm     = 1'b1;
    reg_write = 1'b0;
    mem_read  = 1'b0;
    mem_write = 1'b0;
    is_branch = 1'b0;
    is_jal    = 1'b0;
    is_jalr   = 1'b0;
    uses_rs1  = 1'b0;
    uses_rs2  = 1'b0;

    case (opcode)
      `OPC_LUI: begin
        imm = imm_u; a_sel = 2'd2; reg_write = 1'b1;
      end
      `OPC_AUIPC: begin
        imm = imm_u; a_sel = 2'd1; reg_write = 1'b1;
      end
      `OPC_JAL: begin
        imm = imm_j; is_jal = 1'b1; reg_write = 1'b1;
      end
      `OPC_JALR: begin
        imm = imm_i; is_jalr = 1'b1; reg_write = 1'b1; uses_rs1 = 1'b1;
      end
      `OPC_BRANCH: begin
        imm = imm_b; is_branch = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1; b_imm = 1'b0;
      end
      `OPC_LOAD: begin
        imm = imm_i; mem_read = 1'b1; reg_write = 1'b1; uses_rs1 = 1'b1;
      end
      `OPC_STORE: begin
        imm = imm_s; mem_write = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1;
      end
      `OPC_OPIMM: begin
        imm = imm_i; reg_write = 1'b1; uses_rs1 = 1'b1;
        alu_op = f3_alu;
      end
      `OPC_OP: begin
        reg_write = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1; b_imm = 1'b0;
        alu_op = f3_alu;
      end
      default: begin
        // FENCE, SYSTEM (ECALL) and unknown opcodes: no architectural effect
      end
    endcase
  end
endmodule

`include "rv32_defs.vh"

// 5-stage in-order RV32I pipeline: IF, ID, EX, MEM, WB.
//  - Full forwarding EX/MEM -> EX and MEM/WB -> EX, plus WB -> ID bypass in the register file.
//  - One-cycle load-use stall (detected in ID).
//  - Branches/jumps resolve in EX; static "not taken" prediction, 2-cycle penalty on a redirect.
//  - Harvard memories: combinational instruction read, combinational data read, synchronous data write.
//
// Retire (WB-stage) and debug ports exist for the testbench's golden-model trace comparison
// and for functional coverage. They do not affect behavior.
module rv32_core (
  input         clk,
  input         rst_n,

  // instruction memory
  output [31:0] imem_addr,
  input  [31:0] imem_rdata,

  // data memory (word interface with byte enables)
  output [31:0] dmem_addr,
  output        dmem_we,
  output        dmem_re,
  output [3:0]  dmem_be,
  output [31:0] dmem_wdata,
  input  [31:0] dmem_rdata,

  // retire interface (WB stage)
  output        ret_valid,
  output [31:0] ret_pc,
  output [31:0] ret_insn,
  output        ret_rd_we,
  output [4:0]  ret_rd,
  output [31:0] ret_rd_data,
  output        ret_st_valid,
  output [1:0]  ret_st_size,
  output [31:0] ret_st_addr,
  output [31:0] ret_st_data,

  // debug / coverage observation
  output        dbg_stall,
  output        dbg_redirect,
  output        dbg_rf_bypass,
  output        dbg_ex_valid,
  output        dbg_ex_is_branch,
  output        dbg_ex_is_store,
  output [1:0]  dbg_fwd_a,
  output [1:0]  dbg_fwd_b
);

  // ==================================================================
  // Declarations
  // ==================================================================
  // IF
  reg  [31:0] pc;
  wire        stall;
  wire        redirect;
  wire [31:0] redirect_pc;

  // IF/ID
  reg         ifid_valid;
  reg  [31:0] ifid_pc;
  reg  [31:0] ifid_insn;

  // ID
  wire [4:0]  d_rs1;
  wire [4:0]  d_rs2;
  wire [4:0]  d_rd;
  wire [31:0] d_imm;
  wire [3:0]  d_alu_op;
  wire [1:0]  d_a_sel;
  wire        d_b_imm;
  wire        d_reg_write;
  wire        d_mem_read;
  wire        d_mem_write;
  wire        d_is_branch;
  wire        d_is_jal;
  wire        d_is_jalr;
  wire        d_uses_rs1;
  wire        d_uses_rs2;
  wire [31:0] rf_rd1;
  wire [31:0] rf_rd2;
  wire        rf_we;
  wire        id_bubble;

  // ID/EX
  reg         idex_valid;
  reg  [31:0] idex_pc;
  reg  [31:0] idex_insn;
  reg  [31:0] idex_rs1_val;
  reg  [31:0] idex_rs2_val;
  reg  [31:0] idex_imm;
  reg  [4:0]  idex_rs1;
  reg  [4:0]  idex_rs2;
  reg  [4:0]  idex_rd;
  reg  [2:0]  idex_funct3;
  reg  [3:0]  idex_alu_op;
  reg  [1:0]  idex_a_sel;
  reg         idex_b_imm;
  reg         idex_reg_write;
  reg         idex_mem_read;
  reg         idex_mem_write;
  reg         idex_is_branch;
  reg         idex_is_jal;
  reg         idex_is_jalr;
  reg         idex_uses_rs1;
  reg         idex_uses_rs2;

  // EX
  wire        fwd_a_ex;
  wire        fwd_a_wb;
  wire        fwd_b_ex;
  wire        fwd_b_wb;
  wire [1:0]  fwd_a;
  wire [1:0]  fwd_b;
  wire [31:0] rs1_val;
  wire [31:0] rs2_val;
  wire [31:0] alu_a;
  wire [31:0] alu_b;
  wire [31:0] alu_y;
  wire        eq;
  wire        lt;
  wire        ltu;
  reg         br_cond;
  wire        br_taken;
  wire [31:0] tgt_sum;
  wire [31:0] tgt;
  wire [31:0] ex_result;

  // EX/MEM
  reg         exmem_valid;
  reg  [31:0] exmem_pc;
  reg  [31:0] exmem_insn;
  reg  [31:0] exmem_result;
  reg  [31:0] exmem_store_data;
  reg  [4:0]  exmem_rd;
  reg  [2:0]  exmem_funct3;
  reg         exmem_reg_write;
  reg         exmem_mem_read;
  reg         exmem_mem_write;

  // MEM
  wire [1:0]  ba;
  wire [31:0] ld_shift;
  reg  [31:0] ld_data;
  wire [31:0] mem_result;
  reg  [3:0]  st_be;
  reg  [31:0] st_wdata;
  reg  [31:0] st_data_masked;

  // MEM/WB
  reg         memwb_valid;
  reg  [31:0] memwb_pc;
  reg  [31:0] memwb_insn;
  reg  [31:0] memwb_result;
  reg  [4:0]  memwb_rd;
  reg         memwb_reg_write;
  reg         memwb_st_valid;
  reg  [1:0]  memwb_st_size;
  reg  [31:0] memwb_st_addr;
  reg  [31:0] memwb_st_data;

  // ==================================================================
  // IF stage
  // ==================================================================
  always @(posedge clk) begin
    if (!rst_n)           pc <= 32'd0;
    else if (redirect)    pc <= redirect_pc;
    else if (!stall)      pc <= pc + 32'd4;
  end

  assign imem_addr = pc;

  always @(posedge clk) begin
    if (!rst_n || redirect) begin
      ifid_valid <= 1'b0;
      ifid_pc    <= 32'd0;
      ifid_insn  <= `INSN_NOP;
    end else if (!stall) begin
      ifid_valid <= 1'b1;
      ifid_pc    <= pc;
      ifid_insn  <= imem_rdata;
    end
  end

  // ==================================================================
  // ID stage
  // ==================================================================
  rv32_decoder u_dec (
    .insn      (ifid_insn),
    .rs1       (d_rs1),
    .rs2       (d_rs2),
    .rd        (d_rd),
    .imm       (d_imm),
    .alu_op    (d_alu_op),
    .a_sel     (d_a_sel),
    .b_imm     (d_b_imm),
    .reg_write (d_reg_write),
    .mem_read  (d_mem_read),
    .mem_write (d_mem_write),
    .is_branch (d_is_branch),
    .is_jal    (d_is_jal),
    .is_jalr   (d_is_jalr),
    .uses_rs1  (d_uses_rs1),
    .uses_rs2  (d_uses_rs2)
  );

  assign rf_we = memwb_valid & memwb_reg_write;

  rv32_regfile u_rf (
    .clk   (clk),
    .we    (rf_we),
    .waddr (memwb_rd),
    .wdata (memwb_result),
    .ra1   (d_rs1),
    .ra2   (d_rs2),
    .rd1   (rf_rd1),
    .rd2   (rf_rd2)
  );

  // Load-use hazard: the instruction in EX is a load whose destination is a source of the
  // instruction in ID. Hold PC and IF/ID for one cycle and insert a bubble into ID/EX.
`ifdef BUG_NO_LOADUSE_STALL
  assign stall = 1'b0;
`else
  assign stall = ifid_valid & idex_valid & idex_mem_read & (idex_rd != 5'd0) &
                 ((d_uses_rs1 & (idex_rd == d_rs1)) | (d_uses_rs2 & (idex_rd == d_rs2)));
`endif

`ifdef BUG_NO_ID_FLUSH
  assign id_bubble = stall | ~ifid_valid;
`else
  assign id_bubble = redirect | stall | ~ifid_valid;
`endif

  always @(posedge clk) begin
    if (!rst_n || id_bubble) begin
      idex_valid     <= 1'b0;
      idex_pc        <= 32'd0;
      idex_insn      <= `INSN_NOP;
      idex_rs1_val   <= 32'd0;
      idex_rs2_val   <= 32'd0;
      idex_imm       <= 32'd0;
      idex_rs1       <= 5'd0;
      idex_rs2       <= 5'd0;
      idex_rd        <= 5'd0;
      idex_funct3    <= 3'd0;
      idex_alu_op    <= `ALU_ADD;
      idex_a_sel     <= 2'd0;
      idex_b_imm     <= 1'b0;
      idex_reg_write <= 1'b0;
      idex_mem_read  <= 1'b0;
      idex_mem_write <= 1'b0;
      idex_is_branch <= 1'b0;
      idex_is_jal    <= 1'b0;
      idex_is_jalr   <= 1'b0;
      idex_uses_rs1  <= 1'b0;
      idex_uses_rs2  <= 1'b0;
    end else begin
      idex_valid     <= 1'b1;
      idex_pc        <= ifid_pc;
      idex_insn      <= ifid_insn;
      idex_rs1_val   <= rf_rd1;
      idex_rs2_val   <= rf_rd2;
      idex_imm       <= d_imm;
      idex_rs1       <= d_rs1;
      idex_rs2       <= d_rs2;
      idex_rd        <= d_rd;
      idex_funct3    <= ifid_insn[14:12];
      idex_alu_op    <= d_alu_op;
      idex_a_sel     <= d_a_sel;
      idex_b_imm     <= d_b_imm;
      idex_reg_write <= d_reg_write;
      idex_mem_read  <= d_mem_read;
      idex_mem_write <= d_mem_write;
      idex_is_branch <= d_is_branch;
      idex_is_jal    <= d_is_jal;
      idex_is_jalr   <= d_is_jalr;
      idex_uses_rs1  <= d_uses_rs1;
      idex_uses_rs2  <= d_uses_rs2;
    end
  end

  // ==================================================================
  // EX stage
  // ==================================================================
  // Forwarding: EX/MEM has priority over MEM/WB (it holds the younger value).
  // A load can never be forwarded from EX/MEM because the load-use stall delays its consumer.
  assign fwd_a_ex = idex_uses_rs1 & exmem_reg_write & (exmem_rd != 5'd0) & (exmem_rd == idex_rs1);
  assign fwd_a_wb = idex_uses_rs1 & memwb_reg_write & (memwb_rd != 5'd0) & (memwb_rd == idex_rs1);
  assign fwd_b_ex = idex_uses_rs2 & exmem_reg_write & (exmem_rd != 5'd0) & (exmem_rd == idex_rs2);
  assign fwd_b_wb = idex_uses_rs2 & memwb_reg_write & (memwb_rd != 5'd0) & (memwb_rd == idex_rs2);

`ifdef BUG_FWD_PRIORITY_WRONG
  assign fwd_a = fwd_a_wb ? 2'd2 : (fwd_a_ex ? 2'd1 : 2'd0);
  assign fwd_b = fwd_b_wb ? 2'd2 : (fwd_b_ex ? 2'd1 : 2'd0);
`elsif BUG_NO_FWD_MEMWB
  assign fwd_a = fwd_a_ex ? 2'd1 : 2'd0;
  assign fwd_b = fwd_b_ex ? 2'd1 : 2'd0;
`else
  assign fwd_a = fwd_a_ex ? 2'd1 : (fwd_a_wb ? 2'd2 : 2'd0);
  assign fwd_b = fwd_b_ex ? 2'd1 : (fwd_b_wb ? 2'd2 : 2'd0);
`endif

  assign rs1_val = (fwd_a == 2'd1) ? exmem_result :
                   (fwd_a == 2'd2) ? memwb_result : idex_rs1_val;
  assign rs2_val = (fwd_b == 2'd1) ? exmem_result :
                   (fwd_b == 2'd2) ? memwb_result : idex_rs2_val;

  assign alu_a = (idex_a_sel == 2'd0) ? rs1_val :
                 (idex_a_sel == 2'd1) ? idex_pc : 32'd0;
  assign alu_b = idex_b_imm ? idex_imm : rs2_val;

  rv32_alu u_alu (
    .a  (alu_a),
    .b  (alu_b),
    .op (idex_alu_op),
    .y  (alu_y)
  );

  // Branch comparison (uses forwarded operands)
  assign eq  = (rs1_val == rs2_val);
  assign lt  = ($signed(rs1_val) < $signed(rs2_val));
  assign ltu = (rs1_val < rs2_val);

  always @* begin
    case (idex_funct3)
      3'b000:  br_cond = eq;
      3'b001:  br_cond = ~eq;
`ifdef BUG_BLT_UNSIGNED
      3'b100:  br_cond = ltu;
      3'b101:  br_cond = ~ltu;
`else
      3'b100:  br_cond = lt;
      3'b101:  br_cond = ~lt;
`endif
      3'b110:  br_cond = ltu;
      3'b111:  br_cond = ~ltu;
      default: br_cond = 1'b0;
    endcase
  end

  assign br_taken = idex_valid & idex_is_branch & br_cond;

  // Branch/JAL target = pc + imm; JALR target = (rs1 + imm) with bit 0 cleared.
  assign tgt_sum = (idex_is_jalr ? rs1_val : idex_pc) + idex_imm;
  assign tgt     = idex_is_jalr ? {tgt_sum[31:1], 1'b0} : tgt_sum;

  assign redirect    = br_taken | (idex_valid & (idex_is_jal | idex_is_jalr));
  assign redirect_pc = tgt;

  // Jumps write the link address (pc + 4) instead of the ALU result.
  assign ex_result = (idex_is_jal | idex_is_jalr) ? (idex_pc + 32'd4) : alu_y;

  always @(posedge clk) begin
    if (!rst_n) begin
      exmem_valid      <= 1'b0;
      exmem_pc         <= 32'd0;
      exmem_insn       <= `INSN_NOP;
      exmem_result     <= 32'd0;
      exmem_store_data <= 32'd0;
      exmem_rd         <= 5'd0;
      exmem_funct3     <= 3'd0;
      exmem_reg_write  <= 1'b0;
      exmem_mem_read   <= 1'b0;
      exmem_mem_write  <= 1'b0;
    end else begin
      exmem_valid      <= idex_valid;
      exmem_pc         <= idex_pc;
      exmem_insn       <= idex_insn;
      exmem_result     <= ex_result;
`ifdef BUG_STORE_NO_FWD
      exmem_store_data <= idex_rs2_val;
`else
      exmem_store_data <= rs2_val;
`endif
      exmem_rd         <= idex_rd;
      exmem_funct3     <= idex_funct3;
      exmem_reg_write  <= idex_reg_write;
      exmem_mem_read   <= idex_mem_read;
      exmem_mem_write  <= idex_mem_write;
    end
  end

  // ==================================================================
  // MEM stage
  // ==================================================================
  assign ba = exmem_result[1:0];

  assign dmem_addr = exmem_result;
  assign dmem_we   = exmem_valid & exmem_mem_write;
  assign dmem_re   = exmem_valid & exmem_mem_read;

  // Store formatting: replicate data across lanes, enable the addressed bytes.
  always @* begin
    case (exmem_funct3[1:0])
      2'b00: begin
        st_be          = 4'b0001 << ba;
        st_wdata       = {4{exmem_store_data[7:0]}};
        st_data_masked = {24'd0, exmem_store_data[7:0]};
      end
      2'b01: begin
        st_be          = ba[1] ? 4'b1100 : 4'b0011;
        st_wdata       = {2{exmem_store_data[15:0]}};
        st_data_masked = {16'd0, exmem_store_data[15:0]};
      end
      default: begin
        st_be          = 4'b1111;
        st_wdata       = exmem_store_data;
        st_data_masked = exmem_store_data;
      end
    endcase
  end

  assign dmem_be    = st_be;
  assign dmem_wdata = st_wdata;

  // Load formatting
  assign ld_shift = dmem_rdata >> {ba, 3'b000};

  always @* begin
    case (exmem_funct3)
`ifdef BUG_LB_NO_SIGNEXT
      3'b000:  ld_data = {24'd0, ld_shift[7:0]};
`else
      3'b000:  ld_data = {{24{ld_shift[7]}}, ld_shift[7:0]};
`endif
      3'b001:  ld_data = {{16{ld_shift[15]}}, ld_shift[15:0]};
      3'b100:  ld_data = {24'd0, ld_shift[7:0]};
      3'b101:  ld_data = {16'd0, ld_shift[15:0]};
      default: ld_data = ld_shift;
    endcase
  end

  assign mem_result = exmem_mem_read ? ld_data : exmem_result;

  always @(posedge clk) begin
    if (!rst_n) begin
      memwb_valid     <= 1'b0;
      memwb_pc        <= 32'd0;
      memwb_insn      <= `INSN_NOP;
      memwb_result    <= 32'd0;
      memwb_rd        <= 5'd0;
      memwb_reg_write <= 1'b0;
      memwb_st_valid  <= 1'b0;
      memwb_st_size   <= 2'd0;
      memwb_st_addr   <= 32'd0;
      memwb_st_data   <= 32'd0;
    end else begin
      memwb_valid     <= exmem_valid;
      memwb_pc        <= exmem_pc;
      memwb_insn      <= exmem_insn;
      memwb_result    <= mem_result;
      memwb_rd        <= exmem_rd;
      memwb_reg_write <= exmem_reg_write;
      memwb_st_valid  <= exmem_valid & exmem_mem_write;
      memwb_st_size   <= exmem_funct3[1:0];
      memwb_st_addr   <= exmem_result;
      memwb_st_data   <= st_data_masked;
    end
  end

  // ==================================================================
  // WB stage: register write happens in u_rf; retire interface below.
  // Conventions shared with the Python golden model:
  //  - rd/rd_data are reported as 0 when no register is written (including rd == x0)
  //  - store fields are reported as 0 when the instruction is not a store
  // ==================================================================
  assign ret_valid    = memwb_valid;
  assign ret_pc       = memwb_pc;
  assign ret_insn     = memwb_insn;
  assign ret_rd_we    = memwb_valid & memwb_reg_write & (memwb_rd != 5'd0);
  assign ret_rd       = ret_rd_we ? memwb_rd : 5'd0;
  assign ret_rd_data  = ret_rd_we ? memwb_result : 32'd0;
  assign ret_st_valid = memwb_valid & memwb_st_valid;
  assign ret_st_size  = ret_st_valid ? memwb_st_size : 2'd0;
  assign ret_st_addr  = ret_st_valid ? memwb_st_addr : 32'd0;
  assign ret_st_data  = ret_st_valid ? memwb_st_data : 32'd0;

  // ==================================================================
  // Debug / coverage observation
  // ==================================================================
  assign dbg_stall        = stall;
  assign dbg_redirect     = redirect;
  assign dbg_rf_bypass    = memwb_reg_write & (memwb_rd != 5'd0) & ifid_valid &
                            ((d_uses_rs1 & (memwb_rd == d_rs1)) | (d_uses_rs2 & (memwb_rd == d_rs2)));
  assign dbg_ex_valid     = idex_valid;
  assign dbg_ex_is_branch = idex_valid & idex_is_branch;
  assign dbg_ex_is_store  = idex_valid & idex_mem_write;
  assign dbg_fwd_a        = fwd_a;
  assign dbg_fwd_b        = fwd_b;

endmodule

`timescale 1ns/1ps

// Self-checking testbench for the RV32I pipeline core.
//
// One program per simulation. Plusargs:
//   +HEX=<file>       program, one 32-bit hex word per line
//   +TRACE=<file>     golden retire trace produced by tools/rv32.py (first line = entry count)
//   +TESTNAME=<name>  label for the log
//   +VCD              dump waveforms/tb_rv32_core.vcd
//
// Checks:
//   1. Every retired instruction (pc, insn, rd write, store address/size/data) must equal the
//      golden trace entry, in order. Extra or missing retires are failures.
//   2. x0 never holds a non-zero value.
//   3. Stall and redirect are never asserted in the same cycle.
//   4. Data accesses stay inside the 4 KiB data memory.
//   5. No X/Z on retire outputs.
//   6. Watchdog timeout.
// Coverage: event bins are printed as "COV <index> <count>"; tools/run_regression.py merges them.
module tb_rv32_core;

  reg clk;
  reg rst_n;

  wire        ret_valid;
  wire [31:0] ret_pc;
  wire [31:0] ret_insn;
  wire        ret_rd_we;
  wire [4:0]  ret_rd;
  wire [31:0] ret_rd_data;
  wire        ret_st_valid;
  wire [1:0]  ret_st_size;
  wire [31:0] ret_st_addr;
  wire [31:0] ret_st_data;

  wire        dbg_stall;
  wire        dbg_redirect;
  wire        dbg_rf_bypass;
  wire        dbg_ex_valid;
  wire        dbg_ex_is_branch;
  wire        dbg_ex_is_store;
  wire [1:0]  dbg_fwd_a;
  wire [1:0]  dbg_fwd_b;

  wire [31:0] mon_dmem_addr;
  wire        mon_dmem_we;
  wire        mon_dmem_re;

  rv32_system dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .ret_valid        (ret_valid),
    .ret_pc           (ret_pc),
    .ret_insn         (ret_insn),
    .ret_rd_we        (ret_rd_we),
    .ret_rd           (ret_rd),
    .ret_rd_data      (ret_rd_data),
    .ret_st_valid     (ret_st_valid),
    .ret_st_size      (ret_st_size),
    .ret_st_addr      (ret_st_addr),
    .ret_st_data      (ret_st_data),
    .dbg_stall        (dbg_stall),
    .dbg_redirect     (dbg_redirect),
    .dbg_rf_bypass    (dbg_rf_bypass),
    .dbg_ex_valid     (dbg_ex_valid),
    .dbg_ex_is_branch (dbg_ex_is_branch),
    .dbg_ex_is_store  (dbg_ex_is_store),
    .dbg_fwd_a        (dbg_fwd_a),
    .dbg_fwd_b        (dbg_fwd_b),
    .mon_dmem_addr    (mon_dmem_addr),
    .mon_dmem_we      (mon_dmem_we),
    .mon_dmem_re      (mon_dmem_re)
  );

  // ------------------------------------------------------------------
  // Coverage bin indices (names live in tools/run_regression.py)
  // ------------------------------------------------------------------
  localparam C_LUI = 0, C_AUIPC = 1, C_JAL = 2, C_JALR = 3, C_BRANCH = 4,
             C_LOAD = 5, C_STORE = 6, C_OPIMM = 7, C_OP = 8, C_ECALL = 9,
             C_ALU = 10,                      // 10..19: add sub sll slt sltu xor srl sra or and
             C_BTK = 20,                      // 20..25: beq bne blt bge bltu bgeu taken
             C_BNT = 26,                      // 26..31: not taken
             C_LB = 32, C_LH = 33, C_LW = 34, C_LBU = 35, C_LHU = 36,
             C_SB = 37, C_SH = 38, C_SW = 39,
             C_FWA_EX = 40, C_FWA_WB = 41, C_FWB_EX = 42, C_FWB_WB = 43,
             C_STALL = 44, C_REDIR = 45, C_FWD_BOTH = 46, C_FWD_BR = 47,
             C_FWD_ST = 48, C_RFBYP = 49, C_X0DEST = 50,
             C_NBINS = 51;

  // ------------------------------------------------------------------
  // State
  // ------------------------------------------------------------------
  reg [8*256-1:0] hexfile;
  reg [8*256-1:0] tracefile;
  reg [8*256-1:0] testname;
  reg [175:0]     trace [0:16383];
  reg [175:0]     exp_w;
  reg [175:0]     got_w;

  integer total;
  integer nret;
  integer errors;
  integer cycles;
  integer max_cycles;
  integer n_stall;
  integer n_flush;
  integer i;
  integer tmp;
  integer cov [0:63];
  reg     done;

  reg        prev_br;
  reg [31:0] prev_pc;
  reg [2:0]  prev_f3;

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------
  task bump;
    input integer idx;
    begin
      cov[idx] = cov[idx] + 1;
    end
  endtask

  function integer br_idx;
    input [2:0] f3;
    begin
      case (f3)
        3'b000:  br_idx = 0;
        3'b001:  br_idx = 1;
        3'b100:  br_idx = 2;
        3'b101:  br_idx = 3;
        3'b110:  br_idx = 4;
        3'b111:  br_idx = 5;
        default: br_idx = 0;
      endcase
    end
  endfunction

  task fail;
    input [8*80-1:0] msg;
    begin
      errors = errors + 1;
      if (errors <= 10) $display("  ERROR @%0t cycle %0d: %0s", $time, cycles, msg);
    end
  endtask

  task show_mismatch;
    input integer idx;
    input [175:0] e;
    input [175:0] g;
    begin
      $display("  MISMATCH at retire #%0d", idx);
      $display("    exp: pc=%h insn=%h rdinfo=%h rd_data=%h stinfo=%h st_addr=%h st_data=%h",
               e[175:144], e[143:112], e[111:104], e[103:72], e[71:64], e[63:32], e[31:0]);
      $display("    got: pc=%h insn=%h rdinfo=%h rd_data=%h stinfo=%h st_addr=%h st_data=%h",
               g[175:144], g[143:112], g[111:104], g[103:72], g[71:64], g[63:32], g[31:0]);
    end
  endtask

  task cov_retire;
    input [31:0] insn;
    input [31:0] pc;
    reg [6:0] op;
    reg [2:0] f3;
    reg       alt;
    reg [4:0] rdf;
    begin
      op  = insn[6:0];
      f3  = insn[14:12];
      alt = insn[30];
      rdf = insn[11:7];

      // outcome of the previous branch: taken if this instruction is not at prev_pc + 4
      if (prev_br) begin
        if (pc != prev_pc + 32'd4) bump(C_BTK + br_idx(prev_f3));
        else                       bump(C_BNT + br_idx(prev_f3));
      end
      prev_br = (op == 7'b1100011);
      prev_pc = pc;
      prev_f3 = f3;

      case (op)
        7'b0110111: bump(C_LUI);
        7'b0010111: bump(C_AUIPC);
        7'b1101111: bump(C_JAL);
        7'b1100111: bump(C_JALR);
        7'b1100011: bump(C_BRANCH);
        7'b0000011: begin
          bump(C_LOAD);
          case (f3)
            3'b000:  bump(C_LB);
            3'b001:  bump(C_LH);
            3'b010:  bump(C_LW);
            3'b100:  bump(C_LBU);
            3'b101:  bump(C_LHU);
            default: ;
          endcase
        end
        7'b0100011: begin
          bump(C_STORE);
          case (f3)
            3'b000:  bump(C_SB);
            3'b001:  bump(C_SH);
            3'b010:  bump(C_SW);
            default: ;
          endcase
        end
        7'b0010011, 7'b0110011: begin
          if (op == 7'b0010011) bump(C_OPIMM); else bump(C_OP);
          case (f3)
            3'b000:  if (op == 7'b0110011 && alt) bump(C_ALU + 1); else bump(C_ALU + 0);
            3'b001:  bump(C_ALU + 2);
            3'b010:  bump(C_ALU + 3);
            3'b011:  bump(C_ALU + 4);
            3'b100:  bump(C_ALU + 5);
            3'b101:  if (alt) bump(C_ALU + 7); else bump(C_ALU + 6);
            3'b110:  bump(C_ALU + 8);
            default: bump(C_ALU + 9);
          endcase
        end
        7'b1110011: if (insn == 32'h00000073) bump(C_ECALL);
        default: ;
      endcase

      // an instruction that writes a register but targets x0 (excluding the canonical NOP)
      if (rdf == 5'd0 && insn != 32'h00000013 &&
          (op == 7'b0110111 || op == 7'b0010111 || op == 7'b1101111 || op == 7'b1100111 ||
           op == 7'b0000011 || op == 7'b0010011 || op == 7'b0110011))
        bump(C_X0DEST);
    end
  endtask

  task print_cov;
    integer k;
    begin
      for (k = 0; k < C_NBINS; k = k + 1) $display("COV %0d %0d", k, cov[k]);
    end
  endtask

  task finish_test;
    begin
      done = 1'b1;
      print_cov;
      $display("STATS cycles=%0d retired=%0d stalls=%0d flushes=%0d", cycles, nret, n_stall, n_flush);
      if (errors == 0 && total > 0 && nret == total) $display("TEST %0s PASS", testname);
      else                                           $display("TEST %0s FAIL errors=%0d retired=%0d/%0d",
                                                              testname, errors, nret, total);
      $finish;
    end
  endtask

  // ------------------------------------------------------------------
  // Clock, reset, program load
  // ------------------------------------------------------------------
  always #5 clk = ~clk;

  initial begin
    clk        = 1'b0;
    rst_n      = 1'b0;
    done       = 1'b0;
    nret       = 0;
    errors     = 0;
    cycles     = 0;
    n_stall    = 0;
    n_flush    = 0;
    prev_br    = 1'b0;
    prev_pc    = 32'd0;
    prev_f3    = 3'd0;
    testname   = "unnamed";
    for (i = 0; i < 64; i = i + 1) cov[i] = 0;

    tmp = $value$plusargs("TESTNAME=%s", testname);
    if (!$value$plusargs("HEX=%s", hexfile)) begin
      $display("ERROR: +HEX=<file> is required");
      $finish;
    end
    if (!$value$plusargs("TRACE=%s", tracefile)) begin
      $display("ERROR: +TRACE=<file> is required");
      $finish;
    end

    if ($test$plusargs("VCD")) begin
      $dumpfile("waveforms/tb_rv32_core.vcd");
      $dumpvars(0, tb_rv32_core);
    end

    #1;
    $readmemh(hexfile, dut.u_imem.mem);
    for (i = 0; i < 16384; i = i + 1) trace[i] = 176'd0;
    $readmemh(tracefile, trace);
    exp_w      = trace[0];
    total      = exp_w[31:0];
    max_cycles = total * 6 + 200;

    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
  end

  // ------------------------------------------------------------------
  // Per-cycle monitor / checker / scoreboard (samples pre-edge values)
  // ------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n && !done) begin
      cycles = cycles + 1;

      // --- hazard and pipeline-control events
      if (dbg_stall)    begin n_stall = n_stall + 1; bump(C_STALL); end
      if (dbg_redirect) begin n_flush = n_flush + 1; bump(C_REDIR); end
      if (dbg_fwd_a == 2'd1) bump(C_FWA_EX);
      if (dbg_fwd_a == 2'd2) bump(C_FWA_WB);
      if (dbg_fwd_b == 2'd1) bump(C_FWB_EX);
      if (dbg_fwd_b == 2'd2) bump(C_FWB_WB);
      if (dbg_fwd_a != 2'd0 && dbg_fwd_b != 2'd0) bump(C_FWD_BOTH);
      if (dbg_ex_is_branch && (dbg_fwd_a != 2'd0 || dbg_fwd_b != 2'd0)) bump(C_FWD_BR);
      if (dbg_ex_is_store && dbg_fwd_b != 2'd0) bump(C_FWD_ST);
      if (dbg_rf_bypass) bump(C_RFBYP);

      // --- invariants
      // A load-use stall needs a load in EX; a redirect needs a branch/jump in EX: never both.
      if (dbg_stall && dbg_redirect) fail("stall and redirect asserted together");
      if (dut.u_core.u_rf.regs[0] !== 32'd0) fail("x0 holds a non-zero value");
      if ((mon_dmem_we || mon_dmem_re) && (mon_dmem_addr >= 32'd4096)) fail("data access outside 4 KiB");

      // --- retire scoreboard
      if (ret_valid) begin
        if ((^{ret_pc, ret_insn, ret_rd_data, ret_st_addr, ret_st_data}) === 1'bx)
          fail("X/Z on retire outputs");

        if (nret >= total) begin
          fail("retire beyond the end of the golden trace");
        end else begin
          exp_w = trace[nret + 1];
          got_w = {ret_pc, ret_insn, 2'b00, ret_rd_we, ret_rd, ret_rd_data,
                   5'b00000, ret_st_valid, ret_st_size, ret_st_addr, ret_st_data};
          if (got_w !== exp_w) begin
            errors = errors + 1;
            if (errors <= 3) show_mismatch(nret, exp_w, got_w);
          end
          cov_retire(ret_insn, ret_pc);
          nret = nret + 1;
        end
      end

      if (errors > 10) begin
        $display("  too many errors, aborting this test");
        finish_test;
      end else if (nret >= total) begin
        finish_test;
      end else if (cycles > max_cycles) begin
        errors = errors + 1;
        $display("  ERROR: timeout after %0d cycles (retired %0d of %0d)", cycles, nret, total);
        finish_test;
      end
    end
  end

endmodule

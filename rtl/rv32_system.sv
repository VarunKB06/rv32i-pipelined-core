// Core + instruction memory + data memory. The testbench instantiates this module.
module rv32_system (
  input         clk,
  input         rst_n,

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

  output        dbg_stall,
  output        dbg_redirect,
  output        dbg_rf_bypass,
  output        dbg_ex_valid,
  output        dbg_ex_is_branch,
  output        dbg_ex_is_store,
  output [1:0]  dbg_fwd_a,
  output [1:0]  dbg_fwd_b,

  output [31:0] mon_dmem_addr,
  output        mon_dmem_we,
  output        mon_dmem_re
);
  wire [31:0] imem_addr;
  wire [31:0] imem_rdata;
  wire [31:0] dmem_addr;
  wire        dmem_we;
  wire        dmem_re;
  wire [3:0]  dmem_be;
  wire [31:0] dmem_wdata;
  wire [31:0] dmem_rdata;

  rv32_core u_core (
    .clk              (clk),
    .rst_n            (rst_n),
    .imem_addr        (imem_addr),
    .imem_rdata       (imem_rdata),
    .dmem_addr        (dmem_addr),
    .dmem_we          (dmem_we),
    .dmem_re          (dmem_re),
    .dmem_be          (dmem_be),
    .dmem_wdata       (dmem_wdata),
    .dmem_rdata       (dmem_rdata),
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
    .dbg_fwd_b        (dbg_fwd_b)
  );

  rv32_imem u_imem (
    .addr  (imem_addr),
    .rdata (imem_rdata)
  );

  rv32_dmem u_dmem (
    .clk   (clk),
    .we    (dmem_we),
    .be    (dmem_be),
    .addr  (dmem_addr),
    .wdata (dmem_wdata),
    .rdata (dmem_rdata)
  );

  assign mon_dmem_addr = dmem_addr;
  assign mon_dmem_we   = dmem_we;
  assign mon_dmem_re   = dmem_re;
endmodule

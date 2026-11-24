# Verification plan

## Method: golden-model trace comparison

1. `tools/rv32.py` assembles/generates a program and runs it on a Python instruction-set simulator
   (ISS) written from the RISC-V specification, independently of the RTL.
2. The ISS writes a **retire trace**: for every instruction, in program order: `pc`, instruction word,
   register write (`rd`, data) and store (address, size, data).
3. The testbench (`verification/tb_rv32_core.sv`) loads the same program, runs the RTL, and compares
   every instruction leaving the WB stage against the trace. Any difference is reported with both entries.

Directed tests also self-check: each ends by storing `0x600D` to data address `0x1F0` only if every internal
check passed. The runner requires that marker in the *golden model's* trace first, which validates the test
program itself before it is used against the RTL.

## Stimulus

| Source | Content |
|---|---|
| `tests/t01_alu.S` | every ALU op, shift/compare boundaries, LUI/AUIPC |
| `tests/t02_loadstore.S` | LB/LH/LW/LBU/LHU, SB/SH/SW, sign/zero extension, sub-word merging |
| `tests/t03_branches.S` | six branch types taken/not taken, backward loop, flush of wrong-path instructions |
| `tests/t04_jumps.S` | JAL/JALR links and targets, rd == rs1, odd JALR target, JAL x0 |
| `tests/t05_hazards.S` | EX/MEM and MEM/WB forwarding, back-to-back same-destination writes, WB->ID bypass, load-use into ALU/store/branch/address/JALR |
| `tests/t06_loops.S` | Fibonacci and array sum (stalls inside loops) |
| `tests/t07_x0.S` | writes to x0, forwarding from x0, load into x0 |
| random (`gen_random_program`) | seeded, ~250 instructions: small register pool (dense dependencies), forward-only branches/jumps (always terminates), aligned loads/stores in 0x100..0x1FF |

## Checkers

1. Retire trace comparison (above).
2. x0 never non-zero.
3. Stall and redirect never in the same cycle.
4. Data accesses inside the 4 KiB memory.
5. No X/Z on retire outputs.
6. Cycle watchdog.

## Functional coverage

Hand-written event bins (51), counted in the testbench and merged by the runner into
`reports/functional_coverage.txt`: opcode classes, all ten ALU operations, each branch type taken and
not taken, each load/store width, forwarding from each source on each operand, load-use stall, redirect,
both operands forwarded, forwarding into a branch compare and into store data, register-file bypass,
and instructions that target x0.

## Bug-injection check (`--mutate`)

`rtl/` contains 11 switchable deliberate bugs (compile with `-D BUG_...`). The runner recompiles the design
with each one and requires the regression to **fail**; a surviving mutant means the testbench has a hole.

| Macro | Bug |
|---|---|
| `BUG_NO_FWD_MEMWB` | no MEM/WB forwarding |
| `BUG_FWD_PRIORITY_WRONG` | MEM/WB preferred over EX/MEM |
| `BUG_NO_LOADUSE_STALL` | load-use hazard not stalled |
| `BUG_NO_ID_FLUSH` | taken branch does not squash the instruction in ID |
| `BUG_NO_RF_BYPASS` | no WB->ID bypass |
| `BUG_X0_WRITE` | x0 can be written |
| `BUG_SLT_UNSIGNED` | SLT compares unsigned |
| `BUG_SRA_LOGICAL` | SRA/SRAI shift logically |
| `BUG_BLT_UNSIGNED` | BLT/BGE compare unsigned |
| `BUG_LB_NO_SIGNEXT` | LB does not sign-extend |
| `BUG_STORE_NO_FWD` | store data not forwarded |

## Not done / limitations

* Procedural checkers only: no native SVA, no UVM, no formal, no compliance suite (riscv-tests / riscv-arch-test).
* Coverage is hand-written event counting, not a covergroup/cross-coverage flow.
* The golden model and the directed-test expectations were written by the same author as the RTL.
  Running the official RISC-V architectural compliance tests would be the strongest independent check.

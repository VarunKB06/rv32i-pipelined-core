# RV32I 5-Stage Pipelined Core with Golden-Model Verification

[![RV32I regression](https://github.com/VarunKB06/rv32i-pipelined-core/actions/workflows/regression.yml/badge.svg)](https://github.com/VarunKB06/rv32i-pipelined-core/actions/workflows/regression.yml)

A 5-stage in-order **RV32I** processor core in Verilog/SystemVerilog (IF, ID, EX, MEM, WB) with data
forwarding, load-use stalls and branch flushing, plus a verification environment that checks every
retired instruction against an independent Python instruction-set simulator.

## Status

| Item | State |
|---|---|
| RTL (`rtl/`) | Compiles and passes the full regression with Icarus Verilog in GitHub Actions |
| Directed tests (`tests/`) | 7 / 7 pass |
| Random programs | 40 / 40 pass (seeds 1-40, about 250 instructions each) |
| Functional coverage | 51 / 51 event bins hit |
| Bug-injection check | 11 / 11 injected bugs caught |
| Not done | Official RISC-V compliance suite, native SVA, UVM, formal, synthesis (see Limitations) |

All numbers below come from the CI run's `reports/` output.

## Features

* RV32I base ISA: LUI, AUIPC, JAL, JALR, six branches, five loads, three stores, all ALU ops
* Forwarding EX/MEM and MEM/WB into EX (ALU, branch compare, store data, JALR base); WB-to-ID regfile bypass
* One-cycle load-use stall; branches/jumps resolved in EX with a 2-cycle flush penalty
* Retire interface (pc, instruction, register write, store) used by the testbench scoreboard

## Quick start

Requires Icarus Verilog 11+ and Python 3.8+.

```bash
python3 tools/rv32.py --selftest                 # assembler + golden model checks (no simulator needed)
python3 tools/run_regression.py                  # 7 directed tests + 40 random programs
python3 tools/run_regression.py --random 200     # more random programs
python3 tools/run_regression.py --mutate         # bug-injection check (every mutant must be caught)
python3 tools/run_regression.py --waves t05_hazards   # also writes waveforms/tb_rv32_core.vcd
./scripts/run_all.sh                             # self-test + regression
```

Outputs: `reports/regression_summary.txt`, `reports/functional_coverage.txt`,
`reports/mutation_summary.txt`, per-test logs in `reports/logs/`.

Manual single run:

```bash
python3 tools/run_regression.py --programs-only --random 0
iverilog -g2012 -I rtl -s tb_rv32_core -o build/sim.vvp rtl/*.sv verification/tb_rv32_core.sv
vvp build/sim.vvp +HEX=build/programs/t05_hazards.hex +TRACE=build/programs/t05_hazards.trace +TESTNAME=t05 +VCD
```

## Layout

```
rtl/            core, decoder, ALU, register file, memories, system wrapper, injectable bugs
verification/   tb_rv32_core.sv (trace-comparing, self-checking testbench with coverage)
tools/          rv32.py (assembler, golden ISS, random generator), run_regression.py
tests/          directed assembly programs with built-in self-checks
docs/           architecture.md, verification_plan.md
.github/        CI workflow (regression + mutation)
```

## How verification works

The Python ISS runs each program and writes the expected retire trace. The testbench runs the RTL and
compares each instruction leaving WB with the trace (pc, instruction, register write, store address/size/data).
Directed tests also self-check and must pass in the golden model before they are used. Details, stimulus table,
checkers, coverage bins and the 11 injectable bugs are in [docs/verification_plan.md](docs/verification_plan.md);
microarchitecture is in [docs/architecture.md](docs/architecture.md).

## Results

Source (committed in `reports/`): `reports/regression_summary.txt`, `reports/functional_coverage.txt`, `reports/mutation_summary.txt`.

| Metric | Value |
|---|---|
| Directed tests passing | 7 / 7 |
| Random programs passing (seeds 1..40) | 40 / 40 |
| Instructions retired / cycles | 9,526 / 12,099 (CPI 1.270) |
| Load-use stalls / redirect flushes | 283 / 1,051 |
| Event bins hit | 51 / 51 |
| Injected bugs caught | 11 / 11 |
| CI | [GitHub Actions workflow runs](https://github.com/VarunKB06/rv32i-pipelined-core/actions/workflows/regression.yml) |

What these numbers mean: every retired instruction matched the Python golden model, and every deliberately
injected bug made the regression fail. They do not prove the core correct: the golden model was written by the
same author as the RTL, and the coverage bins are hand-defined events.

## Limitations

* Single-issue, no branch predictor, no caches, no CSRs/interrupts, no M/A/C extensions
* Behavioural memories (combinational read), not SRAM macros; no misaligned-access support
* Procedural checkers and hand-written coverage: no native SVA, UVM or formal yet
* The golden model is written by the same author as the RTL; running the official RISC-V compliance suite
  would be a stronger independent check

## Ideas to extend (and strengthen the project)

1. Run `riscv-arch-test` RV32I against the core
2. Add native SVA properties and a SymbiYosys formal proof of the hazard logic
3. Synthesize with Yosys/Genus, report area and critical path (only report numbers you generate)
4. Port to the PYNQ-Z2 or Tiny Tapeout flow

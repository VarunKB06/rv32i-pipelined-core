#!/usr/bin/env python3
"""Regression driver for the RV32I pipeline core.

  python3 tools/run_regression.py                 # directed tests + 40 random programs
  python3 tools/run_regression.py --random 100    # more random programs
  python3 tools/run_regression.py --mutate        # bug-injection sanity check
  python3 tools/run_regression.py --waves t05_hazards   # also dump a VCD for one test

For every program the golden ISS (tools/rv32.py) produces the program image and the expected
retire trace; the RTL testbench compares against that trace. Directed tests must additionally
reach their own PASS marker in the golden model, which validates the test program itself.

Requires Icarus Verilog (iverilog + vvp) on PATH.
"""
import argparse
import glob
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rv32  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
BUILD = os.path.join(ROOT, 'build')
REPORTS = os.path.join(ROOT, 'reports')

COV_NAMES = (
    ["op_lui", "op_auipc", "op_jal", "op_jalr", "op_branch", "op_load", "op_store",
     "op_imm", "op_reg", "op_ecall"] +
    ["alu_" + n for n in ("add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and")] +
    ["br_taken_" + n for n in ("beq", "bne", "blt", "bge", "bltu", "bgeu")] +
    ["br_not_taken_" + n for n in ("beq", "bne", "blt", "bge", "bltu", "bgeu")] +
    ["load_lb", "load_lh", "load_lw", "load_lbu", "load_lhu", "store_sb", "store_sh", "store_sw"] +
    ["fwd_a_from_exmem", "fwd_a_from_memwb", "fwd_b_from_exmem", "fwd_b_from_memwb",
     "load_use_stall", "redirect_flush", "fwd_both_operands", "fwd_into_branch",
     "fwd_into_store_data", "regfile_wb_bypass", "x0_destination"]
)
assert len(COV_NAMES) == 51

BUGS = [
    ("BUG_NO_FWD_MEMWB",       "no MEM/WB -> EX forwarding"),
    ("BUG_FWD_PRIORITY_WRONG", "MEM/WB forwarded in preference to EX/MEM (stale value)"),
    ("BUG_NO_LOADUSE_STALL",   "load-use hazard not stalled"),
    ("BUG_NO_ID_FLUSH",        "taken branch does not squash the instruction in ID"),
    ("BUG_NO_RF_BYPASS",       "no WB -> ID register-file bypass"),
    ("BUG_X0_WRITE",           "x0 can be written"),
    ("BUG_SLT_UNSIGNED",       "SLT compares unsigned"),
    ("BUG_SRA_LOGICAL",        "SRA/SRAI shift logically"),
    ("BUG_BLT_UNSIGNED",       "BLT/BGE compare unsigned"),
    ("BUG_LB_NO_SIGNEXT",      "LB does not sign-extend"),
    ("BUG_STORE_NO_FWD",       "store data is not forwarded"),
]


def build_programs(n_random, seed0, n_body):
    """Assemble/generate all programs and their golden traces. Returns list of dicts."""
    out_dir = os.path.join(BUILD, 'programs')
    os.makedirs(out_dir, exist_ok=True)
    progs = []
    for path in sorted(glob.glob(os.path.join(ROOT, 'tests', '*.S'))):
        name = os.path.splitext(os.path.basename(path))[0]
        with open(path) as f:
            words = rv32.assemble(f.read())
        trace = rv32.Iss(words).run()
        if not rv32.marker_passed(trace):
            sys.exit("ERROR: directed test %s does not reach its PASS marker in the golden model "
                     "(the test program itself is wrong)" % name)
        progs.append(_emit(out_dir, name, words, trace, 'directed'))
    for k in range(n_random):
        seed = seed0 + k
        name = "rand_s%d" % seed
        words = rv32.gen_random_program(seed, n_body)
        trace = rv32.Iss(words).run()
        progs.append(_emit(out_dir, name, words, trace, 'random'))
    return progs


def _emit(out_dir, name, words, trace, kind):
    hexp = os.path.join(out_dir, name + '.hex')
    trcp = os.path.join(out_dir, name + '.trace')
    rv32.write_hex(hexp, words)
    rv32.write_trace(trcp, trace)
    return {'name': name, 'hex': hexp, 'trace': trcp, 'kind': kind, 'n_ret': len(trace)}


def compile_sim(defines, out):
    rtl = sorted(glob.glob(os.path.join(ROOT, 'rtl', '*.sv')))
    cmd = ['iverilog', '-g2012', '-I', os.path.join(ROOT, 'rtl'), '-s', 'tb_rv32_core', '-o', out]
    for d in defines:
        cmd += ['-D', d]
    cmd += rtl + [os.path.join(ROOT, 'verification', 'tb_rv32_core.sv')]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        return False, r.stdout + r.stderr
    return True, r.stdout + r.stderr


def run_one(sim, prog, waves=False):
    cmd = ['vvp', '-n', sim, '+HEX=' + prog['hex'], '+TRACE=' + prog['trace'],
           '+TESTNAME=' + prog['name']]
    if waves:
        cmd.append('+VCD')
    try:
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=300)
        text = r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        text = "TEST %s FAIL (host timeout)\n" % prog['name']
    passed = re.search(r'^TEST\s+\S+\s+PASS\s*$', text, re.M) is not None
    cov = {int(a): int(b) for a, b in re.findall(r'^COV\s+(\d+)\s+(\d+)\s*$', text, re.M)}
    m = re.search(r'^STATS cycles=(\d+) retired=(\d+) stalls=(\d+) flushes=(\d+)', text, re.M)
    stats = tuple(int(x) for x in m.groups()) if m else (0, 0, 0, 0)
    return passed, cov, stats, text


def regression(args):
    progs = build_programs(args.random, args.seed0, args.body)
    os.makedirs(os.path.join(REPORTS, 'logs'), exist_ok=True)
    sim = os.path.join(BUILD, 'sim.vvp')
    ok, msg = compile_sim([], sim)
    if not ok:
        print(msg)
        sys.exit("ERROR: compile failed")
    if msg.strip():
        print(msg.strip())

    total_cov = [0] * len(COV_NAMES)
    rows, failed = [], []
    cycles = retired = stalls = flushes = 0
    for p in progs:
        passed, cov, st, text = run_one(sim, p, waves=(args.waves == p['name']))
        with open(os.path.join(REPORTS, 'logs', p['name'] + '.log'), 'w') as f:
            f.write(text)
        for k, v in cov.items():
            if k < len(total_cov):
                total_cov[k] += v
        cycles += st[0]
        retired += st[1]
        stalls += st[2]
        flushes += st[3]
        rows.append((p['name'], p['kind'], passed, st))
        print("%-5s %-14s retired=%-5d cycles=%-5d" % ("PASS" if passed else "FAIL", p['name'], st[1], st[0]))
        if not passed:
            failed.append(p['name'])
            print(text)

    hit = sum(1 for c in total_cov if c > 0)
    lines = []
    lines.append("RV32I pipeline core - regression summary")
    lines.append("=" * 48)
    lines.append("directed tests : %d" % sum(1 for r in rows if r[1] == 'directed'))
    lines.append("random programs: %d (seeds %d..%d, ~%d body instructions)" %
                 (args.random, args.seed0, args.seed0 + max(args.random - 1, 0), args.body))
    lines.append("passed         : %d / %d" % (len(rows) - len(failed), len(rows)))
    lines.append("retired insns  : %d" % retired)
    lines.append("cycles         : %d" % cycles)
    if retired:
        lines.append("CPI            : %.3f" % (cycles / float(retired)))
    lines.append("load-use stalls: %d, redirect flushes: %d" % (stalls, flushes))
    lines.append("event bins hit : %d / %d" % (hit, len(COV_NAMES)))
    lines.append("")
    lines.append("%-6s %-14s %-9s %s" % ("result", "test", "kind", "retired/cycles"))
    for name, kind, passed, st in rows:
        lines.append("%-6s %-14s %-9s %d/%d" % ("PASS" if passed else "FAIL", name, kind, st[1], st[0]))
    lines.append("")
    lines.append("FINAL: %s" % ("PASS" if not failed else "FAIL (%s)" % ", ".join(failed)))
    with open(os.path.join(REPORTS, 'regression_summary.txt'), 'w') as f:
        f.write("\n".join(lines) + "\n")

    cl = ["Functional coverage (event bins, merged over all tests)", "=" * 56]
    for i, name in enumerate(COV_NAMES):
        cl.append("[%s] %-22s %d" % ("HIT " if total_cov[i] else "MISS", name, total_cov[i]))
    cl.append("")
    cl.append("bins hit: %d / %d" % (hit, len(COV_NAMES)))
    with open(os.path.join(REPORTS, 'functional_coverage.txt'), 'w') as f:
        f.write("\n".join(cl) + "\n")

    print("\n" + "\n".join(lines[:12]))
    print("coverage: %d / %d bins (see reports/functional_coverage.txt)" % (hit, len(COV_NAMES)))
    return 1 if failed else 0


def mutation(args):
    progs = build_programs(args.random, args.seed0, args.body)
    os.makedirs(BUILD, exist_ok=True)
    lines = ["Bug-injection (mutation) sanity check", "=" * 40,
             "Each mutant is the RTL with one deliberate bug; the regression must FAIL on it.", ""]
    survivors = []
    for macro, desc in BUGS:
        sim = os.path.join(BUILD, 'mut_%s.vvp' % macro)
        ok, msg = compile_sim([macro], sim)
        if not ok:
            lines.append("%-24s COMPILE-ERROR  (%s)" % (macro, desc))
            survivors.append(macro)
            print(msg)
            continue
        caught_by, n_run = None, 0
        for p in progs:
            n_run += 1
            passed, _, _, _ = run_one(sim, p)
            if not passed:
                caught_by = p['name']
                break
        if caught_by:
            lines.append("%-24s CAUGHT by %-14s (%s)" % (macro, caught_by, desc))
        else:
            lines.append("%-24s SURVIVED all %d programs (%s)" % (macro, n_run, desc))
            survivors.append(macro)
        print(lines[-1])
    lines.append("")
    lines.append("caught %d / %d mutants" % (len(BUGS) - len(survivors), len(BUGS)))
    lines.append("FINAL: %s" % ("PASS" if not survivors else "FAIL (survivors: %s)" % ", ".join(survivors)))
    with open(os.path.join(REPORTS, 'mutation_summary.txt'), 'w') as f:
        f.write("\n".join(lines) + "\n")
    print("\n" + "\n".join(lines[-2:]))
    return 1 if survivors else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--random', type=int, default=40, help='number of random programs (default 40)')
    ap.add_argument('--seed0', type=int, default=1, help='first random seed (default 1)')
    ap.add_argument('--body', type=int, default=250, help='random program body length (default 250)')
    ap.add_argument('--mutate', action='store_true', help='run the bug-injection check instead')
    ap.add_argument('--waves', default='', help='dump waveforms/tb_rv32_core.vcd for this test name')
    ap.add_argument('--programs-only', action='store_true',
                    help='only assemble/generate programs and golden traces (no simulator needed)')
    args = ap.parse_args()

    if args.programs_only:
        progs = build_programs(args.random, args.seed0, args.body)
        print("built %d programs in %s" % (len(progs), os.path.join(BUILD, 'programs')))
        return 0
    os.makedirs(os.path.join(ROOT, 'waveforms'), exist_ok=True)
    return mutation(args) if args.mutate else regression(args)


if __name__ == '__main__':
    sys.exit(main())

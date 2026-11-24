#!/usr/bin/env python3
"""RV32I helpers for the pipeline-core project.

* encoders for the supported RV32I subset
* a small two-pass assembler (labels, li/mv/nop/j/beqz/bnez pseudo-instructions)
* a golden instruction-set simulator (ISS) that produces the retire trace the
  testbench compares against, bit for bit
* a constrained-random program generator

Run `python3 tools/rv32.py --selftest` to check the encoders, assembler and ISS
against known encodings and small programs.

Memory model (must match the RTL): Harvard, 1024-word instruction memory,
4 KiB data memory (zero-initialised), no misaligned access, no CSRs.
ECALL ends a program (it retires like a NOP and the testbench stops there).
"""
import random
import re
import sys

MASK = 0xFFFFFFFF
IMEM_WORDS = 1024
DMEM_BYTES = 4096
MARKER_ADDR = 0x1F0     # directed tests store PASS_VALUE here when every check passed
PASS_VALUE = 0x600D
FAIL_VALUE = 0x0BAD
NOP = 0x00000013
ECALL = 0x00000073

OP_LUI, OP_AUIPC, OP_JAL, OP_JALR = 0x37, 0x17, 0x6F, 0x67
OP_BRANCH, OP_LOAD, OP_STORE = 0x63, 0x03, 0x23
OP_OPIMM, OP_OP, OP_FENCE, OP_SYSTEM = 0x13, 0x33, 0x0F, 0x73


class AsmError(Exception):
    pass


class IssError(Exception):
    pass


def s32(x):
    x &= MASK
    return x - (1 << 32) if x & 0x80000000 else x


# --------------------------------------------------------------------------
# Encoders
# --------------------------------------------------------------------------
def enc_r(f7, rs2, rs1, f3, rd, op):
    return ((f7 & 0x7F) << 25) | ((rs2 & 31) << 20) | ((rs1 & 31) << 15) | \
           ((f3 & 7) << 12) | ((rd & 31) << 7) | op


def enc_i(imm, rs1, f3, rd, op):
    if not -2048 <= imm <= 2047:
        raise AsmError("I-type immediate out of range: %d" % imm)
    return ((imm & 0xFFF) << 20) | ((rs1 & 31) << 15) | ((f3 & 7) << 12) | \
           ((rd & 31) << 7) | op


def enc_s(imm, rs2, rs1, f3):
    if not -2048 <= imm <= 2047:
        raise AsmError("S-type immediate out of range: %d" % imm)
    imm &= 0xFFF
    return (((imm >> 5) & 0x7F) << 25) | ((rs2 & 31) << 20) | ((rs1 & 31) << 15) | \
           ((f3 & 7) << 12) | ((imm & 0x1F) << 7) | OP_STORE


def enc_b(imm, rs2, rs1, f3):
    if imm & 1 or not -4096 <= imm <= 4094:
        raise AsmError("branch offset out of range or odd: %d" % imm)
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | ((rs2 & 31) << 20) | \
           ((rs1 & 31) << 15) | ((f3 & 7) << 12) | (((imm >> 1) & 0xF) << 8) | \
           (((imm >> 11) & 1) << 7) | OP_BRANCH


def enc_u(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 31) << 7) | op


def enc_j(imm, rd):
    if imm & 1 or not -(1 << 20) <= imm < (1 << 20):
        raise AsmError("jal offset out of range or odd: %d" % imm)
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
           ((rd & 31) << 7) | OP_JAL


R_OPS = {'add': (0x00, 0), 'sub': (0x20, 0), 'sll': (0x00, 1), 'slt': (0x00, 2),
         'sltu': (0x00, 3), 'xor': (0x00, 4), 'srl': (0x00, 5), 'sra': (0x20, 5),
         'or': (0x00, 6), 'and': (0x00, 7)}
I_OPS = {'addi': 0, 'slti': 2, 'sltiu': 3, 'xori': 4, 'ori': 6, 'andi': 7}
SH_OPS = {'slli': (0x00, 1), 'srli': (0x00, 5), 'srai': (0x20, 5)}
LOAD_OPS = {'lb': 0, 'lh': 1, 'lw': 2, 'lbu': 4, 'lhu': 5}
STORE_OPS = {'sb': 0, 'sh': 1, 'sw': 2}
BR_OPS = {'beq': 0, 'bne': 1, 'blt': 4, 'bge': 5, 'bltu': 6, 'bgeu': 7}


def li_words(rd, value):
    """Words that load a 32-bit constant: 1 word if it fits addi, else lui+addi."""
    v = s32(value)
    if -2048 <= v <= 2047:
        return [enc_i(v, 0, 0, rd, OP_OPIMM)]
    lo = v & 0xFFF
    if lo >= 0x800:
        lo -= 0x1000
    hi = ((v - lo) >> 12) & 0xFFFFF
    return [enc_u(hi, rd, OP_LUI), enc_i(lo, rd, 0, rd, OP_OPIMM)]


# --------------------------------------------------------------------------
# Assembler
# --------------------------------------------------------------------------
_ABI = {'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4, 't0': 5, 't1': 6, 't2': 7,
        's0': 8, 'fp': 8, 's1': 9}
_ABI.update({'a%d' % i: 10 + i for i in range(8)})
_ABI.update({'s%d' % i: 16 + i for i in range(2, 12)})
_ABI.update({'t%d' % i: 25 + i for i in range(3, 7)})


def parse_reg(tok):
    tok = tok.strip()
    if tok in _ABI:
        return _ABI[tok]
    m = re.fullmatch(r'x(\d+)', tok)
    if m and int(m.group(1)) < 32:
        return int(m.group(1))
    raise AsmError("bad register '%s'" % tok)


def parse_imm(tok):
    try:
        return int(tok.strip(), 0)
    except ValueError:
        raise AsmError("bad immediate '%s'" % tok)


def parse_mem(tok):
    m = re.fullmatch(r'\s*(-?\w+)\s*\(\s*(\w+)\s*\)\s*', tok)
    if not m:
        raise AsmError("bad memory operand '%s'" % tok)
    return parse_imm(m.group(1)), parse_reg(m.group(2))


def _split(text):
    """Return (labels, items); each item is (lineno, mnemonic, operands, pc)."""
    labels, items, pc = {}, [], 0
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split('#')[0].strip()
        while ':' in line:
            lab, line = line.split(':', 1)
            lab = lab.strip()
            if not re.fullmatch(r'[A-Za-z_]\w*', lab):
                raise AsmError("line %d: bad label '%s'" % (lineno, lab))
            if lab in labels:
                raise AsmError("line %d: duplicate label '%s'" % (lineno, lab))
            labels[lab] = pc
            line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        mn = parts[0].lower()
        ops = [o.strip() for o in parts[1].split(',')] if len(parts) > 1 else []
        size = 1
        if mn == 'li':
            if len(ops) != 2:
                raise AsmError("line %d: li needs 2 operands" % lineno)
            size = len(li_words(parse_reg(ops[0]), parse_imm(ops[1])))
        items.append((lineno, mn, ops, pc))
        pc += 4 * size
    return labels, items


def _target(tok, labels, pc):
    tok = tok.strip()
    if tok in labels:
        return labels[tok] - pc
    return parse_imm(tok)


def assemble(text):
    labels, items = _split(text)
    words = []
    for lineno, mn, ops, pc in items:
        try:
            words.extend(_emit(mn, ops, pc, labels))
        except AsmError as e:
            raise AsmError("line %d: %s" % (lineno, e))
    return words


def _emit(mn, ops, pc, labels):
    def need(n):
        if len(ops) != n:
            raise AsmError("%s needs %d operands" % (mn, n))

    if mn in R_OPS:
        need(3)
        f7, f3 = R_OPS[mn]
        return [enc_r(f7, parse_reg(ops[2]), parse_reg(ops[1]), f3, parse_reg(ops[0]), OP_OP)]
    if mn in I_OPS:
        need(3)
        return [enc_i(parse_imm(ops[2]), parse_reg(ops[1]), I_OPS[mn], parse_reg(ops[0]), OP_OPIMM)]
    if mn in SH_OPS:
        need(3)
        f7, f3 = SH_OPS[mn]
        sh = parse_imm(ops[2])
        if not 0 <= sh < 32:
            raise AsmError("shift amount out of range")
        return [enc_i((f7 << 5) | sh, parse_reg(ops[1]), f3, parse_reg(ops[0]), OP_OPIMM)]
    if mn in LOAD_OPS:
        need(2)
        imm, base = parse_mem(ops[1])
        return [enc_i(imm, base, LOAD_OPS[mn], parse_reg(ops[0]), OP_LOAD)]
    if mn in STORE_OPS:
        need(2)
        imm, base = parse_mem(ops[1])
        return [enc_s(imm, parse_reg(ops[0]), base, STORE_OPS[mn])]
    if mn in BR_OPS:
        need(3)
        return [enc_b(_target(ops[2], labels, pc), parse_reg(ops[1]), parse_reg(ops[0]), BR_OPS[mn])]
    if mn == 'lui':
        need(2)
        return [enc_u(parse_imm(ops[1]), parse_reg(ops[0]), OP_LUI)]
    if mn == 'auipc':
        need(2)
        return [enc_u(parse_imm(ops[1]), parse_reg(ops[0]), OP_AUIPC)]
    if mn == 'jal':
        if len(ops) == 1:
            return [enc_j(_target(ops[0], labels, pc), 1)]
        need(2)
        return [enc_j(_target(ops[1], labels, pc), parse_reg(ops[0]))]
    if mn == 'jalr':
        need(2)
        imm, base = parse_mem(ops[1])
        return [enc_i(imm, base, 0, parse_reg(ops[0]), OP_JALR)]
    if mn == 'ecall':
        need(0)
        return [ECALL]
    # pseudo-instructions
    if mn == 'nop':
        need(0)
        return [NOP]
    if mn == 'li':
        need(2)
        return li_words(parse_reg(ops[0]), parse_imm(ops[1]))
    if mn == 'mv':
        need(2)
        return [enc_i(0, parse_reg(ops[1]), 0, parse_reg(ops[0]), OP_OPIMM)]
    if mn == 'j':
        need(1)
        return [enc_j(_target(ops[0], labels, pc), 0)]
    if mn == 'beqz':
        need(2)
        return [enc_b(_target(ops[1], labels, pc), 0, parse_reg(ops[0]), 0)]
    if mn == 'bnez':
        need(2)
        return [enc_b(_target(ops[1], labels, pc), 0, parse_reg(ops[0]), 1)]
    raise AsmError("unknown mnemonic '%s'" % mn)


# --------------------------------------------------------------------------
# Golden ISS
# --------------------------------------------------------------------------
def _alu(f3, alt, a, b):
    a &= MASK
    b &= MASK
    if f3 == 0:
        return (a - b if alt else a + b) & MASK
    if f3 == 1:
        return (a << (b & 31)) & MASK
    if f3 == 2:
        return int(s32(a) < s32(b))
    if f3 == 3:
        return int(a < b)
    if f3 == 4:
        return a ^ b
    if f3 == 5:
        return ((s32(a) >> (b & 31)) & MASK) if alt else (a >> (b & 31))
    if f3 == 6:
        return a | b
    return a & b


def _sx(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


class Iss:
    def __init__(self, words):
        if len(words) > IMEM_WORDS:
            raise IssError("program longer than instruction memory")
        self.imem = list(words) + [NOP] * (IMEM_WORDS - len(words))
        self.regs = [0] * 32
        self.mem = bytearray(DMEM_BYTES)
        self.pc = 0

    def _check(self, addr, size):
        if addr % size or addr < 0 or addr + size > DMEM_BYTES:
            raise IssError("bad data access: addr=0x%x size=%d" % (addr, size))

    def step(self):
        pc = self.pc
        if pc & 3 or not 0 <= pc < IMEM_WORDS * 4:
            raise IssError("bad pc 0x%x" % pc)
        insn = self.imem[pc >> 2]
        op = insn & 0x7F
        rd = (insn >> 7) & 31
        f3 = (insn >> 12) & 7
        rs1 = (insn >> 15) & 31
        rs2 = (insn >> 20) & 31
        r1, r2 = self.regs[rs1], self.regs[rs2]
        i_imm = _sx(insn >> 20, 12)
        nxt = pc + 4
        we, val, st = False, 0, None

        if op == OP_LUI:
            we, val = True, insn & 0xFFFFF000
        elif op == OP_AUIPC:
            we, val = True, (pc + (insn & 0xFFFFF000)) & MASK
        elif op == OP_JAL:
            imm = _sx(((insn >> 31) << 20) | (((insn >> 12) & 0xFF) << 12) |
                      (((insn >> 20) & 1) << 11) | (((insn >> 21) & 0x3FF) << 1), 21)
            we, val, nxt = True, pc + 4, (pc + imm) & MASK
        elif op == OP_JALR:
            we, val, nxt = True, pc + 4, ((r1 + i_imm) & MASK) & ~1
        elif op == OP_BRANCH:
            imm = _sx((((insn >> 31) & 1) << 12) | (((insn >> 7) & 1) << 11) |
                      (((insn >> 25) & 0x3F) << 5) | (((insn >> 8) & 0xF) << 1), 13)
            taken = {0: r1 == r2, 1: r1 != r2, 4: s32(r1) < s32(r2), 5: s32(r1) >= s32(r2),
                     6: r1 < r2, 7: r1 >= r2}.get(f3)
            if taken is None:
                raise IssError("illegal branch funct3 at pc 0x%x" % pc)
            if taken:
                nxt = (pc + imm) & MASK
        elif op == OP_LOAD:
            size = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}.get(f3)
            if size is None:
                raise IssError("illegal load funct3 at pc 0x%x" % pc)
            addr = (r1 + i_imm) & MASK
            self._check(addr, size)
            raw = int.from_bytes(self.mem[addr:addr + size], 'little')
            if f3 in (0, 1):
                raw = _sx(raw, 8 * size) & MASK
            we, val = True, raw
        elif op == OP_STORE:
            size = {0: 1, 1: 2, 2: 4}.get(f3)
            if size is None:
                raise IssError("illegal store funct3 at pc 0x%x" % pc)
            imm = _sx(((insn >> 25) << 5) | ((insn >> 7) & 0x1F), 12)
            addr = (r1 + imm) & MASK
            self._check(addr, size)
            data = r2 & ((1 << (8 * size)) - 1)
            self.mem[addr:addr + size] = data.to_bytes(size, 'little')
            st = (f3 & 3, addr, data)
        elif op == OP_OPIMM:
            alt = (insn >> 30) & 1
            if f3 == 0:
                alt = 0
            we, val = True, _alu(f3, alt, r1, i_imm)
        elif op == OP_OP:
            we, val = True, _alu(f3, (insn >> 30) & 1, r1, r2)
        elif op == OP_SYSTEM:
            if insn != ECALL:
                raise IssError("unsupported SYSTEM instruction 0x%08x" % insn)
        elif op == OP_FENCE:
            pass
        else:
            raise IssError("illegal opcode in 0x%08x at pc 0x%x" % (insn, pc))

        we = we and rd != 0
        if we:
            self.regs[rd] = val & MASK
        self.pc = nxt
        return {'pc': pc, 'insn': insn, 'we': we, 'rd': rd if we else 0,
                'rd_data': (val & MASK) if we else 0, 'st': st}

    def run(self, max_steps=200000):
        trace = []
        for _ in range(max_steps):
            e = self.step()
            trace.append(e)
            if e['insn'] == ECALL:
                return trace
        raise IssError("no ECALL within %d steps" % max_steps)


def trace_line(e):
    rdinfo = (int(e['we']) << 5) | e['rd']
    if e['st'] is None:
        stinfo, st_addr, st_data = 0, 0, 0
    else:
        size, st_addr, st_data = e['st']
        stinfo = (1 << 2) | size
    return "%08x%08x%02x%08x%02x%08x%08x" % (
        e['pc'], e['insn'], rdinfo, e['rd_data'], stinfo, st_addr, st_data)


def write_hex(path, words):
    with open(path, 'w') as f:
        for w in words:
            f.write("%08x\n" % (w & MASK))


def write_trace(path, trace):
    with open(path, 'w') as f:
        f.write("%044x\n" % len(trace))
        for e in trace:
            f.write(trace_line(e) + "\n")


def marker_passed(trace):
    """True if the last store to MARKER_ADDR wrote PASS_VALUE."""
    last = None
    for e in trace:
        if e['st'] and e['st'][1] == MARKER_ADDR:
            last = e['st'][2]
    return last == PASS_VALUE


# --------------------------------------------------------------------------
# Constrained-random program generator
# --------------------------------------------------------------------------
def _land(idx, k, end, jalr_slots):
    """Target index for a forward skip of k instructions, never inside a JALR pair."""
    t = min(idx + 1 + k, end)
    while t in jalr_slots:
        t += 1
    return t


def gen_random_program(seed, n=250):
    """Random program of about n body instructions ending in ECALL.

    Register roles: x28 = data base (0x100, never overwritten), x27 = JALR scratch,
    x1..x12 = working pool (small pool => many dependencies). All branches and jumps go
    forward by 1-3 instructions, so every program terminates. Loads/stores stay in
    0x100..0x1FF and are naturally aligned.
    """
    rng = random.Random(seed)
    pool = list(range(1, 13))
    prelude = [enc_i(0x100, 0, 0, 28, OP_OPIMM)]
    for r in pool:
        v = rng.getrandbits(32) if rng.random() < 0.5 else rng.randint(-64, 64)
        prelude += li_words(r, v)
    p0 = len(prelude)
    end = p0 + n                      # index of the final ECALL
    body = []                         # items: ('w', word) | ('br', f3, rs1, rs2, k) | ('jal', rd, k)
    jalr_slots = set()                # indices of JALR instructions: never a branch/jal target
    recent = []

    def src():
        if recent and rng.random() < 0.6:
            return rng.choice(recent[-3:])
        return rng.choice([0] + pool)

    def dst():
        r = rng.choice(pool) if rng.random() < 0.95 else 0
        if r:
            recent.append(r)
        return r

    def rimm():
        c = rng.random()
        if c < 0.4:
            return rng.randint(-8, 8)
        if c < 0.6:
            return rng.choice([-2048, 2047, 0, -1, 1])
        return rng.randint(-2048, 2047)

    while len(body) < n:
        idx = p0 + len(body)
        remaining = end - idx
        r = rng.random()
        if r < 0.22:
            mn = rng.choice(sorted(R_OPS))
            f7, f3 = R_OPS[mn]
            body.append(('w', enc_r(f7, src(), src(), f3, dst(), OP_OP)))
        elif r < 0.44:
            f3 = rng.choice(sorted(I_OPS.values()))
            body.append(('w', enc_i(rimm(), src(), f3, dst(), OP_OPIMM)))
        elif r < 0.50:
            f7, f3 = SH_OPS[rng.choice(sorted(SH_OPS))]
            body.append(('w', enc_i((f7 << 5) | rng.randint(0, 31), src(), f3, dst(), OP_OPIMM)))
        elif r < 0.54:
            op = rng.choice([OP_LUI, OP_AUIPC])
            body.append(('w', enc_u(rng.getrandbits(20), dst(), op)))
        elif r < 0.66:
            f3 = rng.choice(sorted(LOAD_OPS.values()))
            size = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}[f3]
            off = rng.randrange(0, 256, size)
            body.append(('w', enc_i(off, 28, f3, dst(), OP_LOAD)))
        elif r < 0.76:
            f3 = rng.choice(sorted(STORE_OPS.values()))
            size = {0: 1, 1: 2, 2: 4}[f3]
            off = rng.randrange(0, 256, size)
            body.append(('w', enc_s(off, src(), 28, f3)))
        elif r < 0.88:
            body.append(('br', rng.choice(sorted(BR_OPS.values())), src(), src(), rng.randint(1, 3)))
        elif r < 0.92:
            body.append(('jal', dst() if rng.random() < 0.5 else 0, rng.randint(1, 3)))
        elif r < 0.95 and remaining >= 4:
            jalr_slots.add(idx + 1)
            body.append(('w', enc_u(0, 27, OP_AUIPC)))                  # x27 = pc
            body.append(('w', enc_i(12, 27, 0, dst(), OP_JALR)))        # jump to pc+12, skipping 1
            body.append(('w', enc_i(rng.randint(-8, 8), src(), 0, dst(), OP_OPIMM)))  # skipped filler
        else:
            body.append(('w', enc_i(rimm(), src(), 0, 0, OP_OPIMM)))    # write to x0 (ignored)

    words = list(prelude)
    for i, item in enumerate(body):
        idx = p0 + i
        if item[0] == 'w':
            words.append(item[1])
        elif item[0] == 'br':
            _, f3, a, b, k = item
            words.append(enc_b(4 * (_land(idx, k, end, jalr_slots) - idx), b, a, f3))
        else:
            _, rd, k = item
            words.append(enc_j(4 * (_land(idx, k, end, jalr_slots) - idx), rd))
    words.append(ECALL)
    return words


# --------------------------------------------------------------------------
# Self-test
# --------------------------------------------------------------------------
def selftest():
    known = [
        (enc_i(1, 0, 0, 1, OP_OPIMM), 0x00100093),            # addi x1,x0,1
        (enc_r(0x00, 2, 1, 0, 3, OP_OP), 0x002081B3),         # add x3,x1,x2
        (enc_r(0x20, 2, 1, 0, 3, OP_OP), 0x402081B3),         # sub x3,x1,x2
        (enc_i(4, 2, 2, 5, OP_LOAD), 0x00412283),             # lw x5,4(x2)
        (enc_s(8, 5, 2, 2), 0x00512423),                      # sw x5,8(x2)
        (enc_b(8, 2, 1, 0), 0x00208463),                      # beq x1,x2,+8
        (enc_b(-4, 0, 0, 0), 0xFE000EE3),                     # beq x0,x0,-4
        (enc_j(8, 1), 0x008000EF),                            # jal x1,+8
        (enc_j(-4, 0), 0xFFDFF06F),                           # jal x0,-4
        (enc_u(0x12345, 1, OP_LUI), 0x123450B7),              # lui x1,0x12345
        (enc_u(0, 1, OP_AUIPC), 0x00000097),                  # auipc x1,0
        (enc_i(0x403, 2, 5, 1, OP_OPIMM), 0x40315093),        # srai x1,x2,3
        (enc_i(0, 1, 0, 0, OP_JALR), 0x00008067),             # jalr x0,0(x1)
        (enc_s(-1, 1, 2, 0), 0xFE110FA3),                     # sb x1,-1(x2)
        (ECALL, 0x00000073),
    ]
    for got, exp in known:
        assert got == exp, "encoding mismatch: got %08x expected %08x" % (got, exp)

    # assembler agrees with the encoders, including labels and pseudo-instructions
    prog = assemble("""
        start: addi x1, x0, 1
               add  x3, x1, x2
               beq  x1, x2, start     # backward
               j    end
               nop
        end:   ecall
    """)
    assert prog[0] == 0x00100093 and prog[1] == 0x002081B3
    assert prog[2] == enc_b(-8, 2, 1, 0)
    assert prog[3] == enc_j(8, 0)
    assert prog[-1] == ECALL

    # li round trip for awkward constants
    for v in [0, 1, -1, 2047, 2048, -2048, -2049, 0x7FFFF800, 0x12345678, 0xABCDE000,
              0x80000000, 0xFFFFF800, 0xFFFFFFFF, 0x7FFFFFFF]:
        iss = Iss(li_words(5, v) + [ECALL])
        iss.run()
        assert iss.regs[5] == v & MASK, "li failed for 0x%x -> 0x%x" % (v, iss.regs[5])

    # ISS semantics on a few hand-computed cases
    def run_asm(src):
        iss = Iss(assemble(src + "\n ecall"))
        tr = iss.run()
        return iss, tr

    iss, _ = run_asm("li x1,-8\n li x2,4\n sra x3,x1,x2\n srl x4,x1,x2\n slt x5,x1,x2\n sltu x6,x1,x2")
    assert iss.regs[3] == MASK and iss.regs[4] == 0x0FFFFFFF and iss.regs[5] == 1 and iss.regs[6] == 0
    iss, _ = run_asm("li x1,0x8899AABB\n li x28,256\n sw x1,0(x28)\n lb x2,0(x28)\n lbu x3,3(x28)\n"
                     "lh x4,2(x28)\n lhu x5,0(x28)")
    assert iss.regs[2] == 0xFFFFFFBB and iss.regs[3] == 0x88 and iss.regs[4] == 0xFFFF8899 \
        and iss.regs[5] == 0xAABB
    iss, tr = run_asm("addi x0,x0,5\n add x1,x0,x0")
    assert iss.regs[0] == 0 and iss.regs[1] == 0 and tr[0]['we'] is False and tr[0]['rd'] == 0
    iss, tr = run_asm("auipc x5,0\n jalr x6,12(x5)\n j end\n sub x3,x6,x5\n end: nop")
    assert iss.regs[6] - iss.regs[5] == 8
    assert len(tr) == 5       # auipc, jalr, sub, nop, ecall (the j is jumped over)
    # trace format: one store, check packing
    e = {'pc': 0x10, 'insn': 0x00512423, 'we': False, 'rd': 0, 'rd_data': 0, 'st': (2, 0x108, 0x1234)}
    assert trace_line(e) == "00000010" "00512423" "00" "00000000" "06" "00000108" "00001234"
    print("selftest: OK")


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--selftest':
        selftest()
    else:
        print(__doc__)

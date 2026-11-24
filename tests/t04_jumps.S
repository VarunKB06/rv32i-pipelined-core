# t04_jumps: JAL / JALR link values and targets.
    jal  x1, target1         # x1 = address of the next instruction
    j    fail                # skipped
target1:
    auipc x2, 0              # x2 = address of this instruction = x1 + 4
    sub  x3, x2, x1
    li   x4, 4
    bne  x3, x4, fail
    # JALR forward by 12 from an AUIPC base, link = jalr address + 4
    auipc x5, 0              # x5 = P
    jalr x6, 12(x5)          # jumps to P+12, x6 = P+8
    j    fail                # at P+8, skipped
    sub  x3, x6, x5          # at P+12
    li   x4, 8
    bne  x3, x4, fail
    # JALR where rd == rs1
    auipc x7, 0              # x7 = Q
    jalr x7, 12(x7)          # jumps to Q+12, x7 = Q+8
    j    fail
    auipc x8, 0              # at Q+12
    sub  x3, x8, x7          # (Q+12) - (Q+8) = 4
    li   x4, 4
    bne  x3, x4, fail
    # JALR clears bit 0 of the target
    auipc x9, 0              # x9 = R
    addi x9, x9, 17          # x9 = R+17 (odd); JALR clears bit 0 -> target R+16
    jalr x0, 0(x9)           # at R+8
    j    fail                # at R+12
    nop                      # at R+16 : landing point
    auipc x10, 0             # at R+20
    sub  x3, x10, x9         # (R+20) - (R+17) = 3
    li   x4, 3
    bne  x3, x4, fail
    # JAL with x0 as link must not change x0
    jal  x0, after
    j    fail
after:
    bne  x0, x0, fail
pass:
    li   x29, 0x1F0
    li   x30, 0x600D
    sw   x30, 0(x29)
    ecall
fail:
    li   x29, 0x1F0
    li   x30, 0x0BAD
    sw   x30, 0(x29)
    ecall

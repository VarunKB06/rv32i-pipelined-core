# t03_branches: all six branch types, taken and not taken, forward and backward.
    li   x1, 5
    li   x2, 5
    li   x3, -1              # 0xFFFFFFFF
    li   x4, 1
    beq  x1, x2, b1
    j    fail
b1: bne  x1, x2, fail        # not taken
    bne  x1, x4, b2
    j    fail
b2: beq  x1, x4, fail        # not taken
    blt  x3, x4, b3          # -1 < 1 signed
    j    fail
b3: blt  x4, x3, fail        # 1 < -1 false
    bge  x4, x3, b4          # 1 >= -1
    j    fail
b4: bge  x3, x4, fail        # -1 >= 1 false
    bltu x4, x3, b5          # 1 < 0xFFFFFFFF unsigned
    j    fail
b5: bltu x3, x4, fail
    bgeu x3, x4, b6
    j    fail
b6: bgeu x4, x3, fail
    bge  x1, x2, b7          # equal -> taken
    j    fail
b7: bgeu x1, x2, b8
    j    fail
b8: blt  x1, x2, fail        # equal -> not taken
    bltu x1, x2, fail
    # backward branch loop: count to 10
    li   x5, 0
    li   x6, 10
loop:
    addi x5, x5, 1
    bne  x5, x6, loop
    bne  x5, x6, fail
    # taken branch over an instruction that would corrupt x7
    li   x7, 1
    beq  x0, x0, skip
    li   x7, 99              # must be flushed
skip:
    bne  x7, x4, fail
    # two taken branches back to back
    beq  x0, x0, t1
    li   x7, 98
t1: beq  x0, x0, t2
    li   x7, 97
t2: bne  x7, x4, fail
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

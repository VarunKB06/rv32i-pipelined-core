# t01_alu: register-register and register-immediate ALU operations with self-checks.
# Convention: any failed check branches to 'fail'. x29/x30 are reserved for the PASS/FAIL marker.
    li   x1, 15
    li   x2, 4
    li   x5, -8
    add  x3, x1, x2          # 19
    li   x4, 19
    bne  x3, x4, fail
    sub  x3, x1, x2          # 11
    li   x4, 11
    bne  x3, x4, fail
    sub  x3, x2, x1          # -11
    li   x4, -11
    bne  x3, x4, fail
    sll  x3, x1, x2          # 240
    li   x4, 240
    bne  x3, x4, fail
    slt  x3, x5, x1          # -8 < 15 signed -> 1
    li   x4, 1
    bne  x3, x4, fail
    sltu x3, x5, x1          # 0xFFFFFFF8 < 15 unsigned -> 0
    bne  x3, x0, fail
    slt  x3, x1, x5          # 15 < -8 -> 0
    bne  x3, x0, fail
    xor  x3, x1, x2          # 15 ^ 4 = 11
    li   x4, 11
    bne  x3, x4, fail
    srl  x3, x5, x2          # 0xFFFFFFF8 >> 4 = 0x0FFFFFFF
    li   x4, 0x0FFFFFFF
    bne  x3, x4, fail
    sra  x3, x5, x2          # -8 >>> 4 = -1
    li   x4, -1
    bne  x3, x4, fail
    or   x3, x1, x2          # 15
    li   x4, 15
    bne  x3, x4, fail
    and  x3, x1, x2          # 4
    li   x4, 4
    bne  x3, x4, fail
    # immediates
    addi x3, x1, -20         # -5
    li   x4, -5
    bne  x3, x4, fail
    slti x3, x5, -7          # -8 < -7 -> 1
    li   x4, 1
    bne  x3, x4, fail
    sltiu x3, x5, -7         # 0xFFFFFFF8 < 0xFFFFFFF9 -> 1
    bne  x3, x4, fail
    xori x3, x1, 255         # 15 ^ 255 = 240
    li   x4, 240
    bne  x3, x4, fail
    ori  x3, x2, 48          # 4 | 0x30 = 0x34
    li   x4, 0x34
    bne  x3, x4, fail
    andi x3, x1, 6           # 6
    li   x4, 6
    bne  x3, x4, fail
    slli x3, x2, 28          # 0x40000000
    li   x4, 0x40000000
    bne  x3, x4, fail
    srli x3, x5, 28          # 0xF
    li   x4, 15
    bne  x3, x4, fail
    srai x3, x5, 1           # -4
    li   x4, -4
    bne  x3, x4, fail
    # shift edge cases and boundaries
    slli x3, x1, 0           # unchanged
    bne  x3, x1, fail
    li   x6, 0x80000000      # INT_MIN
    srai x3, x6, 31          # -1
    li   x4, -1
    bne  x3, x4, fail
    srli x3, x6, 31          # 1
    li   x4, 1
    bne  x3, x4, fail
    slt  x3, x6, x0          # INT_MIN < 0 -> 1
    bne  x3, x4, fail
    sltu x3, x6, x0          # unsigned: not < 0 -> 0
    bne  x3, x0, fail
    li   x7, 0x7FFFFFFF
    addi x3, x7, 1           # wraps to INT_MIN
    bne  x3, x6, fail
    # LUI / AUIPC
    lui  x3, 0xABCDE
    li   x4, 0xABCDE000
    bne  x3, x4, fail
    auipc x3, 0
    auipc x4, 0
    sub  x8, x4, x3          # consecutive AUIPCs differ by 4
    li   x9, 4
    bne  x8, x9, fail
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

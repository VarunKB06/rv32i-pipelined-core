# t02_loadstore: byte/half/word loads and stores, sign/zero extension, sub-word merging.
    li   x28, 0x100
    li   x1, 0x8899AABB
    sw   x1, 0(x28)
    lw   x2, 0(x28)
    bne  x2, x1, fail
    lbu  x3, 0(x28)          # 0xBB
    li   x4, 0xBB
    bne  x3, x4, fail
    lbu  x3, 1(x28)          # 0xAA
    li   x4, 0xAA
    bne  x3, x4, fail
    lbu  x3, 2(x28)          # 0x99
    li   x4, 0x99
    bne  x3, x4, fail
    lbu  x3, 3(x28)          # 0x88
    li   x4, 0x88
    bne  x3, x4, fail
    lb   x3, 0(x28)          # 0xBB sign-extended = -69
    li   x4, -69
    bne  x3, x4, fail
    lb   x3, 3(x28)          # 0x88 sign-extended = -120
    li   x4, -120
    bne  x3, x4, fail
    lb   x3, 1(x28)          # 0xAA = -86
    li   x4, -86
    bne  x3, x4, fail
    lh   x3, 0(x28)          # 0xAABB = -21829
    li   x4, -21829
    bne  x3, x4, fail
    lh   x3, 2(x28)          # 0x8899 = -30567
    li   x4, -30567
    bne  x3, x4, fail
    lhu  x3, 0(x28)          # 0xAABB = 43707
    li   x4, 43707
    bne  x3, x4, fail
    lhu  x3, 2(x28)          # 0x8899 = 34969
    li   x4, 34969
    bne  x3, x4, fail
    # sub-word stores merge into a zeroed word
    sw   x0, 4(x28)
    li   x5, 0x7F
    sb   x5, 5(x28)
    lw   x3, 4(x28)          # 0x00007F00
    li   x4, 0x7F00
    bne  x3, x4, fail
    li   x5, 0xCAFE
    sh   x5, 6(x28)
    lw   x3, 4(x28)          # 0xCAFE7F00
    li   x4, 0xCAFE7F00
    bne  x3, x4, fail
    li   x5, 0x11
    sb   x5, 4(x28)
    lw   x3, 4(x28)          # 0xCAFE7F11
    li   x4, 0xCAFE7F11
    bne  x3, x4, fail
    li   x5, 0x22
    sb   x5, 7(x28)
    li   x5, 0x33
    sb   x5, 6(x28)
    lw   x3, 4(x28)          # 0x2233 7F11 -> 0x22337F11
    li   x4, 0x22337F11
    bne  x3, x4, fail
    # store then immediate load of the same word
    li   x5, 77
    sw   x5, 8(x28)
    lw   x3, 8(x28)
    bne  x3, x5, fail
    # negative base offsets
    addi x6, x28, 16
    li   x5, 1234
    sw   x5, -4(x6)          # address 0x10C
    lw   x3, 12(x28)
    bne  x3, x5, fail
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

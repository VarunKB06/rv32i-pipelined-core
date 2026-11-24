# t07_x0: x0 is hardwired to zero, including as a forwarding source and as a load destination.
    addi x0, x0, 5
    add  x1, x0, x0          # must be 0 (no forwarding of the discarded write)
    bne  x1, x0, fail
    li   x2, 9
    add  x0, x2, x2
    addi x3, x0, 0
    bne  x3, x0, fail
    li   x28, 0x100
    sw   x2, 0(x28)
    lw   x0, 0(x28)          # load into x0 is discarded
    add  x3, x0, x0
    bne  x3, x0, fail
    jal  x0, here
    j    fail
here:
    addi x4, x0, 7           # x4 = 7
    li   x5, 7
    bne  x4, x5, fail
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

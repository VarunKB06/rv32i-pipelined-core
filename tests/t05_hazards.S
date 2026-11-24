# t05_hazards: forwarding, load-use stalls, WB->ID bypass, redirects with dependent operands.
    # EX/MEM and MEM/WB forwarding, both operands forwarded
    li   x1, 1
    addi x2, x1, 1           # 2   (x1 forwarded, distance 1)
    addi x3, x2, 1           # 3   (x2 forwarded, distance 1)
    add  x4, x2, x3          # 5   (x2 from MEM/WB, x3 from EX/MEM)
    add  x5, x4, x4          # 10  (same register both operands)
    li   x6, 5
    bne  x4, x6, fail
    li   x6, 10
    bne  x5, x6, fail
    # same destination written back to back: the younger value must win
    addi x7, x0, 1
    addi x7, x0, 2
    addi x7, x0, 3
    add  x8, x7, x0
    li   x6, 3
    bne  x8, x6, fail
    # distance 3: register-file bypass in ID
    addi x9, x0, 9
    nop
    nop
    add  x10, x9, x0
    li   x6, 9
    bne  x10, x6, fail
    # load-use
    li   x28, 0x100
    li   x1, 123
    sw   x1, 0(x28)
    lw   x2, 0(x28)
    addi x3, x2, 1           # needs one stall
    li   x6, 124
    bne  x3, x6, fail
    # load -> store data
    lw   x2, 0(x28)
    sw   x2, 4(x28)
    lw   x4, 4(x28)
    li   x6, 123
    bne  x4, x6, fail
    # load -> branch operand
    lw   x2, 0(x28)
    beq  x2, x1, lb_ok
    j    fail
lb_ok:
    # load -> load address (base register)
    li   x5, 0x100
    sw   x5, 8(x28)
    lw   x2, 8(x28)          # x2 = 0x100
    lw   x3, 0(x2)           # address from the load; loads 123
    li   x6, 123
    bne  x3, x6, fail
    # ALU result forwarded into store data
    li   x2, 55
    sw   x2, 12(x28)
    lw   x3, 12(x28)
    li   x6, 55
    bne  x3, x6, fail
    # forwarded operands into a branch compare
    addi x2, x0, 7
    addi x3, x0, 7
    beq  x2, x3, fb_ok
    j    fail
fb_ok:
    # forwarded base into JALR: auipc, addi, jalr back to back
    auipc x5, 0              # P
    addi  x5, x5, 16         # P+16
    jalr  x0, 0(x5)          # at P+8
    j     fail               # at P+12
    nop                      # at P+16 landing point
    # load-use where the consumer also needs an older producer
    li   x1, 10
    li   x2, 20
    sw   x1, 16(x28)
    lw   x3, 16(x28)
    add  x4, x3, x2          # x3 via stall, x2 via normal path
    li   x6, 30
    bne  x4, x6, fail
    # consecutive loads feeding consecutive uses
    sw   x2, 20(x28)
    lw   x3, 16(x28)
    lw   x4, 20(x28)
    add  x5, x3, x4
    li   x6, 30
    bne  x5, x6, fail
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

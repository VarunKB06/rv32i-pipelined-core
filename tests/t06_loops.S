# t06_loops: Fibonacci and an array sum (load-use stalls inside a loop).
    li   x1, 0
    li   x2, 1
    li   x3, 10
fib:
    add  x4, x1, x2
    mv   x1, x2
    mv   x2, x4
    addi x3, x3, -1
    bnez x3, fib
    li   x5, 55              # fib(10)
    bne  x1, x5, fail
    # store 1..8, then sum them back
    li   x28, 0x100
    li   x6, 1
    li   x7, 9
    mv   x8, x28
st: sw   x6, 0(x8)
    addi x6, x6, 1
    addi x8, x8, 4
    bne  x6, x7, st
    li   x5, 0
    li   x6, 8
    mv   x8, x28
sum:
    lw   x9, 0(x8)
    add  x5, x5, x9
    addi x8, x8, 4
    addi x6, x6, -1
    bnez x6, sum
    li   x10, 36
    bne  x5, x10, fail
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

    .text
    .globl _start
_start:
    // x0 = Apple UART base (t8030 UART0 = 0x235200000)
    movz x0, #0x3520, lsl #16
    movk x0, #0x2, lsl #32
    adr  x1, msg
loop:
    ldrb w2, [x1], #1
    cbz  w2, calc
    str  w2, [x0, #0x20]
    b    loop
calc:
    // sum 1..10 = 55, print as two decimal digits + newline
    mov  x3, #0
    mov  x4, #1
sum:
    add  x3, x3, x4
    add  x4, x4, #1
    cmp  x4, #11
    b.lt sum
    mov  x5, #10
    udiv x6, x3, x5
    msub x7, x6, x5, x3
    add  w6, w6, #48
    str  w6, [x0, #0x20]
    add  w7, w7, #48
    str  w7, [x0, #0x20]
    mov  w2, #10
    str  w2, [x0, #0x20]
    hlt  #0
msg:
    .asciz "test\n"

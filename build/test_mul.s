.text
.globl _start
_start:
  // smull: (-3) * 7 = -21
  mov w8, #-3
  mov w9, #7
  smull x10, w8, w9
  // smaddl: 100 + (-3)*7 = 79
  mov x11, #100
  smaddl x11, w8, w9, x11
  // smsubl: 100 - (-3)*7 = 121
  mov x12, #100
  smsubl x12, w8, w9, x12
  // smulh: (2^60) * 16 = 2^64 -> high 1 ; (-2^63) * 2 -> high -1
  mov x8, #1
  lsl x8, x8, #60
  mov x9, #16
  smulh x13, x8, x9
  mov x8, #1
  lsl x8, x8, #63
  mov x9, #2
  smulh x14, x8, x9
  // umull: (2^32-1)^2
  mov w8, #0xffffffff
  mov w9, #0xffffffff
  umull x15, w8, w9
  // umaddl: 5 + (2^32-1)^2
  mov x16, #5
  umaddl x16, w8, w9, x16
  // umsubl: (2^32-1)^2 - 5 ... use acc = product, sub small: acc=10, prod=3*4=12 -> -2
  mov w8, #3
  mov w9, #4
  mov x17, #10
  umsubl x17, w8, w9, x17
  // umulh: (2^64-1)^2 -> high 2^64-2
  mov x8, #-1
  mov x9, #-1
  umulh x18, x8, x9
  // LDR (SIMD literal): q5 from pool, d6, s7; x5 sentinel must survive
  mov x5, #0x777
  ldr q5, pool_q
  ldr d6, pool_d
  ldr s7, pool_s
  movz x19, #0x2, lsl #16
  movk x19, #0x8, lsl #32
  str q5, [x19]
  str d6, [x19, #16]
  str s7, [x19, #24]
  wfi
pool_q: .quad 0x0706050403020100, 0x0f0e0d0c0b0a0908
pool_d: .quad 0x1122334455667788
pool_s: .word 0xcafebabe

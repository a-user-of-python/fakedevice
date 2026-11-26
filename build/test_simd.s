.text
.globl _start
_start:
	movz x28, #0x2, lsl #16
	movk x28, #0x8, lsl #32
	movz x9, #0x3, lsl #16
	movk x9, #0x8, lsl #32
	mov sp, x9
	// 1: movi v0.2d, #0 -> [0x00]
	movi v0.2d, #0
	str q0, [x28, #0x00]
	// 2: movi v1.16b, #0x41 -> [0x10]
	movi v1.16b, #0x41
	str q1, [x28, #0x10]
	// 3: movi v2.4s, #1, lsl #8 -> [0x20]
	movi v2.4s, #1, lsl #8
	str q2, [x28, #0x20]
	// 4: mvni v3.4s, #0 -> [0x30]
	mvni v3.4s, #0
	str q3, [x28, #0x30]
	// 5: movi v4.8h, #0xff -> [0x40]
	movi v4.8h, #0xff
	str q4, [x28, #0x40]
	// build vA (bytes 0..15) and vB (bytes 16..31) via stack
	movz x0, #0x0100
	movk x0, #0x0302, lsl #16
	movk x0, #0x0504, lsl #32
	movk x0, #0x0706, lsl #48
	movz x1, #0x0908
	movk x1, #0x0b0a, lsl #16
	movk x1, #0x0d0c, lsl #32
	movk x1, #0x0f0e, lsl #48
	str x0, [sp, #-16]
	str x1, [sp, #-8]
	ldr q5, [sp, #-16]
	movz x0, #0x1110
	movk x0, #0x1312, lsl #16
	movk x0, #0x1514, lsl #32
	movk x0, #0x1716, lsl #48
	movz x1, #0x1918
	movk x1, #0x1b1a, lsl #16
	movk x1, #0x1d1c, lsl #32
	movk x1, #0x1f1e, lsl #48
	str x0, [sp, #-16]
	str x1, [sp, #-8]
	ldr q6, [sp, #-16]
	// 6: add v8.16b = v5 + v6 -> [0x50]
	add v8.16b, v5.16b, v6.16b
	str q8, [x28, #0x50]
	// 7: sub v9.16b = v6 - v5 -> [0x60]
	sub v9.16b, v6.16b, v5.16b
	str q9, [x28, #0x60]
	// 8: and/orr/eor -> [0x70]/[0x80]/[0x90]
	and v10.16b, v5.16b, v6.16b
	str q10, [x28, #0x70]
	orr v11.16b, v5.16b, v6.16b
	str q11, [x28, #0x80]
	eor v12.16b, v5.16b, v6.16b
	str q12, [x28, #0x90]
	// 9: fmov d13, x0 ; str d13 -> [0xa0] ; fmov x9, d13
	mov x0, #0x5678
	movk x0, #0x1234, lsl #16
	movk x0, #0xbeef, lsl #32
	movk x0, #0xdead, lsl #48
	fmov d13, x0
	str d13, [x28, #0xa0]
	fmov x9, d13
	// 10: dup v14.16b, w10 (0xab) -> [0xb0]
	mov w10, #0xab
	dup v14.16b, w10
	str q14, [x28, #0xb0]
	// 11: mov v15.b[3], w11src ; umov w11, v15.b[3]
	movi v15.2d, #0
	mov w10, #0xcd
	mov v15.b[3], w10
	str q15, [x28, #0xc0]
	umov w11, v15.b[3]
	// 12: stp q1, q2, [sp, #-32]! ; zero them ; ldp q1, q2, [sp], #32 -> [0xd0] = q1 pattern
	stp q1, q2, [sp, #-32]!
	movi v1.2d, #0
	movi v2.2d, #0
	ldp q1, q2, [sp], #32
	str q1, [x28, #0xd0]
	str q2, [x28, #0xe0]
	// 13: stnp/ldnp x0, x1 at [0x100]
	mov x0, #0x1111111111111111
	mov x1, #0x2222222222222222
	add x27, x28, #0x100
	stnp x0, x1, [x27]
	ldnp x2, x3, [x27]
	// 14: dp1: rbit x12, x0 ; clz x13, x4 ; rev x14, x0
	rbit x12, x0
	mov x4, #0x1000
	clz x13, x4
	rev x14, x0
	// 15: paciasp/retaa subroutine
	bl sub1
	// 16: stur/ldur q round trip at [0xf0]/[0x110]
	movi v16.16b, #0x5a
	stur q16, [x28, #0xf0]
	ldur q17, [x28, #0xf0]
	str q17, [x28, #0x110]
	// 17: str s / ldr s at [0x120]/[0x124]
	mov w10, #0xccdd
	movk w10, #0xaabb, lsl #16
	fmov s18, w10
	str s18, [x28, #0x120]
	ldr s19, [x28, #0x120]
	str s19, [x28, #0x124]
	// 18: movi v20.2d, #0xffffffffffffffff -> [0x130]
	movi v20.2d, #0xffffffffffffffff
	str q20, [x28, #0x130]
	wfi
sub1:
	paciasp
	mov x16, #0x1234
	retaa

import { readFileSync } from 'fs';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { createMachine } = require('./emu.js');
const bin = new Uint8Array(readFileSync('/tmp/test_simd.bin'));
const m = createMachine(() => {}, () => {});
m.loadBytes(0x800010000n, bin);
m.pc = 0x800010000n;
m.run(100000);
let pass = 0, fail = 0;
function chk(name, cond) { if (cond) { pass++; } else { fail++; console.log('FAIL:', name); } }
function bytesAt(addr, n) { const out = []; for (let i = 0; i < n; i++) out.push(Number(m.readPhys(BigInt(addr + i), 1))); return out; }
function eqArr(name, got, want) { chk(name, got.length === want.length && got.every((x, i) => x === want[i])); }
const R = 0x800020000;
chk('halted with wfi', m.status === 'wfi');
eqArr('movi 2d #0', bytesAt(R + 0x00, 16), Array(16).fill(0));
eqArr('movi 16b #0x41', bytesAt(R + 0x10, 16), Array(16).fill(0x41));
eqArr('movi 4s #1 lsl8', bytesAt(R + 0x20, 16), Array.from({length: 16}, (_, i) => [0, 1, 0, 0][i % 4]));
eqArr('mvni 4s #0', bytesAt(R + 0x30, 16), Array(16).fill(0xFF));
eqArr('movi 8h #0xff', bytesAt(R + 0x40, 16), Array.from({length: 16}, (_, i) => i % 2 === 0 ? 0xFF : 0));
const A = Array.from({length: 16}, (_, i) => i), B = Array.from({length: 16}, (_, i) => 16 + i);
eqArr('add 16b', bytesAt(R + 0x50, 16), A.map((a, i) => (a + B[i]) & 0xFF));
eqArr('sub 16b', bytesAt(R + 0x60, 16), A.map((_, i) => (B[i] - A[i]) & 0xFF));
eqArr('and 16b', bytesAt(R + 0x70, 16), A.map((a, i) => a & B[i]));
eqArr('orr 16b', bytesAt(R + 0x80, 16), A.map((a, i) => a | B[i]));
eqArr('eor 16b', bytesAt(R + 0x90, 16), A.map((a, i) => a ^ B[i]));
const CONST = 0xDEADBEEF12345678n;
eqArr('fmov d + str d', bytesAt(R + 0xa0, 8), Array.from({length: 8}, (_, i) => Number((CONST >> BigInt(i * 8)) & 0xFFn)));
chk('fmov x9, d13', m.regs[9] === CONST);
eqArr('dup 16b', bytesAt(R + 0xb0, 16), Array(16).fill(0xAB));
eqArr('ins b[3]', bytesAt(R + 0xc0, 16), Array.from({length: 16}, (_, i) => i === 3 ? 0xCD : 0));
chk('umov w11', m.regs[11] === 0xCDn);
eqArr('ldp q1 restore', bytesAt(R + 0xd0, 16), Array(16).fill(0x41));
eqArr('ldp q2 restore', bytesAt(R + 0xe0, 16), Array.from({length: 16}, (_, i) => [0, 1, 0, 0][i % 4]));
chk('sp restored', m.sp === 0x800030000n);
chk('ldnp x2', m.regs[2] === 0x1111111111111111n);
chk('ldnp x3', m.regs[3] === 0x2222222222222222n);
let rb = 0n; { const s = 0x1111111111111111n; for (let i = 0; i < 64; i++) if ((s >> BigInt(i)) & 1n) rb |= 1n << BigInt(63 - i); }
chk('rbit x12', m.regs[12] === rb);
chk('clz x13', m.regs[13] === 51n);
chk('rev x14', m.regs[14] === 0x1111111111111111n); // byte-reverse of 0x1111... is itself
chk('retaa sub returned, x16', m.regs[16] === 0x1234n);
eqArr('stur q', bytesAt(R + 0xf0, 16), Array(16).fill(0x5A));
eqArr('ldur q', bytesAt(R + 0x110, 16), Array(16).fill(0x5A));
eqArr('str s', bytesAt(R + 0x120, 4), [0xDD, 0xCC, 0xBB, 0xAA]);
eqArr('ldr s round trip', bytesAt(R + 0x124, 4), [0xDD, 0xCC, 0xBB, 0xAA]);
eqArr('movi 2d #ff', bytesAt(R + 0x130, 16), Array(16).fill(0xFF));
console.log(`SIMD test: ${pass} passed, ${fail} failed | status ${m.status} icount ${m.icount}`);

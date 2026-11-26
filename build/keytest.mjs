import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { createMachine, DRAM_BASE } = require('./emu.js');
const m = createMachine(() => {}, s => console.log('[log]', s));
// mrs x0, CurrentEL (0xd5384240); mrs x1, MPIDR_EL1 (0xd53800a1); mrs x2, S3_4_C15_C0_4 (0xd53cf082); hlt (0xd4400000)
const prog = [0xd5384240, 0xd53800a1, 0xd53cf082, 0xd4400000];
const bytes = new Uint8Array(prog.length * 4);
prog.forEach((w, i) => { bytes[i*4] = w & 0xFF; bytes[i*4+1] = (w >> 8) & 0xFF; bytes[i*4+2] = (w >> 16) & 0xFF; bytes[i*4+3] = (w >> 24) & 0xFF; });
m.loadBytes(DRAM_BASE, bytes);
m.pc = DRAM_BASE;
m.run(10);
console.log('CurrentEL read -> X0 =', m.regs[0].toString(), '(want 4)');
console.log('MPIDR read     -> X1 =', m.regs[1].toString(), '(want 0)');
console.log('S3_4_C15_C0_4  -> X2 =', m.regs[2].toString(), '(want 2, bit1 set)');

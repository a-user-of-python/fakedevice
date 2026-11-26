"use strict";
/*
 * FakeDevice — a light ARM64 (AArch64) interpreter + fake iPhone hardware,
 * built to run the real iOS kernel (XNU) unconverted in a browser tab.
 *
 * Stage 1: integer ARMv8 subset, paged RAM, Apple-style UART (t8030 map),
 * stub MMIO elsewhere, system-register stubs. Anything unimplemented stops
 * the machine with a fault readout (PC + raw word) — that readout is the
 * work list for the next stage.
 */
const M64 = 0xFFFFFFFFFFFFFFFFn;
const M128 = (1n << 128n) - 1n;
const DRAM_BASE = 0x800000000n;
const DRAM_END = 0x1000000000n;
const UART_BASE = 0x235200000n;            // t8030 (iPhone 11) UART0
const UART_UTRSTAT = 0x10n, UART_UTXH = 0x20n, UART_URXH = 0x24n;

function createMachine(onUart, onLog) {
  const pages = new Map();
  const x = new Array(31).fill(0n);
  const v = new Array(32).fill(0n);          // AdvSIMD/FP registers, 128-bit each
  let sp = 0n, pc = 0n;
  let N = 0, Z = 0, C = 0, V = 0;
  let icount = 0;
  let status = "ready";                    // ready|halted|trap|undefined|wfi
  let trapInfo = "";
  let mmuOn = false;
  const sysregs = new Map();
  const uartRxQueue = [];                  // bytes the backdoor typed "into" the fake phone's serial port
  const tlb = new Map();                   // VA 4K-slice -> PA slice base, valid while the MMU is on
  const mmioLog = new Map();
  const breakpoints = new Set();           // PC values (hex strings) — backdoor
  const pcRing = new Array(64).fill(0n);   // last PCs, for fault readouts
  let pcRingIdx = 0;
  let zvaSize = 64;                        // DC ZVA block size (matches DCZID_EL0 stub)

  // Stage-3 optimization: numeric page keys (string keys cost a BigInt
  // toString + hash per byte accessed) plus a 1-entry last-page cache —
  // consecutive accesses overwhelmingly hit the same 4K page.
  let lpKey = -1, lpPage = undefined;
  function pageFor(addr, create) {
    const key = Number(addr >> 12n);
    if (key === lpKey) {
      if (lpPage !== undefined) return lpPage;
      if (!create) return undefined;
      lpPage = new Uint8Array(4096); pages.set(key, lpPage);
      return lpPage;
    }
    let p = pages.get(key);
    if (p === undefined && create) { p = new Uint8Array(4096); pages.set(key, p); }
    lpKey = key; lpPage = p;
    return p;
  }
  function isRam(addr) { return addr >= DRAM_BASE && addr < DRAM_END; }
  function mmioRead(addr) {
    if (addr >= UART_BASE && addr < UART_BASE + 0x1000n) {
      if (addr - UART_BASE === UART_UTRSTAT) return 0x6n | (uartRxQueue.length ? 1n : 0n);   // TX ready + RX-ready bit when the backdoor queued input
      if (addr - UART_BASE === UART_URXH) return BigInt(uartRxQueue.length ? uartRxQueue.shift() : 0);
      return 0n;
    }
    const k = "0x" + addr.toString(16);
    mmioLog.set(k, (mmioLog.get(k) || 0) + 1);
    return 0n;
  }
  function mmioWrite(addr, val) {
    if (addr >= UART_BASE && addr < UART_BASE + 0x1000n) {
      if (addr - UART_BASE === UART_UTXH) onUart(Number(val & 0xFFn));
      return;
    }
    const k = "0x" + addr.toString(16);
    mmioLog.set(k, (mmioLog.get(k) || 0) + 1);
  }
  function readPhys(addr, size) {
    if (!isRam(addr)) return mmioRead(addr);
    const off = Number(addr & 0xFFFn);
    if (off + size <= 4096) {                       // fast path: within one page
      const p = pageFor(addr, false);
      if (!p) return 0n;
      let v = 0n;
      for (let i = size - 1; i >= 0; i--) v = (v << 8n) | BigInt(p[off + i]);
      return v;
    }
    let v = 0n;
    for (let i = size - 1; i >= 0; i--) {
      const a = addr + BigInt(i), p = pageFor(a, false);
      v = (v << 8n) | BigInt(p ? p[Number(a & 0xFFFn)] : 0);
    }
    return v;
  }
  function writePhys(addr, val, size) {
    if (!isRam(addr)) { mmioWrite(addr, val); return; }
    const off = Number(addr & 0xFFFn);
    if (off + size <= 4096) {                       // fast path: within one page
      const p = pageFor(addr, true);
      for (let i = 0; i < size; i++) p[off + i] = Number((val >> BigInt(8 * i)) & 0xFFn);
      return;
    }
    for (let i = 0; i < size; i++) {
      const a = addr + BigInt(i), p = pageFor(a, true);
      p[Number(a & 0xFFFn)] = Number((val >> BigInt(8 * i)) & 0xFFn);
    }
  }

  // ---- stage 3: real page-table walking, driven by the kernel's own
  // TTBR0_EL1 / TTBR1_EL1 / TCR_EL1 values. No identity tricks: if the
  // kernel's tables don't map an address, the access faults, like hardware.
  // ---- stage 4: exception delivery. When the kernel has programmed
  // VBAR_EL1, a translation fault or an undefined instruction inside step()
  // is delivered to the kernel's own vector (VBAR + 0x400, sync from EL1)
  // with ESR/FAR/ELR/SPSR set the way hardware sets them, instead of
  // stopping the machine. Before VBAR exists (very early boot) a fault
  // stops the machine exactly as it did in stages 1–3.
  let accessWrite = false, accessFetch = false;   // set around translate() calls
  let inStep = false, curInsnPc = 0n;
  let excCount = 0, lastExc = "";
  function vbarArmed() { return (sysregs.get("3,0,12,0,0") || 0n) !== 0n; }
  function walkFault(va, level) {
    const rec = { __fault: true, va, level: level === undefined ? 3 : level, write: accessWrite, fetch: accessFetch, undef: false };
    if (inStep && vbarArmed()) throw rec;
    if (status === "ready") {
      status = "trap";
      trapInfo = "translation fault at VA 0x" + va.toString(16) + " (fetch/data from PC 0x" + pc.toString(16) + ")";
    }
    return null;
  }
  function deliverException(rec) {
    const vbar = sysregs.get("3,0,12,0,0") || 0n;
    if (!vbar) return false;
    let ec, iss;
    if (rec.undef) { ec = 0x00n; iss = 0n; }                       // unknown reason
    else {
      ec = rec.fetch ? 0x21n : 0x25n;                              // instruction / data abort, current EL
      iss = BigInt(0x04 + rec.level) | (rec.write && !rec.fetch ? (1n << 24n) : 0n);   // FSC: translation fault at level; WnR
    }
    sysregs.set("3,0,5,2,0", (ec << 26n) | (1n << 25n) | iss);     // ESR_EL1 (IL=1)
    sysregs.set("3,0,6,0,0", rec.undef ? 0n : rec.va);             // FAR_EL1
    sysregs.set("3,0,4,0,1", rec.elr);                             // ELR_EL1
    const nzcv = (BigInt(N) << 31n) | (BigInt(Z) << 30n) | (BigInt(C) << 29n) | (BigInt(V) << 28n);
    sysregs.set("3,0,4,0,0", nzcv | (0b1111n << 6n) | 0b0101n);    // SPSR_EL1: NZCV saved, DAIF masked, EL1h
    pc = vbar + 0x200n;   // sync exception from EL1 using SP_EL1 (the kernel's own mode)
    excCount++;
    lastExc = (rec.undef ? "undefined instruction" : (rec.fetch ? "instruction abort" : "data abort") +
      " at VA 0x" + rec.va.toString(16)) + ", ELR 0x" + rec.elr.toString(16) + " -> vector 0x" + pc.toString(16);
    return true;
  }
  function walkTables(va) {
    const tcr = sysregs.get("3,0,2,0,2") || 0n;                       // TCR_EL1
    const t0sz = Number(tcr & 0x3Fn), t1sz = Number((tcr >> 16n) & 0x3Fn);
    const tg0 = Number((tcr >> 14n) & 3n), tg1 = Number((tcr >> 30n) & 3n);
    const g0 = tg0 === 1 ? 16 : tg0 === 2 ? 14 : 12;                  // TG0: 00=4K 01=64K 10=16K
    const g1 = tg1 === 2 ? 12 : tg1 === 3 ? 16 : 14;                  // TG1: 01=16K 10=4K 11=64K
    const vaBits1 = 64 - t1sz;
    const isT1 = t1sz > 0 && (va >> BigInt(vaBits1)) === (1n << BigInt(t1sz)) - 1n;
    let g, ttbr;
    if (isT1) {
      if ((tcr >> 23n) & 1n) return walkFault(va, 0);                 // EPD1: TTBR1 walks disabled
      g = g1;
      ttbr = sysregs.get("3,0,2,0,1") || 0n;                          // TTBR1_EL1
    } else {
      if (va >= (1n << BigInt(64 - t0sz))) return walkFault(va, 0);
      if ((tcr >> 7n) & 1n) return walkFault(va, 0);                  // EPD0
      g = g0;
      ttbr = sysregs.get("3,0,2,0,0") || 0n;                          // TTBR0_EL1
    }
    const vaBits = isT1 ? vaBits1 : 64 - t0sz;
    const stride = g - 3;                                             // index bits per level
    const levels = Math.max(1, Math.ceil((vaBits - g) / stride));
    let table = ttbr & ((1n << 48n) - 1n) & ~((1n << BigInt(g)) - 1n);
    for (let L = 4 - levels; L <= 3; L++) {
      const shift = g + stride * (3 - L);
      // At the initial level only (vaBits - shift) index bits are real;
      // the bits above vaBits are the TTBR1 sign-extension ones and the
      // hardware ignores them. Deeper levels always use the full stride.
      const idxBits = Math.min(stride, vaBits - shift);
      if (idxBits <= 0) return walkFault(va, L);
      const idx = (va >> BigInt(shift)) & ((1n << BigInt(idxBits)) - 1n);
      const desc = readPhys(table + idx * 8n, 8);
      const type = desc & 3n;
      if (type === 0n) return walkFault(va, L);                       // invalid descriptor
      if (L === 3) {
        if (type !== 3n) return walkFault(va, 3);
        return (desc & ((1n << 48n) - (1n << BigInt(g)))) | (va & ((1n << BigInt(g)) - 1n));
      }
      if (type === 1n) {                                              // block descriptor
        return (desc & ((1n << 48n) - 1n) & ~((1n << BigInt(shift)) - 1n)) | (va & ((1n << BigInt(shift)) - 1n));
      }
      if (type === 3n) {                                              // table descriptor
        table = desc & ((1n << 48n) - 1n) & ~((1n << BigInt(g)) - 1n);
        continue;
      }
      return walkFault(va, L);                                        // reserved encoding
    }
    return walkFault(va, 3);
  }
  let tlbVa = -1, tlbPa = 0n;                 // 1-entry TLB cache on top of the Map
  function flushTlb() { tlb.clear(); tlbVa = -1; fetchPaBase = -1n; fetchPage = null; }
  function translate(va) {
    const key = Number(va >> 12n);              // numeric key (was a string: slow)
    if (key === tlbVa) return tlbPa + (va & 0xFFFn);
    const hit = tlb.get(key);
    if (hit !== undefined) { tlbVa = key; tlbPa = hit; return hit + (va & 0xFFFn); }
    const pa = walkTables(va);
    if (pa === null) return null;
    const base = pa & ~0xFFFn;
    tlb.set(key, base);
    tlbVa = key; tlbPa = base;
    return pa;
  }
  function readMem(addr, size) {
    if (mmuOn) {
      accessWrite = false;
      const pa = translate(addr);
      if (pa === null) return 0n;
      return readPhys(pa, size);
    }
    return readPhys(addr, size);
  }
  function writeMem(addr, val, size) {
    if (mmuOn) {
      accessWrite = true;
      const pa = translate(addr);
      if (pa === null) return;
      writePhys(pa, val, size);
      return;
    }
    writePhys(addr, val, size);
  }
  function readV(addr, bytes) {              // vector load: little-endian, zero-extended by caller
    if (bytes === 16) return readMem(addr, 8) | (readMem(addr + 8n, 8) << 64n);
    return readMem(addr, bytes);
  }
  function writeV(addr, val, bytes) {        // vector store: low `bytes` of val
    if (bytes === 16) { writeMem(addr, val & M64, 8); writeMem(addr + 8n, (val >> 64n) & M64, 8); return; }
    writeMem(addr, val, bytes);
  }
  function loadBytes(addr, bytes) {
    // bulk path for RAM (kernel images are tens of MB)
    if (isRam(addr) && isRam(addr + BigInt(bytes.length - 1))) {
      let off = 0;
      while (off < bytes.length) {
        const a = addr + BigInt(off);
        const p = pageFor(a, true);
        const po = Number(a & 0xFFFn);
        const n = Math.min(4096 - po, bytes.length - off);
        if (bytes.subarray) p.set(bytes.subarray(off, off + n), po);
        else for (let i = 0; i < n; i++) p[po + i] = bytes[off + i];
        off += n;
      }
      return;
    }
    for (let i = 0; i < bytes.length; i++) writeMem(addr + BigInt(i), BigInt(bytes[i]), 1);
  }

  function getReg(i, isSP) { return i === 31 ? (isSP ? sp : 0n) : x[i]; }
  function setReg(i, val, isSP) {
    val &= M64;
    if (i === 31) { if (isSP) sp = val; return; }
    x[i] = val;
  }
  function sext(val, bits) {
    if ((val >> BigInt(bits - 1)) & 1n) return (val | (M64 ^ ((1n << BigInt(bits)) - 1n))) & M64;
    return val & M64;
  }
  function shiftReg(val, type, amt, bits) {
    const mask = bits === 64 ? M64 : 0xFFFFFFFFn;
    val &= mask;
    amt &= (bits - 1);
    if (type === 0) return (val << BigInt(amt)) & mask;                    // LSL
    if (type === 1) return val >> BigInt(amt);                             // LSR
    if (type === 2) return (sext(val, bits) >> BigInt(amt)) & mask;        // ASR
    if (amt === 0) return val;                                             // ROR
    return ((val >> BigInt(amt)) | (val << BigInt(bits - amt))) & mask;
  }
  function flagsAdd(a, b, r, bits) {
    const mask = bits === 64 ? M64 : 0xFFFFFFFFn, sign = bits === 64 ? 0x8000000000000000n : 0x80000000n;
    N = (r & sign) ? 1 : 0; Z = ((r & mask) === 0n) ? 1 : 0;
    C = (r > mask || (a & mask) + (b & mask) > mask) ? 1 : 0;
    V = ((~(a ^ b) & (a ^ r)) & sign) ? 1 : 0;
    // carry recomputed exactly:
    C = (((a & mask) + (b & mask)) >> BigInt(bits)) & 1n ? 1 : 0;
  }
  function flagsSub(a, b, r, bits) {
    const mask = bits === 64 ? M64 : 0xFFFFFFFFn, sign = bits === 64 ? 0x8000000000000000n : 0x80000000n;
    N = (r & sign) ? 1 : 0; Z = ((r & mask) === 0n) ? 1 : 0;
    C = ((a & mask) >= (b & mask)) ? 1 : 0;
    V = (((a ^ b) & (a ^ r)) & sign) ? 1 : 0;
  }
  function flagsLogic(r, bits) {
    const sign = bits === 64 ? 0x8000000000000000n : 0x80000000n;
    N = (r & sign) ? 1 : 0; Z = (r === 0n) ? 1 : 0; C = 0; V = 0;
  }
  function condHolds(cond) {
    let r;
    switch (cond >> 1) {
      case 0: r = Z === 1; break;
      case 1: r = C === 1; break;
      case 2: r = N === 1; break;
      case 3: r = V === 1; break;
      case 4: r = C === 1 && Z === 0; break;
      case 5: r = N === V; break;
      case 6: r = N === V && Z === 0; break;
      default: r = true;
    }
    return (cond & 1) && cond !== 15 ? !r : r;
  }
  function decodeBitmask(Nbit, immr, imms, bits) {
    let len = 0;
    if (Nbit) len = 6;
    else {
      for (let i = 5; i >= 1; i--) if (((imms >> i) & 1) === 0) { len = i; break; }
      if (!len) return null;
    }
    const esize = 1 << len;
    if (esize > bits) return null;
    const levels = esize - 1, s = imms & levels, r = immr & levels;
    if (s === levels) return null;
    let welem = (1n << BigInt(s + 1)) - 1n;
    if (r) welem = ((welem >> BigInt(r)) | (welem << BigInt(esize - r))) & ((1n << BigInt(esize)) - 1n);
    let out = 0n;
    for (let i = 0; i < bits; i += esize) out |= welem << BigInt(i);
    return out & (bits === 64 ? M64 : 0xFFFFFFFFn);
  }

  function sysKey(op0, op1, crn, crm, op2) { return op0 + "," + op1 + "," + crn + "," + crm + "," + op2; }
  function mrs(op0, op1, crn, crm, op2) {
    switch (sysKey(op0, op1, crn, crm, op2)) {
      case "3,0,0,0,0": return 0x611F01A0n;              // MIDR_EL1 (stub value)
      case "3,0,0,0,5": return 0n;                       // MPIDR_EL1: boot core 0
      case "3,0,4,2,2": return 4n;                       // CurrentEL = EL1
      case "3,3,0,0,1": return 0x8444C004n;              // CTR_EL0 (plausible)
      case "3,0,0,4,0": return 0x111111n;                // ID_AA64PFR0_EL1 (plausible)
      case "3,3,13,0,2": return BigInt(icount) * 41n;    // CNTPCT_EL0: fake timer
      case "3,3,0,0,7": return 4n;                       // DCZID_EL0: 64-byte ZVA blocks, allowed
      case "3,3,14,0,0": return 24000000n;               // CNTFRQ_EL0: 24 MHz
      case "3,4,15,0,4":                                 // Apple core register S3_4_C15_C0_4:
        // XNU's start path polls bit 1 ("core ready") before programming the
        // TTBRs and turning the MMU on, then read-modify-writes config bits.
        // Model a powered, ready core: bit 1 always reads 1, writes stick.
        return (sysregs.get("3,4,15,0,4") || 0n) | 2n;
      default: return sysregs.get(sysKey(op0, op1, crn, crm, op2)) || 0n;
    }
  }
  function msr(op0, op1, crn, crm, op2, val) {
    const k = sysKey(op0, op1, crn, crm, op2);
    sysregs.set(k, val & M64);
    if (k === "3,0,2,0,0" || k === "3,0,2,0,1" || k === "3,0,2,0,2") flushTlb();   // TTBR0/TTBR1/TCR changed
    if (k === "3,0,1,0,0") {                                                        // SCTLR_EL1
      const on = (val & 1n) !== 0n;
      if (on && !mmuOn) onLog("kernel set SCTLR_EL1.M — MMU on; addresses now translate through the kernel's own page tables");
      if (on !== mmuOn) { mmuOn = on; flushTlb(); }
    }
  }

  function undef(insn) {
    if (inStep && vbarArmed()) throw { __fault: true, undef: true, insn, va: 0n, level: 3, write: false, fetch: false };
    status = "undefined";
    trapInfo = "undefined instruction 0x" + insn.toString(16).padStart(8, "0") + " at PC 0x" + pc.toString(16);
    return false;
  }
  function trap(kind, info) {
    status = "trap";
    trapInfo = kind + " at PC 0x" + pc.toString(16) + (info ? " (" + info + ")" : "");
    return false;
  }

  let fetchPage = null, fetchPaBase = -1n;  // cached fetch page: PA base + Uint8Array
  function fetchInsn() {
    // Fast path: instruction fetch is sequential, so the same 4K page serves
    // ~1024 fetches. Read the 4 bytes straight out of the page array instead
    // of going through readMem -> translate -> readPhys per instruction.
    // Falls back to the slow readMem path on page crossing, non-RAM, or fault.
    let pa;
    if (mmuOn) {
      accessFetch = true;
      try { pa = translate(pc); } finally { accessFetch = false; }
      if (pa === null) return null;              // walkFault already set status
    } else pa = pc;
    if (!isRam(pa) || (pa & 0xFFFn) > 4092n) return Number(readMem(pc, 4));
    const base = pa & ~0xFFFn;
    if (base !== fetchPaBase) { fetchPage = pageFor(pa, false); fetchPaBase = base; }
    if (!fetchPage) return 0;                    // untouched RAM page reads as zero
    const o = Number(pa & 0xFFFn);
    return (fetchPage[o] | (fetchPage[o + 1] << 8) | (fetchPage[o + 2] << 16) | (fetchPage[o + 3] << 24)) >>> 0;
  }
  function step() {
    curInsnPc = pc;
    inStep = true;
    try {
      return stepBody();
    } catch (e) {
      if (e && e.__fault) {
        e.elr = curInsnPc;
        if (deliverException(e)) { status = "ready"; return true; }
        status = "trap";
        trapInfo = e.undef
          ? "undefined instruction, and VBAR_EL1 is not set yet — nowhere to deliver it"
          : "translation fault at VA 0x" + e.va.toString(16) + ", and VBAR_EL1 is not set yet — nowhere to deliver it";
        return false;
      }
      throw e;
    } finally { inStep = false; }
  }
  function stepBody() {
    pcRing[pcRingIdx] = pc; pcRingIdx = (pcRingIdx + 1) & 63;
    const insn = fetchInsn();
    if (insn === null) return false;             // fetch faulted (translation) — stop here
    if (status === "trap") return false;
    icount++;
    const nextPc = pc + 4n;
    const rd = insn & 31, rn = (insn >> 5) & 31, rm = (insn >> 16) & 31;
    const sf = (insn >>> 31) & 1, bits = sf ? 64 : 32;
    const wmask = sf ? M64 : 0xFFFFFFFFn;

    // --- exceptions, hints, barriers, sysregs ---
    if (((insn & 0xFFE0001F) >>> 0) === 0xD4400000) { status = "halted"; trapInfo = "HLT at PC 0x" + pc.toString(16); return false; }
    if (((insn & 0xFFE0001F) >>> 0) === 0xD4200000) { status = "halted"; trapInfo = "BRK #" + ((insn >> 5) & 0xFFFF) + " at PC 0x" + pc.toString(16); return false; }
    if (((insn & 0xFFE0001F) >>> 0) === 0xD4000001) return trap("SVC", "#" + ((insn >> 5) & 0xFFFF));
    if (insn === 0xD69F03E0 || insn === 0xD69F0BFF || insn === 0xD69F0FFF) {   // ERET / ERETAA / ERETAB
      const spsr = sysregs.get("3,0,4,0,0") || 0n;                            // SPSR_EL1
      N = Number((spsr >> 31n) & 1n); Z = Number((spsr >> 30n) & 1n);
      C = Number((spsr >> 29n) & 1n); V = Number((spsr >> 28n) & 1n);
      pc = sysregs.get("3,0,4,0,1") || 0n;                                    // ELR_EL1
      return true;
    }
    if (((insn & 0xFFFFF000) >>> 0) === 0xD5032000) {   // HINT space (mask must clear Rt too: real encodings carry 11111 there)
      if (((insn >> 5) & 0x7F) === 3) { status = "wfi"; trapInfo = "WFI at PC 0x" + pc.toString(16) + " — CPU idle, waiting for an interrupt"; return false; }
      pc = nextPc; return true;
    }
    if (((insn & 0xFFF0F000) >>> 0) === 0xD5033000) { pc = nextPc; return true; }        // barriers
    if (((insn & 0xFFC00000) >>> 0) === 0xD5000000) {                                    // MSR/MRS + SYS (TLBI/DC/IC/AT)
      const L = (insn >> 21) & 1;
      const op0 = (insn >> 19) & 3, op1 = (insn >> 16) & 7;
      const crn = (insn >> 12) & 15, crm = (insn >> 8) & 15, op2 = (insn >> 5) & 7;
      if (!L && crn === 7) {
        // SYS cache maintenance: Rt (rd field) holds the address for DC ops
        if (crm === 4 && op2 === 1) {                    // DC ZVA: zero a block — the kernel BSS eraser
          const a = getReg(rd, false) & ~BigInt(zvaSize - 1);
          for (let i = 0; i < zvaSize; i += 8) writeMem(a + BigInt(i), 0n, 8);
        }
        // DC CIVAC/CVAC/CVAU/IVAC, IC IALLU*: no-ops in this model (no data/instruction caches)
        pc = nextPc; return true;
      }
      if (!L && crn === 8) {                             // TLBI *: flush the translation cache
        flushTlb();
        pc = nextPc; return true;
      }
      if (L) setReg(rd, mrs(op0, op1, crn, crm, op2), false);
      else msr(op0, op1, crn, crm, op2, getReg(rd, false));
      pc = nextPc; return true;
    }

    // --- AdvSIMD / FP (stage 3) ---
    // Vector state is v[0..31], one 128-bit BigInt each. Only the encodings the
    // kernel actually executes are modelled; the rest still stop as undefined.
    // This block sits before the integer load/store sections: the SIMD&FP
    // encoding space (0x3C/0x3D/0xAD families) overlaps their masks.
    if ((insn & 0x3F000000) === 0x1C000000) {
      // LDR (literal, SIMD&FP): bits[29:24] = 011100 (V=1). The integer LDR
      // literal mask used to claim these too and loaded the constant pool
      // into a GPR (0x9CFFF7C1 in strlen -> X1 = 0x03020100 corruption).
      const opc = (insn >>> 30) & 3;
      if (opc === 3) return undef(insn);
      const bytes = opc === 0 ? 4 : opc === 1 ? 8 : 16;
      let imm = BigInt((insn >> 5) & 0x7FFFF);
      if (imm & 0x40000n) imm |= ~0x7FFFFn;
      v[rd] = readV((pc + (imm << 2n)) & M64, bytes) & M128;
      pc = nextPc; return true;
    }
    if ((insn & 0x3F000000) === 0x3C000000 || (insn & 0x3F000000) === 0x3D000000) {
      // LDR / STR (SIMD&FP), single register
      const size = (insn >>> 30) & 3, opc = (insn >>> 22) & 3;
      const bytes = (size === 0 && opc >= 2) ? 16 : (1 << size);
      const isLoad = (opc & 1) === 1;
      const base = getReg(rn, true);
      let addr;
      if ((insn & 0x00200000) !== 0) {                                    // register offset
        const rm = (insn >> 16) & 31, opt = (insn >> 13) & 7, sh = (insn >> 12) & 1;
        let off = getReg(rm, false);
        if (opt === 2) off &= 0xFFFFFFFFn;                                // UXTW
        else if (opt === 6) { off &= 0xFFFFFFFFn; if (off & 0x80000000n) off |= ~0xFFFFFFFFn; } // SXTW
        if (sh) off <<= BigInt(bytes === 16 ? 4 : size);
        addr = base + off;
      } else if ((insn & 0x3F000000) === 0x3D000000) {                   // unsigned offset
        addr = base + BigInt(((insn >> 10) & 0xFFF) * bytes);
      } else {                                                            // unscaled / post / pre
        let imm = BigInt((insn >> 12) & 0x1FF);
        if (imm & 0x100n) imm |= ~0x1FFn;
        const mode = (insn >> 10) & 3;
        if (mode === 0) addr = base + imm;
        else if (mode === 1) { addr = base; setReg(rn, base + imm, true); }
        else if (mode === 3) { addr = base + imm; setReg(rn, addr, true); }
        else return undef(insn);
      }
      if (isLoad) v[rd] = readV(addr, bytes) & M128;
      else writeV(addr, v[rd], bytes);
      pc = nextPc; return true;
    }
    if ((insn & 0x7A000000) === 0x28000000 && ((insn >> 26) & 1) === 1) {
      // LDP / STP (SIMD&FP) + LDNP / STNP
      const opc = (insn >>> 30) & 3;
      if (opc === 3) return undef(insn);
      const size = opc === 0 ? 4 : opc === 1 ? 8 : 16;
      const L = (insn >> 22) & 1, mode = (insn >>> 23) & 7;
      const rt2 = (insn >> 10) & 31;
      let imm = BigInt((insn >> 15) & 0x7F);
      if (imm & 0x40n) imm |= ~0x7Fn;
      imm *= BigInt(size);
      const base = getReg(rn, true);
      let addr;
      if (mode === 2 || mode === 0) addr = base + imm;                     // offset / non-temporal
      else if (mode === 3 || mode === 1 || mode === 6 || mode === 7) addr = base + imm;
      else return undef(insn);
      const isPre = mode === 3 || mode === 7, isPost = mode === 1 || mode === 5;
      const a0 = isPost ? base : addr;
      if (L) { v[rd] = readV(a0, size) & M128; v[rt2] = readV(a0 + BigInt(size), size) & M128; }
      else { writeV(a0, v[rd], size); writeV(a0 + BigInt(size), v[rt2], size); }
      if (isPre || isPost) setReg(rn, addr, true);
      pc = nextPc; return true;
    }
    if ((insn & 0x9F000000) === 0x0F000000 && ((insn >> 19) & 0x1F) === 0 && ((insn >> 10) & 1) === 1) {
      // MOVI / MVNI (modified immediate). bits[23:19] are always zero in this
      // group — that is what separates it from the shift-by-immediate group
      // (SHL/SLI/SSHR...), whose immh field makes them nonzero. cmode 1110 is
      // the byte-replicated
      // form and is always MOVI (its bit 29 is not the invert flag).
      const Q = (insn >>> 30) & 1, cmode = (insn >> 12) & 0xF;
      const imm8 = (((insn >> 16) & 7) << 5) | ((insn >> 5) & 31);
      let val;
      if (cmode === 0xE || cmode === 0xC) {                               // every byte = imm8
        val = 0n; for (let i = 0; i < 16; i++) val |= BigInt(imm8) << BigInt(i * 8);
      } else if (cmode === 0xF) {                                         // bit-expanded
        val = 0n; for (let j = 0; j < 8; j++) if ((imm8 >> j) & 1) val |= 0xFFn << BigInt(j * 8);
        if (Q) val |= val << 64n;
      } else if ((cmode & 0x8) === 0) {                                   // 32-bit lanes
        const e = BigInt(imm8) << BigInt(((cmode >> 1) & 3) * 8);
        val = e | (e << 32n); if (Q) val |= val << 64n;
      } else if ((cmode & 0xE) === 0x8) {                                 // 16-bit lanes
        const e = BigInt(imm8) << BigInt((cmode & 1) * 8);
        val = 0n; for (let i = 0; i < 4; i++) val |= e << BigInt(i * 16);
        if (Q) val |= val << 64n;
      } else return undef(insn);
      if (cmode !== 0xE && ((insn >> 29) & 1) === 1) val = ~val;          // MVNI
      v[rd] = val & (Q ? M128 : M64);
      pc = nextPc; return true;
    }
    if ((insn & 0x9F000000) === 0x0E000000 && (insn & 0xF800) === 0x1800 && ((insn >> 21) & 1) === 1) {
      // three-same LOGICAL: AND/BIC/ORR/ORN (U=0), EOR/BIT/BSL/BIF (U=1).
      // bit 21 is the three-same template's fixed 1 — the copy group
      // (DUP/INS/UMOV) shares the rest of this pattern but has bit 21 = 0.
      const U = (insn >>> 29) & 1, sel = (insn >>> 22) & 3, Q = (insn >>> 30) & 1;
      const a = v[rn], b = v[rm];
      let r;
      if (!U) r = sel === 0 ? a & b : sel === 1 ? a & ~b : sel === 2 ? a | b : a | ~b;
      else r = sel === 0 ? a ^ b : sel === 1 ? (a & b) | (v[rd] & ~b) : sel === 2 ? (v[rd] & a) | (~v[rd] & b) : (a & ~b) | (v[rd] & b);
      v[rd] = r & (Q ? M128 : M64);
      pc = nextPc; return true;
    }
    if ((insn & 0x9F000000) === 0x0E000000 && (insn & 0xF800) === 0x8000 && ((insn >> 21) & 1) === 1) {
      // ADD / SUB (vector, integer lanes); bit 21 as above
      const U = (insn >>> 29) & 1, size = (insn >>> 22) & 3, Q = (insn >>> 30) & 1;
      const esize = 8 << size, lanes = (Q ? 128 : 64) / esize, em = (1n << BigInt(esize)) - 1n;
      let r = 0n;
      for (let i = 0; i < lanes; i++) {
        const a = (v[rn] >> BigInt(i * esize)) & em, b = (v[rm] >> BigInt(i * esize)) & em;
        r |= ((U ? a - b : a + b) & em) << BigInt(i * esize);
      }
      v[rd] = r & M128;
      pc = nextPc; return true;
    }
    if ((insn & 0x9F000000) === 0x0E000000 && ((insn >> 21) & 1) === 1 && [13, 15, 25, 27, 29, 35, 37, 39].includes((insn >> 10) & 0x3F)) {
      // three-same compares / min / max / abs-diff / multiply (lane-wise)
      const U = (insn >>> 29) & 1, size = (insn >>> 22) & 3, Q = (insn >>> 30) & 1;
      const opc = (insn >> 10) & 0x3F;
      const esize = 8 << size, lanes = (Q ? 128 : 64) / esize, em = (1n << BigInt(esize)) - 1n;
      const signBit = 1n << BigInt(esize - 1);
      const asS = (val) => (val & signBit) !== 0n ? val - (1n << BigInt(esize)) : val;
      let r = 0n;
      for (let i = 0; i < lanes; i++) {
        const a = (v[rn] >> BigInt(i * esize)) & em, b = (v[rm] >> BigInt(i * esize)) & em;
        let out;
        if (opc === 13) out = (U ? a > b : asS(a) > asS(b)) ? em : 0n;                       // CMHI / CMGT
        else if (opc === 15) out = (U ? a >= b : asS(a) >= asS(b)) ? em : 0n;                // CMHS / CMGE
        else if (opc === 35) out = (U ? a === b : (a & b) !== 0n) ? em : 0n;                 // CMEQ / CMTST
        else if (opc === 25) out = (U ? (a > b ? a : b) : (asS(a) > asS(b) ? a : b));         // UMAX / SMAX
        else if (opc === 27) out = (U ? (a < b ? a : b) : (asS(a) < asS(b) ? a : b));         // UMIN / SMIN
        else if (opc === 29) { const d = U ? (a > b ? a - b : b - a) : (asS(a) - asS(b)); out = (d < 0n ? -d : d) & em; } // UABD / SABD
        else if (opc === 37) { const cur = (v[rd] >> BigInt(i * esize)) & em; out = (U ? cur - a * b : cur + a * b) & em; } // MLS / MLA
        else out = (a * b) & em;                                                             // MUL (39)
        r |= out << BigInt(i * esize);
      }
      v[rd] = r & (Q ? M128 : M64);
      pc = nextPc; return true;
    }
    if ((insn & 0x9F000000) === 0x0E000000 && ((insn >> 17) & 0x1F) === 0x18 && ((insn >> 10) & 3) === 2) {
      // vector reductions: ADDV / SMINV / UMINV / SMAXV / UMAXV
      const U = (insn >>> 29) & 1, size = (insn >>> 22) & 3, Q = (insn >>> 30) & 1;
      const opc = (insn >> 12) & 0x1F;
      const esize = 8 << size, lanes = (Q ? 128 : 64) / esize, em = (1n << BigInt(esize)) - 1n;
      const signBit = 1n << BigInt(esize - 1);
      const asSigned = (val) => (val & signBit) !== 0n ? val - (1n << BigInt(esize)) : val;
      let r;
      if (opc === 0x1B) {                                                 // ADDV
        r = 0n;
        for (let i = 0; i < lanes; i++) r += (v[rn] >> BigInt(i * esize)) & em;
        r &= em;
      } else if (opc === 0x1A || opc === 0x0A) {                          // MINV (11010) / MAXV (01010)
        const isMin = opc === 0x1A;
        let best = null;
        for (let i = 0; i < lanes; i++) {
          const lane = (v[rn] >> BigInt(i * esize)) & em;
          const key = U ? lane : asSigned(lane);
          if (best === null || (isMin ? key < best.key : key > best.key)) best = { key, lane };
        }
        r = best.lane;
      } else return undef(insn);
      v[rd] = r & M128;
      pc = nextPc; return true;
    }
    if (((insn & 0xFFFFFC00) >>> 0) === 0x9E670000) { v[rd] = getReg(rn, false); pc = nextPc; return true; }              // FMOV Dd, Xn
    if (((insn & 0xFFFFFC00) >>> 0) === 0x9E660000) { setReg(rd, v[rn] & M64, false); pc = nextPc; return true; }         // FMOV Xd, Dn
    if ((insn & 0xFFFFFC00) === 0x1E270000) { v[rd] = getReg(rn, false) & 0xFFFFFFFFn; pc = nextPc; return true; } // FMOV Sd, Wn
    if ((insn & 0xFFFFFC00) === 0x1E260000) { setReg(rd, v[rn] & 0xFFFFFFFFn, false); pc = nextPc; return true; } // FMOV Wd, Sn
    if ((insn & 0xFFFFFC00) === 0x1E204000) { v[rd] = v[rn] & 0xFFFFFFFFn; pc = nextPc; return true; }             // FMOV Sd, Sn
    if ((insn & 0xFFFFFC00) === 0x1E604000) { v[rd] = v[rn] & M64; pc = nextPc; return true; }                     // FMOV Dd, Dn
    {
      const fam = insn & 0x9F00FC00;
      if (fam === 0x0E000C00 || fam === 0x0E001C00 || fam === 0x0E003C00) {
        // DUP / INS / UMOV+SMOV (copy between GPR and vector lanes)
        const imm5 = (insn >> 16) & 31;
        let tz = 0; while (((imm5 >> tz) & 1) === 0) tz++;
        const esize = 8 << tz, idx = imm5 >> (tz + 1), em = (1n << BigInt(esize)) - 1n;
        const Q = (insn >>> 30) & 1;
        if (fam === 0x0E000C00) {                                         // DUP (general)
          const val = getReg(rn, false) & em;
          let r = 0n; const lanes = (Q ? 128 : 64) / esize;
          for (let i = 0; i < lanes; i++) r |= val << BigInt(i * esize);
          v[rd] = r & M128;
        } else if (fam === 0x0E001C00) {                                  // INS (general)
          const val = getReg(rn, false) & em;
          v[rd] = (v[rd] & ~(em << BigInt(idx * esize))) | (val << BigInt(idx * esize));
        } else {                                                          // UMOV / SMOV
          let val = (v[rn] >> BigInt(idx * esize)) & em;
          if (((insn >> 29) & 1) === 1 && (val & (1n << BigInt(esize - 1))) !== 0n) val |= ~em;  // SMOV sign-extend
          setReg(rd, val, false);
        }
        pc = nextPc; return true;
      }
    }

    // --- ADR / ADRP ---
    if ((insn & 0x1F000000) === 0x10000000) {
      let imm = BigInt(((insn >> 3) & 0x1FFFFC) | ((insn >> 29) & 3));
      if (imm & 0x100000n) imm |= ~0x1FFFFFn;
      if (sf) setReg(rd, ((pc & ~0xFFFn) + (imm << 12n)) & M64, false);
      else setReg(rd, (pc + imm) & M64, false);
      pc = nextPc; return true;
    }

    // --- data-processing immediate ---
    const dpi = ((insn >>> 25) & 0xF);
    if (dpi === 8 || dpi === 9) {
      const op6 = (insn >>> 23) & 0x3F;
      if (op6 === 0x22 || op6 === 0x23) {                                        // ADD/SUB imm
        const isSub = (insn >>> 30) & 1, setF = (insn >>> 29) & 1;
        let imm = BigInt((insn >> 10) & 0xFFF);
        if ((insn >> 22) & 1) imm <<= 12n;
        const a = getReg(rn, true) & wmask;
        const r = isSub ? (a - imm) & M64 : (a + imm) & M64;
        if (setF) { if (isSub) flagsSub(a, imm, r, bits); else flagsAdd(a, imm, r, bits); }
        if (!(setF && rd === 31)) setReg(rd, r & wmask, !setF);
        pc = nextPc; return true;
      }
      if (op6 === 0x24) {                                                        // logical imm
        const opc = (insn >>> 29) & 3;
        const imm = decodeBitmask((insn >> 22) & 1, (insn >> 16) & 0x3F, (insn >> 10) & 0x3F, bits);
        if (imm === null) return undef(insn);
        const a = getReg(rn, false) & wmask;
        let r = opc === 1 ? (a | imm) : opc === 2 ? (a ^ imm) : (a & imm);
        r &= wmask;
        if (opc === 3) flagsLogic(r, bits);
        if (!(opc === 3 && rd === 31)) setReg(rd, r, false);
        pc = nextPc; return true;
      }
      if (op6 === 0x25) {                                                        // move wide
        const opc = (insn >>> 29) & 3, hw = ((insn >> 21) & 3) * 16;
        const imm16 = BigInt((insn >> 5) & 0xFFFF);
        let r;
        if (opc === 2) r = imm16 << BigInt(hw);
        else if (opc === 0) r = (~(imm16 << BigInt(hw))) & M64;
        else if (opc === 3) r = (getReg(rd, false) & ~(0xFFFFn << BigInt(hw))) | (imm16 << BigInt(hw));
        else return undef(insn);
        setReg(rd, r & wmask, false);
        pc = nextPc; return true;
      }
      if (op6 === 0x26) {                                                        // bitfield
        const opc = (insn >>> 29) & 3;
        if (((insn >> 22) & 1) !== sf) return undef(insn);
        const immr = (insn >> 16) & 0x3F, imms = (insn >> 10) & 0x3F;
        const src = getReg(rn, false) & wmask;
        let r;
        if (imms >= immr) {
          const width = imms - immr + 1, m = (1n << BigInt(width)) - 1n;
          const field = (src >> BigInt(immr)) & m;
          if (opc === 1) r = ((getReg(rd, false) & wmask) & ~m) | field;         // BFM
          else if (opc === 0) r = sext(field, width) & wmask;                    // SBFM
          else r = field;                                                        // UBFM
        } else {
          const m = ((1n << BigInt(imms + 1)) - 1n) << BigInt(bits - immr);
          const field = (src << BigInt(bits - immr)) & m;
          if (opc === 1) r = ((getReg(rd, false) & wmask) & ~m) | field;
          else if (opc === 0) r = shiftReg(src, 2, immr, bits);                  // ASR form
          else r = field;                                                        // LSL form
        }
        setReg(rd, r & wmask, false);
        pc = nextPc; return true;
      }
      if (op6 === 0x27) {                                                        // EXTR
        const concat = (getReg(rn, false) & wmask) << BigInt(bits) | (getReg(rm, false) & wmask);
        setReg(rd, (concat >> BigInt((insn >> 10) & 0x3F)) & wmask, false);
        pc = nextPc; return true;
      }
    }

    // --- branches ---
    if ((insn & 0x7C000000) === 0x14000000) {                                    // B / BL
      let imm = BigInt(insn & 0x3FFFFFF);
      if (imm & 0x2000000n) imm |= ~0x3FFFFFFn;
      if ((insn >>> 31) & 1) setReg(30, nextPc, false);
      pc = (pc + (imm << 2n)) & M64; return true;
    }
    if ((insn & 0xFF000010) === 0x54000000) {                                    // B.cond
      let imm = BigInt((insn >> 5) & 0x7FFFF);
      if (imm & 0x40000n) imm |= ~0x7FFFFn;
      pc = condHolds(insn & 0xF) ? (pc + (imm << 2n)) & M64 : nextPc; return true;
    }
    if ((insn & 0x7E000000) === 0x34000000) {                                    // CBZ / CBNZ
      let imm = BigInt((insn >> 5) & 0x7FFFF);
      if (imm & 0x40000n) imm |= ~0x7FFFFn;
      const isz = (getReg(rd, false) & wmask) === 0n;
      pc = (((insn >>> 24) & 1) ? !isz : isz) ? (pc + (imm << 2n)) & M64 : nextPc; return true;
    }
    if ((insn & 0x7E000000) === 0x36000000) {                                    // TBZ / TBNZ
      const bpos = (((insn >>> 31) & 1) << 5) | ((insn >> 19) & 0x1F);
      let imm = BigInt((insn >> 5) & 0x3FFF);
      if (imm & 0x2000n) imm |= ~0x3FFFn;
      const bit = (getReg(rd, false) >> BigInt(bpos)) & 1n;
      pc = (((insn >>> 24) & 1) ? bit === 1n : bit === 0n) ? (pc + (imm << 2n)) & M64 : nextPc; return true;
    }
    if (((insn & 0xFFFFFC1F) >>> 0) === 0xD61F0000) { pc = getReg(rn, false); return true; }              // BR
    if (((insn & 0xFFFFFC1F) >>> 0) === 0xD63F0000) { setReg(30, nextPc, false); pc = getReg(rn, false); return true; } // BLR
    if ((insn >>> 0) === 0xD65F0BFF || (insn >>> 0) === 0xD65F0FFF) { pc = getReg(30, false); return true; } // RETAA / RETAB (auth not modelled)
    {
      // Pointer-authenticated branches (FEAT_PAuth): BRAA/BRAB, BLRAA/BLRAB
      // (target in Rn, modifier in Rd), BRAAZ/BRABZ, BLRAAZ/BLRABZ (Rd = 11111).
      // Authentication is not modelled, consistent with RETAA/RETAB: branch to
      // the raw pointer. Frontier case: BLRAA x27, x26 = 0xD73F0B7A.
      const top = (insn & 0xFFFF0000) >>> 0;
      if ((top === 0xD71F0000 || top === 0xD73F0000) && ((insn >> 11) & 1) === 1) {
        if (top === 0xD73F0000) setReg(30, nextPc, false);
        pc = getReg(rn, false); return true;
      }
      if ((top === 0xD61F0000 || top === 0xD63F0000) && ((insn >> 10) & 3) === 2 && (insn & 31) === 31) {
        if (top === 0xD63F0000) setReg(30, nextPc, false);
        pc = getReg(rn, false); return true;
      }
    }
    if (((insn & 0xFFFFFC1F) >>> 0) === 0xD65F0000) { pc = getReg(rn, false); return true; }              // RET

    // --- loads & stores: pairs ---
    if ((insn & 0x7A000000) === 0x28000000) {
      const opc = (insn >>> 30) & 3;
      if (opc === 1 || opc === 3) return undef(insn);                            // SIMD pairs: later
      const size = opc === 2 ? 8 : 4;
      const L = (insn >> 22) & 1, mode = (insn >>> 23) & 7;
      const rt2 = (insn >> 10) & 31;
      let imm = BigInt(insn >> 15 & 0x7F);
      if (imm & 0x40n) imm |= ~0x7Fn;
      imm *= BigInt(size);
      const base = getReg(rn, true);
      let addr = base;
      if (mode === 2 || mode === 0) addr = base + imm;                           // signed offset (010) / LDNP+STNP (000, non-temporal hint ignored)
      else if (mode === 3 || mode === 1) addr = base + imm;                      // pre (011) / post handled below
      else if (mode === 6 || mode === 7) addr = base + imm;
      else return undef(insn);
      const isPre = mode === 3 || mode === 7, isPost = mode === 1 || mode === 5;
      const a0 = isPost ? base : addr;
      if (L) {
        setReg(rd, readMem(a0, size), false);
        setReg(rt2, readMem(a0 + BigInt(size), size), false);
      } else {
        writeMem(a0, getReg(rd, false), size);
        writeMem(a0 + BigInt(size), getReg(rt2, false), size);
      }
      if (isPre || isPost) setReg(rn, addr, true);
      pc = nextPc; return true;
    }

    // --- loads & stores: single ---
    if ((insn & 0x3F000000) === 0x18000000) {                                    // LDR literal (V=0 only; SIMD form lives in the AdvSIMD block)
      const opc = (insn >>> 30) & 3;
      if (opc === 3) { pc = nextPc; return true; }                              // PRFM literal: prefetch hint, no-op
      let imm = BigInt((insn >> 5) & 0x7FFFF);
      if (imm & 0x40000n) imm |= ~0x7FFFFn;
      const addr = (pc + (imm << 2n)) & M64;
      if (opc === 0) setReg(rd, readMem(addr, 4), false);
      else if (opc === 1) setReg(rd, readMem(addr, 8), false);
      else setReg(rd, sext(readMem(addr, 4), 32), false);                        // LDRSW
      pc = nextPc; return true;
    }
    if ((insn & 0x3B000000) === 0x39000000 || (insn & 0x3B000000) === 0x38000000) {
      const size = (insn >>> 30) & 3, opc = (insn >>> 22) & 3;
      const bytes = 1 << size;
      if (size === 3 && opc === 3 && ((insn & 0x3B000000) === 0x39000000)) { pc = nextPc; return true; } // PRFM
      const base = getReg(rn, true);
      let addr, writeback = null;
      if ((insn & 0x3B000000) === 0x39000000) {                                   // unsigned offset
        addr = base + BigInt(((insn >> 10) & 0xFFF) * bytes);
      } else if (((insn >> 21) & 1) && ((insn >> 10) & 3) === 2) {               // register offset
        const opt = (insn >> 13) & 7, sh = ((insn >> 12) & 1) ? size : 0;
        let ext = getReg(rm, false);
        if (opt === 2) ext &= 0xFFFFFFFFn;
        else if (opt === 6) ext = sext(ext & 0xFFFFFFFFn, 32);
        else if (opt !== 3 && opt !== 7) return undef(insn);
        addr = (base + ((ext << BigInt(sh)) & M64)) & M64;
      } else {
        let imm = BigInt((insn >> 12) & 0x1FF);
        if (imm & 0x100n) imm |= ~0x1FFn;
        const mode = (insn >> 10) & 3;
        if (mode === 0) addr = base + imm;                                       // unscaled
        else if (mode === 3) { addr = base + imm; writeback = addr; }            // pre-index
        else if (mode === 1) { addr = base; writeback = base + imm; }            // post-index
        else return undef(insn);
      }
      if (opc === 0) {
        writeMem(addr, getReg(rd, false), bytes);
      } else {
        const raw = readMem(addr, bytes);
        let val;
        if (opc === 1) val = raw;
        else if (opc === 2) val = sext(raw, bytes * 8) & (sf ? M64 : 0xFFFFFFFFn);
        else val = sext(raw, bytes * 8);
        setReg(rd, (sf || opc === 3) ? val : val & 0xFFFFFFFFn, false);
      }
      if (writeback !== null) setReg(rn, writeback, true);
      pc = nextPc; return true;
    }
    if ((insn & 0x3F000000) === 0x08000000) {                                    // exclusives / atomics (simple model)
      const size = (insn >>> 30) & 3, L = (insn >> 21) & 1;
      const bytes = 1 << size, addr = getReg(rn, true);
      const rs = (insn >> 16) & 31;
      if (L) setReg(rd, readMem(addr, bytes), false);
      else {
        writeMem(addr, getReg(rd, false), bytes);
        if (rs !== 31) setReg(rs, 0n, false);                                    // exclusive store: report success
      }
      pc = nextPc; return true;
    }

    // --- data-processing register ---
    if ((insn & 0x1FE00000) === 0x0B200000) {                                    // ADD/SUB extended reg
      const isSub = (insn >>> 30) & 1, setF = (insn >>> 29) & 1;
      const opt = (insn >> 13) & 7, sh = (insn >> 10) & 7;
      let ext = getReg(rm, false);
      const from = [8, 16, 32, 64][opt & 3];
      ext &= (1n << BigInt(from)) - 1n;
      if (opt >= 4) ext = sext(ext, from);
      ext = (ext << BigInt(sh)) & M64;
      const a = getReg(rn, true) & wmask;
      const r = isSub ? (a - ext) & M64 : (a + ext) & M64;
      if (setF) { if (isSub) flagsSub(a, ext, r, bits); else flagsAdd(a, ext, r, bits); }
      if (!(setF && rd === 31)) setReg(rd, r & wmask, !setF);
      pc = nextPc; return true;
    }
    if ((insn & 0x1F200000) === 0x0B000000) {                                    // ADD/SUB shifted reg
      const isSub = (insn >>> 30) & 1, setF = (insn >>> 29) & 1;
      const sht = (insn >> 22) & 3, amt = (insn >> 10) & 0x3F;
      if (sht === 3) return undef(insn);
      const b = shiftReg(getReg(rm, false), sht, amt, bits);
      const a = getReg(rn, true) & wmask;
      const r = isSub ? (a - b) & M64 : (a + b) & M64;
      if (setF) { if (isSub) flagsSub(a, b, r, bits); else flagsAdd(a, b, r, bits); }
      if (!(setF && rd === 31)) setReg(rd, r & wmask, !setF);
      pc = nextPc; return true;
    }
    if ((insn & 0x1F000000) === 0x0A000000) {                                    // logical shifted reg
      const opc = (insn >>> 29) & 3, sht = (insn >> 22) & 3, Nin = (insn >> 21) & 1;
      let b = shiftReg(getReg(rm, false), sht, (insn >> 10) & 0x3F, bits);
      if (Nin) b = (~b) & wmask;
      const a = getReg(rn, false) & wmask;
      let r = opc === 1 ? (a | b) : opc === 2 ? (a ^ b) : (a & b);
      r &= wmask;
      if (opc === 3) flagsLogic(r, bits);
      if (!(opc === 3 && rd === 31)) setReg(rd, r, false);
      pc = nextPc; return true;
    }
    if ((insn & 0x1FE00000) === 0x1A000000) {                                    // ADC / SBC
      const isSub = (insn >>> 30) & 1, setF = (insn >>> 29) & 1;
      const a = getReg(rn, false) & wmask;
      let b = getReg(rm, false) & wmask;
      if (isSub) b = (~b) & wmask;
      const r = (a + b + BigInt(C)) & M64;
      if (setF) flagsAdd(a, b + BigInt(C) > wmask ? wmask : b, r, bits);         // close enough: carry via add of a+b+C below
      if (setF) {                                                                // exact carry/overflow for ADC/SBC
        const mask = wmask, sign = bits === 64 ? 0x8000000000000000n : 0x80000000n;
        const full = (a & mask) + (b & mask) + BigInt(C);
        N = (r & sign) ? 1 : 0; Z = ((r & mask) === 0n) ? 1 : 0;
        C = (full >> BigInt(bits)) & 1n ? 1 : 0;
        V = ((~(a ^ b) & (a ^ r)) & sign) ? 1 : 0;
      }
      setReg(rd, r & wmask, false);
      pc = nextPc; return true;
    }
    if ((insn & 0x3FE00000) === 0x3A400000) {                                    // CCMP / CCMN (register + immediate)
      const isSub = (insn >>> 30) & 1;                                           // 1 = CCMP, 0 = CCMN
      const cond = (insn >> 12) & 0xF, nzcv = insn & 0xF;
      const a = getReg(rn, false) & wmask;
      const b = ((insn >> 11) & 1) === 1 ? BigInt((insn >> 16) & 0x1F) : (getReg(rm, false) & wmask);
      if (condHolds(cond)) {
        if (isSub) { const r = (a - b) & M64; flagsSub(a, b, r, bits); }
        else { const r = (a + b) & M64; flagsAdd(a, b, r, bits); }
      } else { N = (nzcv >> 3) & 1; Z = (nzcv >> 2) & 1; C = (nzcv >> 1) & 1; V = nzcv & 1; }
      pc = nextPc; return true;
    }
    if ((insn & 0x1FE00000) === 0x1A800000) {                                    // CSEL family
      const op = (insn >>> 30) & 1, op2 = (insn >> 10) & 3;
      const cond = (insn >> 12) & 0xF;
      const a = getReg(rn, false) & wmask, b = getReg(rm, false) & wmask;
      let alt;
      if (op === 0 && op2 === 0) alt = b;                                        // CSEL
      else if (op === 0 && op2 === 1) alt = (b + 1n) & M64;                      // CSINC
      else if (op === 1 && op2 === 0) alt = (~b) & M64;                          // CSINV
      else if (op === 1 && op2 === 1) alt = (-b) & M64;                          // CSNEG
      else return undef(insn);
      setReg(rd, (condHolds(cond) ? a : alt) & wmask, false);
      pc = nextPc; return true;
    }
    if (((insn & 0xFFFF0000) >>> 0) === 0xDAC10000) {
      // PACIA/PACIB/PACDA/PACDB/AUTIA/AUTIB/AUTDA/AUTDB + XPAC: pointer
      // authentication is not modelled; signing/authenticating is a no-op.
      // Must sit before DP 2-source, whose mask also matches 0xDAC1xxxx.
      pc = nextPc; return true;
    }
    if ((insn & 0x5FE00000) === 0x5AC00000) {                                    // DP 1-source — must precede DP 2-source:
      const opc = (insn >> 10) & 0x3F;                                          // DP2's mask lacks the S bit and steals these
      const a = getReg(rn, false) & wmask;
      let r;
      if (opc === 0) {                                                           // RBIT
        r = 0n;
        for (let i = 0; i < bits; i++) if ((a >> BigInt(i)) & 1n) r |= 1n << BigInt(bits - 1 - i);
      } else if (opc === 1) {                                                    // REV16
        r = 0n;
        for (let i = 0; i < bits; i += 16) r |= ((a >> BigInt(i)) & 0xFFn) << BigInt(i + 8) | ((a >> BigInt(i + 8)) & 0xFFn) << BigInt(i);
      } else if (opc === 2 || opc === 3) {                                       // REV (32-bit / 64-bit forms)
        r = 0n;
        const nb = bits / 8;
        for (let i = 0; i < nb; i++) r |= ((a >> BigInt(8 * i)) & 0xFFn) << BigInt(8 * (nb - 1 - i));
      } else if (opc === 4) {                                                    // CLZ
        r = BigInt(bits);
        for (let i = bits - 1; i >= 0; i--) if ((a >> BigInt(i)) & 1n) { r = BigInt(bits - 1 - i); break; }
      } else if (opc === 5) {                                                    // CLS
        const sign = (a >> BigInt(bits - 1)) & 1n;
        r = BigInt(bits - 1);
        for (let i = bits - 2; i >= 0; i--) {
          if (((a >> BigInt(i)) & 1n) !== sign) { r = BigInt(bits - 2 - i); break; }
          if (i === 0) r = BigInt(bits - 1);
        }
      } else return undef(insn);
      setReg(rd, r & wmask, false);
      pc = nextPc; return true;
    }
    if ((insn & 0x1FE00000) === 0x1AC00000) {                                    // DP 2-source
      const opc = (insn >> 10) & 0x3F;
      const a = getReg(rn, false) & wmask, b = getReg(rm, false) & wmask;
      let r;
      if (opc === 2) r = b === 0n ? 0n : a / b;                                  // UDIV
      else if (opc === 3) {                                                      // SDIV
        if (b === 0n) r = 0n;
        else {
          const sa = sext(a, bits), sb = sext(b, bits);
          const q = sa / sb;                                                     // BigInt division truncates toward zero
          r = q & wmask;
        }
      }
      else if (opc === 8) r = shiftReg(a, 0, Number(b & BigInt(bits - 1)), bits);   // LSLV
      else if (opc === 9) r = shiftReg(a, 1, Number(b & BigInt(bits - 1)), bits);   // LSRV
      else if (opc === 10) r = shiftReg(a, 2, Number(b & BigInt(bits - 1)), bits);  // ASRV
      else if (opc === 11) r = shiftReg(a, 3, Number(b & BigInt(bits - 1)), bits);  // RORV
      else return undef(insn);
      setReg(rd, r & wmask, false);
      pc = nextPc; return true;
    }
    if ((insn & 0x1FE00000) === 0x1B000000) {                                    // MADD / MSUB
      const ra = (insn >> 10) & 31, o0 = (insn >> 15) & 1;
      const prod = (getReg(rn, false) & wmask) * (getReg(rm, false) & wmask);
      const acc = getReg(ra, false) & wmask;
      setReg(rd, (o0 ? acc - prod : acc + prod) & wmask, false);
      pc = nextPc; return true;
    }
    if (((insn >>> 31) & 1) === 1 &&
        ((insn & 0x1FE00000) === 0x1B200000 || (insn & 0x1FE00000) === 0x1B400000 ||
         (insn & 0x1FE00000) === 0x1BA00000 || (insn & 0x1FE00000) === 0x1BC00000)) {
      // Multiply long / high: SMADDL/SMSUBL (op31 1), SMULH (2), UMADDL/UMSUBL (5), UMULH (6)
      const op31 = (insn >>> 21) & 7, o0 = (insn >> 15) & 1, ra = (insn >> 10) & 31;
      let r;
      if (op31 === 2 || op31 === 6) {                                           // SMULH / UMULH
        if (ra !== 31) return undef(insn);
        const a = getReg(rn, false), b = getReg(rm, false);
        if (op31 === 2) {
          const sa = (a & (1n << 63n)) ? a - (1n << 64n) : a;
          const sb = (b & (1n << 63n)) ? b - (1n << 64n) : b;
          r = (sa * sb) >> 64n;
        } else r = (a * b) >> 64n;
      } else {                                                                  // SMADDL / UMADDL family (32-bit sources)
        const a32 = getReg(rn, false) & 0xFFFFFFFFn, b32 = getReg(rm, false) & 0xFFFFFFFFn;
        let prod;
        if (op31 === 1) {
          const sa = (a32 & 0x80000000n) ? a32 - (1n << 32n) : a32;
          const sb = (b32 & 0x80000000n) ? b32 - (1n << 32n) : b32;
          prod = sa * sb;
        } else prod = a32 * b32;
        r = o0 ? getReg(ra, false) - prod : getReg(ra, false) + prod;
      }
      setReg(rd, r & M64, false);
      pc = nextPc; return true;
    }

    return undef(insn);
  }

  return {
    loadBytes, readMem, writeMem,
    get pc() { return pc; }, set pc(v) { pc = v & M64; },
    get sp() { return sp; }, set sp(v) { sp = v & M64; },
    get vregs() { return v; },
    get status() { return status; },
    get trapInfo() { return trapInfo; },
    get icount() { return icount; },
    get mmioLog() { return mmioLog; },
    get mmuOn() { return mmuOn; },
    get exceptions() { return excCount; },
    get lastException() { return lastExc; },
    regs: x,
    sysregs, readPhys, writePhys,
    step,
    run(max) {
      let n = 0;
      if (status === "breakpoint") { status = "ready"; if (!step()) return status; n++; }
      while (n < max) {
        if (status === "halted" || status === "trap" || status === "undefined" || status === "wfi") break;
        if (breakpoints.size !== 0 && breakpoints.has(pc.toString(16))) {
          status = "breakpoint";
          trapInfo = "breakpoint at PC 0x" + pc.toString(16);
          break;
        }
        if (!step()) break;
        n++;
      }
      return status;
    },
    // ---- backdoor: open access to the fake phone ----
    getReg, setReg,
    breakpoints,
    addBreakpoint(addr) { breakpoints.add((addr & M64).toString(16)); },
    clearBreakpoints() { breakpoints.clear(); },
    peekBytes(addr, len) {
      const out = new Uint8Array(len);
      for (let i = 0; i < len; i++) out[i] = Number(readMem(addr + BigInt(i), 1));
      return out;
    },
    peekQuiet(addr, len) {               // backdoor reads that never disturb the CPU state
      const s = status, t = trapInfo;
      const out = new Uint8Array(len);
      for (let i = 0; i < len; i++) out[i] = Number(readMem(addr + BigInt(i), 1));
      status = s; trapInfo = t;
      return out;
    },
    pokeQuiet(addr, bytes) {
      const s = status, t = trapInfo;
      for (let i = 0; i < bytes.length; i++) writeMem(addr + BigInt(i), BigInt(bytes[i]), 1);
      status = s; trapInfo = t;
    },
    lastPcs(n) {
      const out = [];
      for (let i = 0; i < Math.min(n, 64); i++) out.push(pcRing[(pcRingIdx - 1 - i + 128) & 63]);
      return out.reverse();
    },
    resume() { if (status === "breakpoint" || status === "wfi") status = "ready"; },
    queueUartRx(text) { for (const ch of String(text)) uartRxQueue.push(ch.charCodeAt(0) & 0xFF); },
    reset() {
      pages.clear(); sysregs.clear(); mmioLog.clear(); fetchPaBase = -1n; fetchPage = null;
      x.fill(0n); v.fill(0n); sp = 0n; pc = 0n; N = Z = C = V = 0;
      icount = 0; status = "ready"; trapInfo = ""; mmuOn = false;
    }
  };
}

if (typeof module !== "undefined") module.exports = { createMachine, DRAM_BASE, UART_BASE };

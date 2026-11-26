"use strict";
/*
 * Stage-2 boot loader for FakeDevice: parses the kernelcache Mach-O,
 * loads its segments at their real physical addresses, builds the
 * boot_args structure XNU expects in X0 (layout from Apple's
 * pexpert/pexpert/arm64/boot.h, revision 2), attaches a minimal
 * Apple Device Tree (ADT), and starts the CPU at the true entry point
 * taken from LC_UNIXTHREAD.
 *
 * Address plan (t8030 / iPhone 11):
 *   DRAM base        0x800000000
 *   kernel phys base 0x800004000   (virt base 0xFFFFFFF007004000)
 *   boot_args        right after the kernel image
 *   ADT              one page after boot_args
 */
const KC_VIRT_BASE = 0xFFFFFFF007004000n;
const KC_PHYS_BASE = 0x801004000n;   // this kernelcache's expected load base: its early
                                     // page tables map VA->PA for exactly this placement
                                     // (proven 2026-11-26: the L2 descriptor output is the
                                     // same constant no matter where the image is loaded;
                                     // at 0x800004000 the post-MMU jump lands 16 MB off)
const MEM_SIZE = 0x100000000n;             // 4 GiB, like the iPhone 11

function parseMachO(bytes) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const magic = dv.getUint32(0, true);
  if (magic !== 0xFEEDFACF) throw new Error("not a 64-bit Mach-O (magic 0x" + magic.toString(16) + ")");
  const ncmds = dv.getUint32(16, true);
  const segments = [];
  let entry = null;
  let off = 32;
  for (let i = 0; i < ncmds; i++) {
    const cmd = dv.getUint32(off, true), cmdsize = dv.getUint32(off + 4, true);
    if (cmd === 0x19) {                    // LC_SEGMENT_64
      let name = "";
      for (let j = 0; j < 16; j++) {
        const c = dv.getUint8(off + 8 + j);
        if (!c) break;
        name += String.fromCharCode(c);
      }
      segments.push({
        name,
        vmaddr: dv.getBigUint64(off + 24, true),
        vmsize: dv.getBigUint64(off + 32, true),
        fileoff: dv.getBigUint64(off + 40, true),
        filesize: dv.getBigUint64(off + 48, true),
      });
    } else if (cmd === 0x5) {              // LC_UNIXTHREAD
      // ARM_THREAD_STATE64: x0..x28, fp, lr, sp, pc, cpsr — pc is register index 32
      entry = dv.getBigUint64(off + 16 + 32 * 8, true);
    }
    off += cmdsize;
  }
  return { segments, entry };
}

// ---- minimal Apple Device Tree ----
function adtProp(name, value) {
  const out = [];
  const nb = new Uint8Array(32);
  for (let i = 0; i < name.length && i < 32; i++) nb[i] = name.charCodeAt(i);
  out.push(nb);
  const sz = new Uint8Array(4);
  new DataView(sz.buffer).setUint32(0, value.length, true);
  out.push(sz);
  out.push(value);
  const pad = (4 - (value.length % 4)) % 4;
  if (pad) out.push(new Uint8Array(pad));
  return out;
}
function adtU32(v) { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, v, false); return b; }  // cells are big-endian
function adtStr(s) { const b = new Uint8Array(s.length + 1); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i); return b; }
function adtReg(addr, size) {
  const b = new Uint8Array(16), dv = new DataView(b.buffer);
  dv.setUint32(0, Number(addr >> 32n), false);
  dv.setUint32(4, Number(addr & 0xFFFFFFFFn), false);
  dv.setUint32(8, Number(size >> 32n), false);
  dv.setUint32(12, Number(size & 0xFFFFFFFFn), false);
  return b;
}
function adtNode(name, props, children) {
  const allProps = [adtProp("name", adtStr(name)), ...props];
  const head = new Uint8Array(8), dv = new DataView(head.buffer);
  dv.setUint32(0, allProps.length, true);
  dv.setUint32(4, children.length, true);
  return concatBytes([head, ...allProps.flat(), ...children]);
}
function concatBytes(list) {
  let n = 0;
  for (const b of list) n += b.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const b of list) { out.set(b, o); o += b.length; }
  return out;
}
function buildADT(uartBase) {
  const uart0 = adtNode("uart0", [
    adtProp("compatible", adtStr("samsung,uart")),
    adtProp("reg", adtReg(uartBase, 0x1000n)),
    adtProp("interrupts", concatBytes([adtU32(0), adtU32(0x51), adtU32(0)])),
  ], []);
  const armIo = adtNode("arm-io", [
    adtProp("compatible", adtStr("arm-io,t8030")),
    adtProp("device_type", adtStr("arm-io")),
    adtProp("#address-cells", adtU32(2)),
    adtProp("#size-cells", adtU32(2)),
    adtProp("reg", adtReg(0x200000000n, 0x100000000n)),
    adtProp("ranges", new Uint8Array(0)),
  ], [uart0]);
  // /chosen/random-seed: real iBoot fills this from the hardware RNG. A fixed
  // pattern here on purpose — the emulator stays deterministic run to run.
  const seed = new Uint8Array(64);
  for (let i = 0; i < 64; i++) seed[i] = (i * 37 + 11) & 0xFF;
  const chosen = adtNode("chosen", [
    adtProp("random-seed", seed),
  ], []);
  const memory = adtNode("memory", [
    adtProp("reg", adtReg(0x800000000n, MEM_SIZE)),
  ], []);
  // A13 (t8030): 4 Thunder efficiency cores (cluster 'E', MPIDR 0x00-0x03) and
  // 2 Lightning performance cores (cluster 'P', MPIDR 0x100-0x101). The kernel's
  // ml_parse_cpu_topology requires "state" ("running" = boot CPU) and "reg" on
  // every cpu child; the rest have defaults.
  const cpuNode = (n, reg, cluster, state) => adtNode("cpu@" + n, [
    adtProp("compatible", adtStr(cluster === 0x50 ? "apple,lightning" : "apple,thunder")),
    adtProp("device_type", adtStr("cpu")),
    adtProp("reg", adtU32(reg)),
    adtProp("state", adtStr(state)),
    adtProp("cluster-type", adtU32(cluster)),
  ], []);
  const cpus = adtNode("cpus", [
    adtProp("#address-cells", adtU32(1)),
    adtProp("#size-cells", adtU32(0)),
  ], [
    cpuNode(0, 0x000, 0x45, "running"),
    cpuNode(1, 0x001, 0x45, "idle"),
    cpuNode(2, 0x002, 0x45, "idle"),
    cpuNode(3, 0x003, 0x45, "idle"),
    cpuNode(4, 0x100, 0x50, "idle"),
    cpuNode(5, 0x101, 0x50, "idle"),
  ]);
  const root = adtNode("/", [
    adtProp("compatible", adtStr("apple,t8030")),
    adtProp("model", adtStr("iPhone12,1")),
    adtProp("#address-cells", adtU32(2)),
    adtProp("#size-cells", adtU32(2)),
  ], [chosen, memory, cpus, armIo]);
  return root;
}

// ---- boot_args (arm64, revision 2) ----
function buildBootArgs(m, bootArgsAddr, adtAddr, adtLen, topOfKernelData) {
  const w64 = (off, v) => {                  // little-endian via machine writes
    for (let i = 0; i < 8; i++) m.writeMem(bootArgsAddr + BigInt(off + i), (v >> BigInt(8 * i)) & 0xFFn, 1);
  };
  const w32 = (off, v) => {
    for (let i = 0; i < 4; i++) m.writeMem(bootArgsAddr + BigInt(off + i), BigInt((v >>> (8 * i)) & 0xFF), 1);
  };
  const w16 = (off, v) => {
    m.writeMem(bootArgsAddr + BigInt(off), BigInt(v & 0xFF), 1);
    m.writeMem(bootArgsAddr + BigInt(off + 1), BigInt((v >> 8) & 0xFF), 1);
  };
  for (let i = 0; i < 1152; i += 8) m.writeMem(bootArgsAddr + BigInt(i), 0n, 8);
  w16(0, 2);                                 // Revision
  w16(2, 2);                                 // Version
  w64(8, KC_VIRT_BASE);                      // virtBase
  w64(16, KC_PHYS_BASE);                     // physBase
  w64(24, MEM_SIZE);                         // memSize
  w64(32, topOfKernelData);                  // topOfKernelData
  // Video (40..87): all zero = no framebuffer, serial console only
  w32(88, 0);                                // machineType
  w64(96, adtAddr);                          // deviceTreeP (physical)
  w32(104, adtLen);                          // deviceTreeLength
  const cmdline = "-v";
  for (let i = 0; i < cmdline.length; i++) m.writeMem(bootArgsAddr + BigInt(112 + i), BigInt(cmdline.charCodeAt(i)), 1);
  w64(1136, 0n);                             // bootFlags
  w64(1144, MEM_SIZE);                       // memSizeActual
}

// ---- stage 4: the fake boot chain. On a real iPhone the chain is
// BootROM (mask ROM in the SoC) -> LLB -> iBoot -> kernel. Each stage below
// does the part of that layer's job the emulator actually depends on; the
// kernel itself is the genuine kernelcache, loaded unmodified by "iBoot".
function stageBootROM(m, bytes, log) {
  // BootROM's real job: verify the next stage's image and jump to it. Here it
  // validates the kernelcache container the chain will hand down.
  if (bytes.length < 4) throw new Error("BootROM: image too small");
  const magic = (bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)) >>> 0;
  if (magic !== 0xFEEDFACF) throw new Error("BootROM: bad Mach-O magic 0x" + magic.toString(16));
  const parsed = parseMachO(bytes);
  if (parsed.entry === null) throw new Error("BootROM: no LC_UNIXTHREAD entry point in this Mach-O");
  log("BootROM: image verified (Mach-O arm64, " + bytes.length.toString() + " bytes) — handing off to LLB");
  return parsed;
}
function stageLLB(m, log) {
  // LLB's real job: bring up DRAM and load iBoot. In the emulator DRAM is the
  // sparse page space (4 GiB window at 0x800000000), created on demand.
  log("LLB: DRAM up — " + (MEM_SIZE / 0x40000000n).toString() + " GiB at 0x800000000 — iBoot loaded, jumping");
}
function stageIBoot(m, bytes, parsed, log) {
  const { segments, entry } = parsed;
  let kernelTop = KC_PHYS_BASE;
  for (const s of segments) {
    if (s.filesize === 0n) continue;
    const phys = KC_PHYS_BASE + (s.vmaddr - KC_VIRT_BASE);
    m.loadBytes(phys, bytes.subarray(Number(s.fileoff), Number(s.fileoff + s.filesize)));
    const end = phys + s.vmsize;
    if (end > kernelTop) kernelTop = end;
    log("iBoot: loaded " + s.name + " at phys 0x" + phys.toString(16) + " (" + s.filesize.toString() + " bytes)");
  }
  const align = a => (a + 0x3FFFn) & ~0x3FFFn;
  const bootArgsAddr = align(kernelTop);
  const adtAddr = bootArgsAddr + 0x4000n;
  const adt = buildADT(0x235200000n);
  m.loadBytes(adtAddr, adt);
  const topOfKernelData = align(adtAddr + BigInt(adt.length));
  buildBootArgs(m, bootArgsAddr, adtAddr, adt.length, topOfKernelData);
  const entryPhys = KC_PHYS_BASE + (entry - KC_VIRT_BASE);
  m.regs[0] = bootArgsAddr;                  // X0 = boot_args, as iBoot leaves it
  m.pc = entryPhys;
  m.sp = 0n;                                 // kernel sets its own stack
  log("iBoot: kernel top phys 0x" + kernelTop.toString(16) +
      ", boot_args at 0x" + bootArgsAddr.toString(16) +
      ", ADT " + adt.length + " bytes at 0x" + adtAddr.toString(16));
  log("iBoot: jumping to kernel — entry virt 0x" + entry.toString(16) + " -> phys 0x" + entryPhys.toString(16) + ", X0 = boot_args");
  return { entryPhys, bootArgsAddr, adtAddr };
}
function bootKernel(m, bytes, log) {
  const parsed = stageBootROM(m, bytes, log);
  stageLLB(m, log);
  return stageIBoot(m, bytes, parsed, log);
}

if (typeof module !== "undefined") module.exports = { parseMachO, buildADT, buildBootArgs, bootKernel, stageBootROM, stageLLB, stageIBoot, KC_PHYS_BASE, KC_VIRT_BASE };

// Boot.swift — FakeDeviceCore
//
// The fake boot chain, ported from boot.js: BootROM (validates the
// image) -> LLB (DRAM up) -> iBoot (Mach-O segment load, boot_args
// revision 2, minimal Apple Device Tree), starting the CPU at the true
// LC_UNIXTHREAD entry point. The kernelcache is loaded unmodified.

import Foundation

public let KC_VIRT_BASE: UInt64 = 0xFFFFFFF007004000
public let KC_PHYS_BASE: UInt64 = 0x801004000   // this kernelcache's expected load base

public struct BootError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct MachOSegment {
    public var name: String
    public var vmaddr: UInt64
    public var vmsize: UInt64
    public var fileoff: UInt64
    public var filesize: UInt64
}

public struct MachOImage {
    public var segments: [MachOSegment]
    public var entry: UInt64?
}

private func rd32(_ b: [UInt8], _ off: Int) -> UInt32 {
    UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
}
private func rd64(_ b: [UInt8], _ off: Int) -> UInt64 {
    var v: UInt64 = 0
    var i = 7
    while i >= 0 { v = (v << 8) | UInt64(b[off + i]); i -= 1 }
    return v
}

public func parseMachO(_ bytes: [UInt8]) throws -> MachOImage {
    let magic = rd32(bytes, 0)
    if magic != 0xFEEDFACF { throw BootError("not a 64-bit Mach-O (magic 0x" + String(magic, radix: 16) + ")") }
    let ncmds = Int(rd32(bytes, 16))
    var segments: [MachOSegment] = []
    var entry: UInt64? = nil
    var off = 32
    for _ in 0..<ncmds {
        let cmd = rd32(bytes, off), cmdsize = Int(rd32(bytes, off + 4))
        if cmd == 0x19 {                    // LC_SEGMENT_64
            var name = ""
            for j in 0..<16 {
                let c = bytes[off + 8 + j]
                if c == 0 { break }
                name += String(UnicodeScalar(c))
            }
            segments.append(MachOSegment(
                name: name,
                vmaddr: rd64(bytes, off + 24),
                vmsize: rd64(bytes, off + 32),
                fileoff: rd64(bytes, off + 40),
                filesize: rd64(bytes, off + 48)))
        } else if cmd == 0x5 {              // LC_UNIXTHREAD: pc is register index 32
            entry = rd64(bytes, off + 16 + 32 * 8)
        }
        off += cmdsize
    }
    return MachOImage(segments: segments, entry: entry)
}

// MARK: - Minimal Apple Device Tree

private func adtProp(_ name: String, _ value: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    var nb = [UInt8](repeating: 0, count: 32)
    let nameBytes = Array(name.utf8)
    for i in 0..<min(nameBytes.count, 32) { nb[i] = nameBytes[i] }
    out += nb
    let sz = UInt32(value.count)
    out += [UInt8(sz & 0xFF), UInt8((sz >> 8) & 0xFF), UInt8((sz >> 16) & 0xFF), UInt8((sz >> 24) & 0xFF)]  // little-endian
    out += value
    let pad = (4 - (value.count % 4)) % 4
    if pad > 0 { out += [UInt8](repeating: 0, count: pad) }
    return out
}
private func adtU32(_ v: UInt32) -> [UInt8] {   // cells are big-endian
    [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}
private func adtStr(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }
private func adtReg(_ addr: UInt64, _ size: UInt64) -> [UInt8] {
    adtU32(UInt32(addr >> 32)) + adtU32(UInt32(addr & 0xFFFFFFFF)) + adtU32(UInt32(size >> 32)) + adtU32(UInt32(size & 0xFFFFFFFF))
}
private func adtNode(_ name: String, _ props: [[UInt8]], _ children: [[UInt8]]) -> [UInt8] {
    let allProps = [adtProp("name", adtStr(name))] + props
    var out = [UInt8]()
    let np = UInt32(allProps.count), nc = UInt32(children.count)
    out += [UInt8(np & 0xFF), UInt8((np >> 8) & 0xFF), UInt8((np >> 16) & 0xFF), UInt8((np >> 24) & 0xFF)]
    out += [UInt8(nc & 0xFF), UInt8((nc >> 8) & 0xFF), UInt8((nc >> 16) & 0xFF), UInt8((nc >> 24) & 0xFF)]
    for p in allProps { out += p }
    for c in children { out += c }
    return out
}

public func buildADT(_ uartBase: UInt64) -> [UInt8] {
    let uart0 = adtNode("uart0", [
        adtProp("compatible", adtStr("samsung,uart")),
        adtProp("reg", adtReg(uartBase, 0x1000)),
        adtProp("interrupts", adtU32(0) + adtU32(0x51) + adtU32(0)),
    ], [])
    let armIo = adtNode("arm-io", [
        adtProp("compatible", adtStr("arm-io,t8030")),
        adtProp("device_type", adtStr("arm-io")),
        adtProp("#address-cells", adtU32(2)),
        adtProp("#size-cells", adtU32(2)),
        adtProp("reg", adtReg(0x200000000, 0x100000000)),
        adtProp("ranges", []),
    ], [uart0])
    // /chosen/random-seed: a fixed pattern on purpose — deterministic run to run.
    var seed = [UInt8](repeating: 0, count: 64)
    for i in 0..<64 { seed[i] = UInt8((i * 37 + 11) & 0xFF) }
    let chosen = adtNode("chosen", [
        adtProp("random-seed", seed),
    ], [])
    let memory = adtNode("memory", [
        adtProp("reg", adtReg(0x800000000, MEM_SIZE)),
    ], [])
    // A13 (t8030): 4 Thunder (cluster 'E') + 2 Lightning (cluster 'P') cores.
    func cpuNode(_ n: Int, _ reg: UInt32, _ cluster: UInt32, _ state: String) -> [UInt8] {
        adtNode("cpu@\(n)", [
            adtProp("compatible", adtStr(cluster == 0x50 ? "apple,lightning" : "apple,thunder")),
            adtProp("device_type", adtStr("cpu")),
            adtProp("reg", adtU32(reg)),
            adtProp("state", adtStr(state)),
            adtProp("cluster-type", adtU32(cluster)),
        ], [])
    }
    let cpus = adtNode("cpus", [
        adtProp("#address-cells", adtU32(1)),
        adtProp("#size-cells", adtU32(0)),
    ], [
        cpuNode(0, 0x000, 0x45, "running"),
        cpuNode(1, 0x001, 0x45, "idle"),
        cpuNode(2, 0x002, 0x45, "idle"),
        cpuNode(3, 0x003, 0x45, "idle"),
        cpuNode(4, 0x100, 0x50, "idle"),
        cpuNode(5, 0x101, 0x50, "idle"),
    ])
    let root = adtNode("/", [
        adtProp("compatible", adtStr("apple,t8030")),
        adtProp("model", adtStr("iPhone12,1")),
        adtProp("#address-cells", adtU32(2)),
        adtProp("#size-cells", adtU32(2)),
    ], [chosen, memory, cpus, armIo])
    return root
}

// MARK: - boot_args (arm64, revision 2)

public func buildBootArgs(_ m: Machine, _ bootArgsAddr: UInt64, _ adtAddr: UInt64, _ adtLen: Int, _ topOfKernelData: UInt64) throws {
    func w64(_ off: Int, _ v: UInt64) throws {
        for i in 0..<8 { try m.writeMem(bootArgsAddr &+ UInt64(off + i), 1, (v >> (8 * i)) & 0xFF) }
    }
    func w32(_ off: Int, _ v: UInt32) throws {
        for i in 0..<4 { try m.writeMem(bootArgsAddr &+ UInt64(off + i), 1, UInt64((v >> (8 * i)) & 0xFF)) }
    }
    func w16(_ off: Int, _ v: UInt64) throws {
        try m.writeMem(bootArgsAddr &+ UInt64(off), 1, v & 0xFF)
        try m.writeMem(bootArgsAddr &+ UInt64(off + 1), 1, (v >> 8) & 0xFF)
    }
    var i = 0
    while i < 1152 { try m.writeMem(bootArgsAddr &+ UInt64(i), 8, 0); i += 8 }
    try w16(0, 2)                                   // Revision
    try w16(2, 2)                                   // Version
    try w64(8, KC_VIRT_BASE)                        // virtBase
    try w64(16, KC_PHYS_BASE)                       // physBase
    try w64(24, MEM_SIZE)                           // memSize
    try w64(32, topOfKernelData)                    // topOfKernelData
    // Video (40..87): all zero = no framebuffer, serial console only
    try w32(88, 0)                                  // machineType
    try w64(96, adtAddr)                            // deviceTreeP (physical)
    try w32(104, UInt32(adtLen))                    // deviceTreeLength
    let cmdline = "-v"
    for (j, ch) in cmdline.enumerated() { try m.writeMem(bootArgsAddr &+ UInt64(112 + j), 1, UInt64(ch.unicodeScalars.first!.value)) }
    try w64(1136, 0)                                // bootFlags
    try w64(1144, MEM_SIZE)                         // memSizeActual
}

// MARK: - The fake boot chain: BootROM -> LLB -> iBoot

public struct BootResult {
    public var entryPhys: UInt64
    public var bootArgsAddr: UInt64
    public var adtAddr: UInt64
}

public func stageBootROM(_ bytes: [UInt8], _ log: (String) -> Void) throws -> MachOImage {
    if bytes.count < 4 { throw BootError("BootROM: image too small") }
    let magic = rd32(bytes, 0)
    if magic != 0xFEEDFACF { throw BootError("BootROM: bad Mach-O magic 0x" + String(magic, radix: 16)) }
    let parsed = try parseMachO(bytes)
    if parsed.entry == nil { throw BootError("BootROM: no LC_UNIXTHREAD entry point in this Mach-O") }
    log("BootROM: image verified (Mach-O arm64, \(bytes.count) bytes) — handing off to LLB")
    return parsed
}

public func stageLLB(_ log: (String) -> Void) {
    log("LLB: DRAM up — \(MEM_SIZE / 0x40000000) GiB at 0x800000000 — iBoot loaded, jumping")
}

public func stageIBoot(_ m: Machine, _ bytes: [UInt8], _ parsed: MachOImage, _ log: (String) -> Void) throws -> BootResult {
    var kernelTop = KC_PHYS_BASE
    for s in parsed.segments {
        if s.filesize == 0 { continue }
        let phys = KC_PHYS_BASE &+ (s.vmaddr &- KC_VIRT_BASE)
        let start = Int(s.fileoff), end = Int(s.fileoff + s.filesize)
        m.loadBytes(phys, Array(bytes[start..<end]))
        let segEnd = phys &+ s.vmsize
        if segEnd > kernelTop { kernelTop = segEnd }
        log("iBoot: loaded \(s.name) at phys \(hexStr(phys)) (\(s.filesize) bytes)")
    }
    func align(_ a: UInt64) -> UInt64 { (a &+ 0x3FFF) & ~0x3FFF }
    let bootArgsAddr = align(kernelTop)
    let adtAddr = bootArgsAddr &+ 0x4000
    let adt = buildADT(0x235200000)
    m.loadBytes(adtAddr, adt)
    let topOfKernelData = align(adtAddr &+ UInt64(adt.count))
    try buildBootArgs(m, bootArgsAddr, adtAddr, adt.count, topOfKernelData)
    let entry = parsed.entry!
    let entryPhys = KC_PHYS_BASE &+ (entry &- KC_VIRT_BASE)
    m.x[0] = bootArgsAddr                           // X0 = boot_args, as iBoot leaves it
    m.pc = entryPhys
    m.sp = 0                                        // kernel sets its own stack
    log("iBoot: kernel top phys \(hexStr(kernelTop)), boot_args at \(hexStr(bootArgsAddr)), ADT \(adt.count) bytes at \(hexStr(adtAddr))")
    log("iBoot: jumping to kernel — entry virt \(hexStr(entry)) -> phys \(hexStr(entryPhys)), X0 = boot_args")
    return BootResult(entryPhys: entryPhys, bootArgsAddr: bootArgsAddr, adtAddr: adtAddr)
}

public func bootKernel(_ m: Machine, _ bytes: [UInt8], _ log: (String) -> Void) throws -> BootResult {
    let parsed = try stageBootROM(bytes, log)
    stageLLB(log)
    return try stageIBoot(m, bytes, parsed, log)
}

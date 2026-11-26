// Boot.swift — FakeDeviceCore
//
// The fake boot chain, ported from boot.js: BootROM (validates the
// image) -> LLB (DRAM up) -> iBoot (Mach-O segment load, boot_args
// revision 2, minimal Apple Device Tree), starting the CPU at the true
// LC_UNIXTHREAD entry point. The kernelcache is loaded unmodified.
// Every machine-specific value (load bases, DRAM size, UART, CPU
// topology, ADT content, boot_args template) comes from the loaded
// translator pack — nothing about a specific device is compiled in.

import Foundation

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

// MARK: - Minimal Apple Device Tree (structure from the pack)

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
// ADT integer property values are stored LITTLE-ENDIAN, in the machine's
// native format — NOT the FDT/OpenFirmware big-endian cell format. Proven
// from the kernel's own consumers (stage-5 frontier 3): XNU's ml_readprop()
// raw-loads a uint32_t/uint64_t from the property bytes, ml_read_reg_range()
// raw-loads a uint64_t pair, and pe_arm_get_soc_base_phys() reads the arm-io
// "ranges" property as a uintptr_t array whose element [1] is the SoC base.
private func adtU32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}
private func adtU64(_ v: UInt64) -> [UInt8] {
    (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) }
}
private func adtStr(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }
private func adtReg(_ addr: UInt64, _ size: UInt64) -> [UInt8] {
    // A "reg" property is exactly two little-endian uint64s: (address, size)
    adtU64(addr) + adtU64(size)
}
private func adtRanges(_ list: [TranslatorPack.ArmIo.Range]) -> [UInt8] {
    // A "ranges" property is an array of little-endian uint64 triplets
    // (childAddress, parentAddress, size)
    list.flatMap { adtU64(TranslatorPack.hex($0.childAddress)) + adtU64(TranslatorPack.hex($0.parentAddress)) + adtU64(TranslatorPack.hex($0.size)) }
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

public func buildADT(_ pack: TranslatorPack) -> [UInt8] {
    // A child device's ADT "reg" address is an OFFSET within its parent
    // bus: the kernel computes the physical address as socBase + reg[0],
    // where socBase is ranges[1] of the arm-io node. pack.uart.base is the
    // full physical address, so the tree stores base - armIoBase.
    let uartRegOffset = pack.uartBase &- TranslatorPack.hex(pack.armIo.regAddress)
    let uart0 = adtNode(pack.uart.name, [
        adtProp("compatible", adtStr(pack.uart.compatible)),
        adtProp("reg", adtReg(uartRegOffset, pack.uartSize)),
        adtProp("interrupts", pack.uart.interrupts.flatMap { adtU32($0) }),
        adtProp("interrupt-parent", adtU32(pack.uart.interruptParent)),
        adtProp("AAPL,phandle", adtU32(pack.uart.phandle)),
    ], [])
    // The interrupt controller (stage-5 frontier 21): a real t8030 tree
    // has an AIC under arm-io. Without it, PE's
    // pe_arm_map_interrupt_controller fails (it looks up a node whose
    // "interrupt-controller" property reads "master"), the
    // AppleInterruptController driver can never start, and IOKit's DT
    // interrupt resolution can never succeed. "reg" is an offset within
    // arm-io, like every child device here.
    let aic = adtNode(pack.aic.name, [
        adtProp("compatible", adtStr(pack.aic.compatible)),
        adtProp("device_type", adtStr(pack.aic.deviceType)),
        adtProp("reg", adtReg(TranslatorPack.hex(pack.aic.regOffset), TranslatorPack.hex(pack.aic.regSize))),
        adtProp("interrupt-controller", adtStr(pack.aic.interruptControllerValue)),
        adtProp("#interrupt-cells", adtU32(pack.aic.interruptCells)),
        adtProp("aic-version", adtU32(pack.aic.aicVersion)),
        adtProp("AAPL,phandle", adtU32(pack.aic.phandle)),
    ], [])
    // PE also maps a "timer" device (device_type "timer") in the same
    // lookup; a real tree carries one under arm-io.
    let timer = adtNode(pack.timer.name, [
        adtProp("compatible", adtStr(pack.timer.compatible)),
        adtProp("device_type", adtStr(pack.timer.deviceType)),
        adtProp("reg", adtReg(TranslatorPack.hex(pack.timer.regOffset), TranslatorPack.hex(pack.timer.regSize))),
        adtProp("AAPL,phandle", adtU32(pack.timer.phandle)),
    ], [])
    let armIoProps: [[UInt8]] = [
        adtProp("compatible", adtStr(pack.armIo.compatible)),
        adtProp("device_type", adtStr(pack.armIo.deviceType)),
        adtProp("#address-cells", adtU32(pack.armIo.addressCells)),
        adtProp("#size-cells", adtU32(pack.armIo.sizeCells)),
        adtProp("reg", adtReg(TranslatorPack.hex(pack.armIo.regAddress), TranslatorPack.hex(pack.armIo.regSize))),
        adtProp("ranges", adtRanges(pack.armIo.ranges)),
        adtProp("AAPL,phandle", adtU32(pack.armIo.phandle)),
        // Devices under arm-io resolve their interrupts through the AIC:
        // IODTFindInterruptParent follows this phandle (the target
        // carries #interrupt-cells + AAPL,phandle — the aic node does).
        adtProp("interrupt-parent", adtU32(pack.armIo.interruptParent)),
    ]
    let armIo = adtNode(pack.armIo.name, armIoProps, [uart0, aic, timer])
    // /chosen/lock-regs: real iBoot describes the hardware lock apertures
    // here; the kernel's lock-regs init panics if the node, its "amcc"
    // child, or the amcc property set is missing (stage-5 frontier 14).
    // The kernel's reader fetches each named register as a
    // <name>-reg-offset / -reg-mask / -reg-value u32 triplet.
    func regProps(_ regs: [TranslatorPack.LockRegs.Reg]) -> [[UInt8]] {
        regs.flatMap { r -> [[UInt8]] in
            var ps = [adtProp(r.name + "-reg-offset", adtU32(r.offset)),
                      adtProp(r.name + "-reg-mask", adtU32(r.mask))]
            if let value = r.value { ps.append(adtProp(r.name + "-reg-value", adtU32(value))) }
            return ps
        }
    }
    let lr = pack.lockRegs
    let ctrrA = adtNode(lr.ctrrA.name, [
        adtProp("page-size-shift", adtU32(lr.ctrrA.pageSizeShift)),
        adtProp("lower-limit", adtU64(TranslatorPack.hex(lr.ctrrA.lowerLimit))),
        adtProp("upper-limit", adtU64(TranslatorPack.hex(lr.ctrrA.upperLimit))),
        adtProp("lock", adtU32(lr.ctrrA.lock)),
        adtProp("enable", adtU32(lr.ctrrA.enable)),
        adtProp("write-disable", adtU32(lr.ctrrA.writeDisable)),
    ] + regProps(lr.ctrrA.regs), [])
    let amcc = adtNode(lr.amcc.name, [
        adtProp("aperture-count", adtU32(lr.amcc.apertureCount)),
        adtProp("aperture-size", adtU32(UInt32(TranslatorPack.hex(lr.amcc.apertureSize)))),
        adtProp("plane-count", adtU32(lr.amcc.planeCount)),
        adtProp("plane-stride", adtU32(lr.amcc.planeStride)),
        adtProp("aperture-phys-addr", lr.amcc.aperturePhysAddr.flatMap { adtU64(TranslatorPack.hex($0)) }),
        adtProp("cache-status", adtU32(lr.amcc.cacheStatus)),
    ] + regProps(lr.amcc.regs), [ctrrA])
    let lockRegs = adtNode(lr.name, [], [amcc])
    // /chosen/random-seed: real iBoot fills this from the hardware RNG; the
    // pack carries a fixed seed so runs stay deterministic.
    let chosen = adtNode(pack.deviceTree.chosenNodeName, [
        adtProp("random-seed", pack.randomSeed),
        // arm_init() reads gDramBase/gDramSize from these two /chosen
        // properties (raw uint64 loads) and panics if either is missing —
        // real iBoot always supplies them (stage-5 frontier 4).
        adtProp("dram-base", adtU64(pack.dramBase)),
        adtProp("dram-size", adtU64(pack.dramSize)),
    ], [lockRegs])
    let memory = adtNode(pack.deviceTree.memoryNodeName, [
        adtProp("reg", adtReg(pack.dramBase, pack.dramSize)),
    ], [])
    // CPU topology from the pack; the kernel's topology parser requires
    // "state" ("running" = boot CPU) and "reg" on every cpu child.
    func cpuNode(_ cpu: TranslatorPack.Cpus.Cpu) -> [UInt8] {
        adtNode(cpu.name, [
            adtProp("compatible", adtStr(cpu.compatible)),
            adtProp("device_type", adtStr(pack.cpus.deviceType)),
            adtProp("reg", adtU32(cpu.reg)),
            adtProp("state", adtStr(cpu.state)),
            adtProp("cluster-type", adtU32(cpu.clusterType)),
        ], [])
    }
    let cpus = adtNode(pack.cpus.name, [
        adtProp("#address-cells", adtU32(pack.cpus.addressCells)),
        adtProp("#size-cells", adtU32(pack.cpus.sizeCells)),
    ], pack.cpus.list.map(cpuNode))
    // /defaults: real iBoot trees carry a "defaults" node; this kernel
    // version does not consume it, but it belongs in a faithful tree.
    // Its "serial-device" property carries the console UART's
    // AAPL,phandle. The serial console itself is enabled by the
    // debug=0xa boot-arg (DB_PRT|DB_KPRT) and by the uart0 node's name
    // + "uart-1,samsung" compatible, which the kernel's PE serial init
    // matches by string (stage-5 frontier 22).
    let defaults = adtNode(pack.defaults.name, [
        adtProp("serial-device", adtU32(pack.uart.phandle)),
    ], [])
    let root = adtNode(pack.deviceTree.rootName, [
        adtProp("compatible", adtStr(pack.deviceTree.rootCompatible)),
        adtProp("model", adtStr(pack.deviceTree.model)),
        adtProp("#address-cells", adtU32(pack.deviceTree.rootAddressCells)),
        adtProp("#size-cells", adtU32(pack.deviceTree.rootSizeCells)),
    ], [chosen, memory, cpus, armIo, defaults])
    return root
}

// MARK: - boot_args (arm64, revision 2 layout; values from the pack)

public func buildBootArgs(_ m: Machine, _ pack: TranslatorPack, _ bootArgsAddr: UInt64, _ adtAddr: UInt64, _ adtLen: Int, _ topOfKernelData: UInt64) throws {
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
    let L = pack.bootArgs.layout                   // field offsets (boot.h rev 2), from the pack
    var i = 0
    while i < pack.bootArgs.structSize { try m.writeMem(bootArgsAddr &+ UInt64(i), 8, 0); i += 8 }
    try w16(L.revision, UInt64(pack.bootArgs.revision))
    try w16(L.version, UInt64(pack.bootArgs.version))
    try w64(L.virtBase, pack.kernelVirtBase)
    try w64(L.physBase, pack.kernelPhysBase)
    try w64(L.memSize, pack.dramSize)
    try w64(L.topOfKernelData, topOfKernelData)     // physical, per boot.h
    // Video: all zero = no framebuffer, serial console only
    try w32(L.machineType, pack.bootArgs.machineType)
    // deviceTreeP is a void* in boot.h: the kernel dereferences it as a
    // VIRTUAL address, so write phystokv(adtAddr), not the physical
    // address (stage-5 frontier 2 — see PACK.md).
    try w64(L.deviceTreeP, adtAddr &- pack.kernelPhysBase &+ pack.kernelVirtBase)
    try w32(L.deviceTreeLength, UInt32(adtLen))
    for (j, ch) in pack.bootArgs.commandLine.enumerated() {
        try m.writeMem(bootArgsAddr &+ UInt64(L.commandLine + j), 1, UInt64(ch.unicodeScalars.first!.value))
    }
    try w64(L.bootFlags, TranslatorPack.hex(pack.bootArgs.bootFlags))
    try w64(L.memSizeActual, pack.dramSize)
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

public func stageLLB(_ pack: TranslatorPack, _ log: (String) -> Void) {
    log("LLB: DRAM up — \(pack.dramSize / 0x40000000) GiB at \(hexStr(pack.dramBase)) — iBoot loaded, jumping")
}

public func stageIBoot(_ m: Machine, _ bytes: [UInt8], _ parsed: MachOImage, _ pack: TranslatorPack, _ log: (String) -> Void) throws -> BootResult {
    var kernelTop = pack.kernelPhysBase
    for s in parsed.segments {
        if s.filesize == 0 { continue }
        let phys = pack.kernelPhysBase &+ (s.vmaddr &- pack.kernelVirtBase)
        let start = Int(s.fileoff), end = Int(s.fileoff + s.filesize)
        m.loadBytes(phys, Array(bytes[start..<end]))
        let segEnd = phys &+ s.vmsize
        if segEnd > kernelTop { kernelTop = segEnd }
        log("iBoot: loaded \(s.name) at phys \(hexStr(phys)) (\(s.filesize) bytes)")
    }
    let pageMask = pack.pageSize &- 1
    func align(_ a: UInt64) -> UInt64 { (a &+ pageMask) & ~pageMask }
    let bootArgsAddr = align(kernelTop) &+ TranslatorPack.hex(pack.bootLayout.bootArgsOffsetFromKernelTop)
    let adtAddr = bootArgsAddr &+ TranslatorPack.hex(pack.bootLayout.adtOffsetFromBootArgs)
    let adt = buildADT(pack)
    m.loadBytes(adtAddr, adt)
    let topOfKernelData = align(adtAddr &+ UInt64(adt.count))
    try buildBootArgs(m, pack, bootArgsAddr, adtAddr, adt.count, topOfKernelData)
    let entry = parsed.entry!
    let entryPhys = pack.kernelPhysBase &+ (entry &- pack.kernelVirtBase)
    m.x[0] = bootArgsAddr                           // X0 = boot_args, as iBoot leaves it
    m.pc = entryPhys
    m.sp = 0                                        // kernel sets its own stack
    log("iBoot: kernel top phys \(hexStr(kernelTop)), boot_args at \(hexStr(bootArgsAddr)), ADT \(adt.count) bytes at \(hexStr(adtAddr))")
    log("iBoot: jumping to kernel — entry virt \(hexStr(entry)) -> phys \(hexStr(entryPhys)), X0 = boot_args")
    return BootResult(entryPhys: entryPhys, bootArgsAddr: bootArgsAddr, adtAddr: adtAddr)
}

public func bootKernel(_ m: Machine, _ bytes: [UInt8], _ pack: TranslatorPack, _ log: (String) -> Void) throws -> BootResult {
    let parsed = try stageBootROM(bytes, log)
    stageLLB(pack, log)
    return try stageIBoot(m, bytes, parsed, pack, log)
}

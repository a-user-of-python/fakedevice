// Machine.swift — FakeDeviceCore
//
// Native Swift port of the FakeDevice ARM64 interpreter core.
// Reference implementation: emu.js (repo build/ folder) — this port
// mirrors its semantics exactly, including its quirks, so the Swift
// core reaches the same machine states: same instruction counts, same
// faults, same endpoint when booting the real kernelcache.

import Foundation

public let PAGE_SIZE = 4096

let M64: UInt64 = 0xFFFFFFFFFFFFFFFF

/// 128-bit vector register value (two 64-bit halves), mirroring the
/// reference's 128-bit BigInt lanes.
struct V128: Equatable {
    var lo: UInt64 = 0
    var hi: UInt64 = 0
    static let zero = V128()
    func lane(_ esize: Int, _ idx: Int) -> UInt64 {
        if esize == 64 { return idx == 0 ? lo : hi }
        let bits = idx * esize
        let word = bits < 64 ? lo : hi
        return (word >> (bits & 63)) & laneMask(esize)
    }
    mutating func setLane(_ esize: Int, _ idx: Int, _ val: UInt64) {
        if esize == 64 { if idx == 0 { lo = val } else { hi = val }; return }
        let bits = idx * esize
        let off = bits & 63
        let m = laneMask(esize) << off
        if bits < 64 { lo = (lo & ~m) | ((val << off) & m) }
        else { hi = (hi & ~m) | ((val << off) & m) }
    }
    static func & (a: V128, b: V128) -> V128 { V128(lo: a.lo & b.lo, hi: a.hi & b.hi) }
    static func | (a: V128, b: V128) -> V128 { V128(lo: a.lo | b.lo, hi: a.hi | b.hi) }
    static func ^ (a: V128, b: V128) -> V128 { V128(lo: a.lo ^ b.lo, hi: a.hi ^ b.hi) }
    static prefix func ~ (a: V128) -> V128 { V128(lo: ~a.lo, hi: ~a.hi) }
    /// Keep only the low 64 bits (Q=0 forms).
    var lowOnly: V128 { V128(lo: lo, hi: 0) }
}

func laneMask(_ esize: Int) -> UInt64 {
    esize >= 64 ? M64 : (UInt64(1) << esize) - 1
}

/// A translation fault / undefined instruction, mirroring the record the
/// reference throws inside step() and catches to deliver an exception.
struct Fault: Error {
    var va: UInt64 = 0
    var level: Int = 3
    var write: Bool = false
    var fetch: Bool = false
    var undef: Bool = false
    var insn: UInt32 = 0
    var elr: UInt64 = 0
}

final class Page {
    var bytes = [UInt8](repeating: 0, count: PAGE_SIZE)
}

func sysKey(_ op0: Int, _ op1: Int, _ crn: Int, _ crm: Int, _ op2: Int) -> String {
    "\(op0),\(op1),\(crn),\(crm),\(op2)"
}
func hexStr(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }
/// Sign-extend the low `bits` of val to a full 64-bit pattern (the
/// reference's sext()).
func sext64(_ val: UInt64, _ bits: Int) -> UInt64 {
    if bits >= 64 { return val }
    if (val >> (bits - 1)) & 1 == 1 { return (val | (M64 ^ ((UInt64(1) << bits) - 1))) & M64 }
    return val & M64
}

public final class Machine {
    public var onUart: (UInt8) -> Void
    public var onLog: (String) -> Void
    /// The fake hardware this machine runs, from a translator pack.
    public let definition: MachineDefinition

    var pages: [UInt64: Page] = [:]
    public var x = [UInt64](repeating: 0, count: 31)
    var v = [V128](repeating: .zero, count: 32)
    public var sp: UInt64 = 0
    public var pc: UInt64 = 0
    var nFlag = 0, zFlag = 0, cFlag = 0, vFlag = 0
    public var icount = 0
    public var status = "ready"     // ready | halted | trap | undefined | wfi | breakpoint
    public var trapInfo = ""
    public var mmuOn = false
    var sysregs: [String: UInt64] = [:]
    /// CNTV deadline (stage-5 frontier 20): the absolute tick at which the
    /// virtual timer fires, set by CNTV_TVAL/CVAL writes; nil until the
    /// kernel first programs it. Stored as the raw 64-bit pattern of the
    /// signed BigInt the reference keeps.
    var cntvDeadline: UInt64? = nil
    var uartRxQueue: [UInt8] = []
    var tlb: [UInt64: UInt64] = [:]
    /// Insertion-ordered like the reference's Map (the backdoor prints it in order).
    public private(set) var mmioLog: [(key: String, count: Int)] = []
    var breakpoints: Set<String> = []
    /// Insertion order for breakpoints, for bplist (a Swift Set has no order).
    private(set) var breakpointList: [String] = []
    var pcRing = [UInt64](repeating: 0, count: 64)
    var pcRingIdx = 0
    var zvaSize = 64

    var lpKey: Int64 = -1
    var lpPage: Page? = nil
    var tlbVa: Int64 = -1
    var tlbPa: UInt64 = 0
    var fetchPage: Page? = nil
    var fetchPaBase: Int64 = -1

    var accessWrite = false
    var accessFetch = false
    var inStep = false
    var curInsnPc: UInt64 = 0
    var quietWalk = false
    var lastWalkLevel = 3
    public var exceptions = 0
    public var lastException = ""

    public init(onUart: @escaping (UInt8) -> Void, onLog: @escaping (String) -> Void, definition: MachineDefinition) {
        self.onUart = onUart
        self.onLog = onLog
        self.definition = definition
    }

    public func reset() {
        pages.removeAll()
        sysregs.removeAll()
        mmioLog.removeAll()
        fetchPage = nil
        fetchPaBase = -1
        x = [UInt64](repeating: 0, count: 31)
        v = [V128](repeating: .zero, count: 32)
        sp = 0
        pc = 0
        nFlag = 0; zFlag = 0; cFlag = 0; vFlag = 0
        icount = 0
        status = "ready"
        trapInfo = ""
        mmuOn = false
        // like the reference, reset() does NOT clear the TLB, lp cache,
        // breakpoints, UART RX queue or exception counters.
    }

    // MARK: - Physical memory

    func isRam(_ addr: UInt64) -> Bool { addr >= definition.dramBase && addr < definition.dramEnd }

    func pageFor(_ addr: UInt64, _ create: Bool) -> Page? {
        let key = Int64(addr >> 12)
        if key == lpKey {
            if let p = lpPage { return p }
            if !create { return nil }
            let p = Page()
            pages[UInt64(bitPattern: key)] = p
            lpPage = p
            return p
        }
        var p = pages[UInt64(bitPattern: key)]
        if p == nil && create {
            p = Page()
            pages[UInt64(bitPattern: key)] = p
        }
        lpKey = key
        lpPage = p
        return p
    }

    func noteMmio(_ addr: UInt64) {
        let k = hexStr(addr)
        if let i = mmioLog.firstIndex(where: { $0.key == k }) { mmioLog[i].count += 1 }
        else { mmioLog.append((key: k, count: 1)) }
    }

    func mmioRead(_ addr: UInt64) -> UInt64 {
        if addr >= definition.uartBase && addr < definition.uartBase &+ definition.uartSize {
            if addr - definition.uartBase == definition.uartUtrstat { return 0x6 | (uartRxQueue.isEmpty ? 0 : 1) }
            if addr - definition.uartBase == definition.uartUrxh { return uartRxQueue.isEmpty ? 0 : UInt64(uartRxQueue.removeFirst()) }
            return 0
        }
        noteMmio(addr)
        return 0
    }

    func mmioWrite(_ addr: UInt64, _ val: UInt64) {
        if addr >= definition.uartBase && addr < definition.uartBase &+ definition.uartSize {
            if addr - definition.uartBase == definition.uartUtxh { onUart(UInt8(val & 0xFF)) }
            return
        }
        noteMmio(addr)
    }

    public func readPhys(_ addr: UInt64, _ size: Int) -> UInt64 {
        if !isRam(addr) { return mmioRead(addr) }
        let off = Int(addr & 0xFFF)
        if off + size <= PAGE_SIZE {
            guard let p = pageFor(addr, false) else { return 0 }
            var val: UInt64 = 0
            var i = size - 1
            while i >= 0 { val = (val << 8) | UInt64(p.bytes[off + i]); i -= 1 }
            return val
        }
        var val: UInt64 = 0
        var i = size - 1
        while i >= 0 {
            let a = addr &+ UInt64(i)
            let p = pageFor(a, false)
            val = (val << 8) | UInt64(p != nil ? p!.bytes[Int(a & 0xFFF)] : 0)
            i -= 1
        }
        return val
    }

    public func writePhys(_ addr: UInt64, _ val: UInt64, _ size: Int) {
        if !isRam(addr) { mmioWrite(addr, val); return }
        let off = Int(addr & 0xFFF)
        if off + size <= PAGE_SIZE {
            guard let p = pageFor(addr, true) else { return }
            var i = 0
            while i < size { p.bytes[off + i] = UInt8((val >> (8 * i)) & 0xFF); i += 1 }
            return
        }
        var i = 0
        while i < size {
            let a = addr &+ UInt64(i)
            if let p = pageFor(a, true) { p.bytes[Int(a & 0xFFF)] = UInt8((val >> (8 * i)) & 0xFF) }
            i += 1
        }
    }

    public func loadBytes(_ addr: UInt64, _ bytes: [UInt8]) {
        if isRam(addr) && isRam(addr &+ UInt64(bytes.count - 1)) {
            var off = 0
            while off < bytes.count {
                let a = addr &+ UInt64(off)
                guard let p = pageFor(a, true) else { break }
                let po = Int(a & 0xFFF)
                let n = min(PAGE_SIZE - po, bytes.count - off)
                p.bytes.replaceSubrange(po..<(po + n), with: bytes[off..<(off + n)])
                off += n
            }
            return
        }
        for i in 0..<bytes.count { try? writeMem(addr &+ UInt64(i), 1, UInt64(bytes[i])) }
    }

    // MARK: - MMU: page-table walk driven by the kernel's TTBR/TCR

    func flushTlb() {
        tlb.removeAll()
        tlbVa = -1
        fetchPaBase = -1
        fetchPage = nil
    }

    func vbarArmed() -> Bool { (sysregs[sysKey(3, 0, 12, 0, 0)] ?? 0) != 0 }

    func walkFault(_ va: UInt64, _ level: Int) throws -> UInt64? {
        lastWalkLevel = level
        if quietWalk { return nil }
        if inStep && vbarArmed() {
            throw Fault(va: va, level: lastWalkLevel, write: accessWrite, fetch: accessFetch)
        }
        if status == "ready" {
            status = "trap"
            trapInfo = "translation fault at VA \(hexStr(va)) (fetch/data from PC \(hexStr(pc)))"
        }
        return nil
    }

    func walkTables(_ va: UInt64) throws -> UInt64? {
        let tcr = sysregs[sysKey(3, 0, 2, 0, 2)] ?? 0                    // TCR_EL1
        let t0sz = Int(tcr & 0x3F), t1sz = Int((tcr >> 16) & 0x3F)
        let tg0 = Int((tcr >> 14) & 3), tg1 = Int((tcr >> 30) & 3)
        let g0 = tg0 == 1 ? 16 : (tg0 == 2 ? 14 : 12)                     // TG0: 00=4K 01=64K 10=16K (page-offset bits)
        let g1 = tg1 == 2 ? 12 : (tg1 == 3 ? 16 : 14)                     // TG1: 01=16K 10=4K 11=64K
        let vaBits1 = 64 - t1sz
        let isT1 = t1sz > 0 && (va >> vaBits1) == (UInt64(1) << t1sz) - 1
        let g: Int
        var ttbr: UInt64
        if isT1 {
            if (tcr >> 23) & 1 == 1 { return try walkFault(va, 0) }       // EPD1
            g = g1
            ttbr = sysregs[sysKey(3, 0, 2, 0, 1)] ?? 0                    // TTBR1_EL1
        } else {
            if va >= (UInt64(1) << (64 - t0sz)) { return try walkFault(va, 0) }
            if (tcr >> 7) & 1 == 1 { return try walkFault(va, 0) }        // EPD0
            g = g0
            ttbr = sysregs[sysKey(3, 0, 2, 0, 0)] ?? 0                    // TTBR0_EL1
        }
        let vaBits = isT1 ? vaBits1 : 64 - t0sz
        let stride = g - 3                                                // index bits per level
        let levels = max(1, Int(ceil(Double(vaBits - g) / Double(stride))))
        var table = ttbr & ((UInt64(1) << 48) - 1) & ~((UInt64(1) << g) - 1)
        var level = 4 - levels
        while level <= 3 {
            let shift = g + stride * (3 - level)
            let idxBits = min(stride, vaBits - shift)
            if idxBits <= 0 { return try walkFault(va, level) }
            let idx = (va >> shift) & ((UInt64(1) << idxBits) - 1)
            let desc = readPhys(table &+ idx * 8, 8)
            let type = desc & 3
            if type == 0 { return try walkFault(va, level) }              // invalid descriptor
            if level == 3 {
                if type != 3 { return try walkFault(va, 3) }
                return (desc & ((UInt64(1) << 48) - (UInt64(1) << g))) | (va & ((UInt64(1) << g) - 1))
            }
            if type == 1 {                                                // block descriptor
                return (desc & ((UInt64(1) << 48) - 1) & ~((UInt64(1) << shift) - 1)) | (va & ((UInt64(1) << shift) - 1))
            }
            if type == 3 {                                                // table descriptor
                table = desc & ((UInt64(1) << 48) - 1) & ~((UInt64(1) << g) - 1)
                level += 1
                continue
            }
            return try walkFault(va, level)                               // reserved encoding
        }
        return try walkFault(va, 3)
    }

    func translate(_ va: UInt64) throws -> UInt64? {
        let key = va >> 12
        if Int64(bitPattern: key) == tlbVa { return tlbPa | (va & 0xFFF) }
        if let hit = tlb[key] {
            tlbVa = Int64(bitPattern: key)
            tlbPa = hit
            return hit | (va & 0xFFF)
        }
        guard let pa = try walkTables(va) else { return nil }
        let base = pa & ~0xFFF
        tlb[key] = base
        tlbVa = Int64(bitPattern: key)
        tlbPa = base
        return pa
    }

    // MARK: - Virtual memory access

    public func readMem(_ addr: UInt64, _ size: Int) throws -> UInt64 {
        if mmuOn {
            accessWrite = false
            guard let pa = try translate(addr) else { return 0 }
            return readPhys(pa, size)
        }
        return readPhys(addr, size)
    }

    public func writeMem(_ addr: UInt64, _ size: Int, _ val: UInt64) throws {
        if mmuOn {
            accessWrite = true
            guard let pa = try translate(addr) else { return }
            writePhys(pa, val, size)
            return
        }
        writePhys(addr, val, size)
    }

    /// Vector load: little-endian, `bytes` wide (zero-extended above).
    func readV(_ addr: UInt64, _ bytes: Int) throws -> V128 {
        if bytes == 16 {
            let lo = try readMem(addr, 8)
            let hi = try readMem(addr &+ 8, 8)
            return V128(lo: lo, hi: hi)
        }
        let val = try readMem(addr, bytes)
        return V128(lo: val, hi: 0)
    }

    /// Vector store: writes the low `bytes` of val.
    func writeV(_ addr: UInt64, _ val: V128, _ bytes: Int) throws {
        if bytes == 16 {
            try writeMem(addr, 8, val.lo)
            try writeMem(addr &+ 8, 8, val.hi)
            return
        }
        try writeMem(addr, bytes, val.lo)
    }

    func fetchInsn() throws -> UInt32? {
        var pa: UInt64
        if mmuOn {
            accessFetch = true
            defer { accessFetch = false }
            guard let t = try translate(pc) else { return nil }   // walkFault already set status
            pa = t
        } else { pa = pc }
        if !isRam(pa) || (pa & 0xFFF) > 4092 {
            return UInt32(truncatingIfNeeded: (try? readMem(pc, 4)) ?? 0)
        }
        let base = pa & ~0xFFF
        if Int64(bitPattern: base) != fetchPaBase {
            fetchPage = pageFor(pa, false)
            fetchPaBase = Int64(bitPattern: base)
        }
        guard let fp = fetchPage else { return 0 }                // untouched RAM page reads as zero
        let o = Int(pa & 0xFFF)
        return UInt32(fp.bytes[o]) | UInt32(fp.bytes[o + 1]) << 8 | UInt32(fp.bytes[o + 2]) << 16 | UInt32(fp.bytes[o + 3]) << 24
    }

    // MARK: - Registers

    func getReg(_ i: Int, _ isSP: Bool = false) -> UInt64 {
        i == 31 ? (isSP ? sp : 0) : x[i]
    }
    func setReg(_ i: Int, _ val: UInt64, _ isSP: Bool = false) {
        let val = val & M64
        if i == 31 { if isSP { sp = val }; return }
        x[i] = val
    }

    // MARK: - Exceptions

    func deliverException(_ rec: Fault) -> Bool {
        let vbar = sysregs[sysKey(3, 0, 12, 0, 0)] ?? 0
        if vbar == 0 { return false }
        var ec: UInt64 = 0
        var iss: UInt64 = 0
        if rec.undef { ec = 0x00; iss = 0 }                        // unknown reason
        else {
            ec = rec.fetch ? 0x21 : 0x25                          // instruction / data abort, current EL
            iss = UInt64(0x04 + rec.level) | (rec.write && !rec.fetch ? (1 << 24) : 0)
        }
        sysregs[sysKey(3, 0, 5, 2, 0)] = (ec << 26) | (1 << 25) | iss       // ESR_EL1 (IL=1)
        sysregs[sysKey(3, 0, 6, 0, 0)] = rec.undef ? 0 : rec.va             // FAR_EL1
        sysregs[sysKey(3, 0, 4, 0, 1)] = rec.elr                            // ELR_EL1
        let nzcv = (UInt64(nFlag) << 31) | (UInt64(zFlag) << 30) | (UInt64(cFlag) << 29) | (UInt64(vFlag) << 28)
        let panBit = ((sysregs[sysKey(3, 0, 4, 2, 3)] ?? 0) & 1) << 22   // SPSR_EL1.PAN = current PAN (stage-5 frontier 18)
        sysregs[sysKey(3, 0, 4, 0, 0)] = nzcv | panBit | (0b1111 << 6) | 0b0101      // SPSR_EL1: NZCV+PAN saved, DAIF masked, EL1h
        pc = vbar &+ 0x200   // sync exception from EL1 using SP_EL1
        exceptions += 1
        lastException = (rec.undef ? "undefined instruction"
            : (rec.fetch ? "instruction abort" : "data abort") + " at VA \(hexStr(rec.va))")
            + ", ELR \(hexStr(rec.elr)) -> vector \(hexStr(pc))"
        return true
    }

    // MARK: - Run control

    @discardableResult
    public func run(_ maxInstructions: Int) -> String {
        var n = 0
        if status == "breakpoint" {
            status = "ready"
            if !step() { return status }
            n += 1
        }
        while n < maxInstructions {
            if status == "halted" || status == "trap" || status == "undefined" || status == "wfi" { break }
            if !breakpoints.isEmpty && breakpoints.contains(String(pc, radix: 16)) {
                status = "breakpoint"
                trapInfo = "breakpoint at PC \(hexStr(pc))"
                break
            }
            if !step() { break }
            n += 1
        }
        return status
    }

    public func step() -> Bool {
        curInsnPc = pc
        inStep = true
        defer { inStep = false }
        do {
            return try stepBody()
        } catch let f as Fault {
            var rec = f
            rec.elr = curInsnPc
            if deliverException(rec) {
                status = "ready"
                return true
            }
            status = "trap"
            trapInfo = rec.undef
                ? "undefined instruction, and VBAR_EL1 is not set yet — nowhere to deliver it"
                : "translation fault at VA \(hexStr(rec.va)), and VBAR_EL1 is not set yet — nowhere to deliver it"
            return false
        } catch {
            return false
        }
    }

    public func resume() { if status == "breakpoint" || status == "wfi" { status = "ready" } }
    public func addBreakpoint(_ addr: UInt64) {
        let k = String(addr & M64, radix: 16)
        if breakpoints.insert(k).inserted { breakpointList.append(k) }
    }
    public func clearBreakpoints() { breakpoints.removeAll(); breakpointList.removeAll() }
    /// Read a system register by its encoding fields (0 if never written).
    public func sysregValue(_ op0: Int, _ op1: Int, _ crn: Int, _ crm: Int, _ op2: Int) -> UInt64 {
        sysregs[sysKey(op0, op1, crn, crm, op2)] ?? 0
    }
    public func queueUartRx(_ text: String) {
        for u in text.utf16 { uartRxQueue.append(UInt8(u & 0xFF)) }
    }

    // MARK: - Backdoor primitives

    public func peekBytes(_ addr: UInt64, _ len: Int) -> [UInt8] {
        var out = [UInt8]()
        for i in 0..<len { out.append(UInt8(((try? readMem(addr &+ UInt64(i), 1)) ?? 0) & 0xFF)) }
        return out
    }

    /// Backdoor reads that never disturb the CPU state.
    public func peekQuiet(_ addr: UInt64, _ len: Int) -> [UInt8] {
        let savedStatus = status, savedTrap = trapInfo
        defer { status = savedStatus; trapInfo = savedTrap }
        return peekBytes(addr, len)
    }

    public func pokeQuiet(_ addr: UInt64, _ bytes: [UInt8]) {
        let savedStatus = status, savedTrap = trapInfo
        defer { status = savedStatus; trapInfo = savedTrap }
        for i in 0..<bytes.count { try? writeMem(addr &+ UInt64(i), 1, UInt64(bytes[i])) }
    }

    public func lastPcs(_ n: Int) -> [UInt64] {
        var out = [UInt64]()
        for i in 0..<min(n, 64) { out.append(pcRing[(pcRingIdx - 1 - i + 128) & 63]) }
        return out.reversed()
    }
}

// CPU.swift — FakeDeviceCore
//
// stepBody(): the ARM64 interpreter proper. A faithful transcription of
// emu.js's stepBody — same block order, same masks, same quirks — so
// decode priority and behaviour match the reference on every encoding.
// AdvSIMD/FP blocks live in SIMD.swift (simdStep), at the same position
// in the decode order as the reference.

import Foundation

extension Machine {

    func trap(_ kind: String, _ info: String?) -> Bool {
        status = "trap"
        trapInfo = kind + " at PC \(hexStr(pc))" + (info != nil ? " (\(info!))" : "")
        return false
    }

    func undef(_ insn: UInt32) throws -> Bool {
        if inStep && vbarArmed() {
            throw Fault(va: 0, level: 3, write: false, fetch: false, undef: true, insn: insn)
        }
        status = "undefined"
        let word = String(insn, radix: 16)
        trapInfo = "undefined instruction 0x" + String(repeating: "0", count: max(0, 8 - word.count)) + word + " at PC \(hexStr(pc))"
        return false
    }

    func shiftReg(_ valIn: UInt64, _ type: Int, _ amtIn: Int, _ bits: Int) -> UInt64 {
        let mask: UInt64 = bits == 64 ? M64 : 0xFFFFFFFF
        let val = valIn & mask
        let amt = amtIn & (bits - 1)
        if type == 0 { return (val << amt) & mask }                                   // LSL
        if type == 1 { return val >> amt }                                            // LSR
        if type == 2 { return UInt64(bitPattern: Int64(bitPattern: sext64(val, bits)) >> amt) & mask }  // ASR
        if amt == 0 { return val }                                                    // ROR
        return ((val >> amt) | (val << (bits - amt))) & mask
    }

    func flagsAdd(_ a: UInt64, _ b: UInt64, _ r: UInt64, _ bits: Int) {
        let mask: UInt64 = bits == 64 ? M64 : 0xFFFFFFFF
        let sign: UInt64 = bits == 64 ? 0x8000000000000000 : 0x80000000
        nFlag = (r & sign) != 0 ? 1 : 0
        zFlag = (r & mask) == 0 ? 1 : 0
        if bits == 64 { cFlag = a.addingReportingOverflow(b).overflow ? 1 : 0 }
        else { cFlag = Int(((a & mask) + (b & mask)) >> 32 & 1) }
        vFlag = ((~(a ^ b) & (a ^ r)) & sign) != 0 ? 1 : 0
    }

    func flagsSub(_ a: UInt64, _ b: UInt64, _ r: UInt64, _ bits: Int) {
        let mask: UInt64 = bits == 64 ? M64 : 0xFFFFFFFF
        let sign: UInt64 = bits == 64 ? 0x8000000000000000 : 0x80000000
        nFlag = (r & sign) != 0 ? 1 : 0
        zFlag = (r & mask) == 0 ? 1 : 0
        cFlag = (a & mask) >= (b & mask) ? 1 : 0
        vFlag = (((a ^ b) & (a ^ r)) & sign) != 0 ? 1 : 0
    }

    func flagsLogic(_ r: UInt64, _ bits: Int) {
        let sign: UInt64 = bits == 64 ? 0x8000000000000000 : 0x80000000
        nFlag = (r & sign) != 0 ? 1 : 0
        zFlag = r == 0 ? 1 : 0
        cFlag = 0
        vFlag = 0
    }

    func condHolds(_ cond: Int) -> Bool {
        var r: Bool
        switch cond >> 1 {
        case 0: r = zFlag == 1
        case 1: r = cFlag == 1
        case 2: r = nFlag == 1
        case 3: r = vFlag == 1
        case 4: r = cFlag == 1 && zFlag == 0
        case 5: r = nFlag == vFlag
        case 6: r = nFlag == vFlag && zFlag == 0
        default: r = true
        }
        return (cond & 1) == 1 && cond != 15 ? !r : r
    }

    func decodeBitmask(_ nBit: Int, _ immr: Int, _ imms: Int, _ bits: Int) -> UInt64? {
        var len = 0
        if nBit == 1 { len = 6 } else {
            var i = 5
            while i >= 1 { if (imms >> i) & 1 == 0 { len = i; break }; i -= 1 }
            if len == 0 { return nil }
        }
        let esize = 1 << len
        if esize > bits { return nil }
        let levels = esize - 1
        let s = imms & levels, r = immr & levels
        if s == levels { return nil }
        var welem = (UInt64(1) << (s + 1)) - 1
        if r != 0 {
            let em: UInt64 = esize == 64 ? M64 : (UInt64(1) << esize) - 1
            welem = ((welem >> r) | (welem << (esize - r))) & em
        }
        var out: UInt64 = 0
        var i = 0
        while i < bits { out |= welem << i; i += esize }
        return out & (bits == 64 ? M64 : 0xFFFFFFFF)
    }

    func mrs(_ op0: Int, _ op1: Int, _ crn: Int, _ crm: Int, _ op2: Int) -> UInt64 {
        switch sysKey(op0, op1, crn, crm, op2) {
        case "3,0,0,0,0": return 0x611F01A0                          // MIDR_EL1 (stub value)
        case "3,0,0,0,5": return 0                                   // MPIDR_EL1: boot core 0
        case "3,0,4,2,2": return 4                                   // CurrentEL = EL1
        case "3,3,0,0,1": return 0x8444C004                          // CTR_EL0 (plausible)
        case "3,0,0,4,0": return 0x111111                            // ID_AA64PFR0_EL1 (plausible)
        case "3,3,13,0,2": return UInt64(icount) &* 41               // CNTPCT_EL0
        case "3,3,14,0,2": return UInt64(icount) &* 41               // CNTVCT_EL0: the kernel's timebase (frontier 20; was unmodelled -> read 0 forever)
        case "3,3,14,3,0":                                           // CNTV_TVAL_EL0: signed ticks remaining
            if let d = cntvDeadline { return (d &- (UInt64(icount) &* 41)) & 0xFFFFFFFF }
            return sysregs[sysKey(3, 3, 14, 3, 0)] ?? 0
        case "3,3,14,3,2": return cntvDeadline ?? 0                  // CNTV_CVAL_EL0
        case "3,3,14,3,1":                                           // CNTV_CTL_EL0: ISTATUS (bit 2) is computed, not stored
            let stored = sysregs[sysKey(3, 3, 14, 3, 1)] ?? 0
            var fired = false
            if (stored & 1) != 0, let d = cntvDeadline,
               Int64(bitPattern: UInt64(icount) &* 41) >= Int64(bitPattern: d) { fired = true }
            return (stored & 3) | (fired ? 4 : 0)
        case "3,3,0,0,7": return 4                                   // DCZID_EL0: 64-byte ZVA blocks, allowed
        case "3,3,14,0,0": return 24_000_000                         // CNTFRQ_EL0: 24 MHz
        case "3,4,15,0,4":                                           // Apple core register: bit 1 "ready", writes stick
            return (sysregs[sysKey(3, 4, 15, 0, 4)] ?? 0) | 2
        default: return sysregs[sysKey(op0, op1, crn, crm, op2)] ?? 0
        }
    }

    func msr(_ op0: Int, _ op1: Int, _ crn: Int, _ crm: Int, _ op2: Int, _ val: UInt64) {
        let k = sysKey(op0, op1, crn, crm, op2)
        sysregs[k] = val & M64
        if k == "3,3,14,3,0" {                                       // CNTV_TVAL_EL0: deadline = now + sext32(val) (frontier 20)
            let d = Int64(Int32(truncatingIfNeeded: val))
            cntvDeadline = (UInt64(icount) &* 41) &+ UInt64(bitPattern: d)
        }
        if k == "3,3,14,3,2" { cntvDeadline = val & M64 }            // CNTV_CVAL_EL0: absolute deadline
        if k == "3,0,2,0,0" || k == "3,0,2,0,1" || k == "3,0,2,0,2" { flushTlb() }   // TTBR0/TTBR1/TCR changed
        if k == "3,0,1,0,0" {                                                        // SCTLR_EL1
            let on = val & 1 != 0
            if on && !mmuOn { onLog("kernel set SCTLR_EL1.M — MMU on; addresses now translate through the kernel's own page tables") }
            if on != mmuOn { mmuOn = on; flushTlb() }
        }
    }

    // MARK: - stepBody

    func stepBody() throws -> Bool {
        pcRing[pcRingIdx] = pc
        pcRingIdx = (pcRingIdx + 1) & 63
        guard let insn = try fetchInsn() else { return false }        // fetch faulted (translation)
        if status == "trap" { return false }
        icount += 1
        let nextPc = pc &+ 4
        let rd = Int(insn & 31), rn = Int((insn >> 5) & 31), rm = Int((insn >> 16) & 31)
        let sf = Int(insn >> 31)
        let bits = sf == 1 ? 64 : 32
        let wmask: UInt64 = sf == 1 ? M64 : 0xFFFFFFFF

        // --- exceptions, hints, barriers, sysregs ---
        if insn & 0xFFE0001F == 0xD4400000 { status = "halted"; trapInfo = "HLT at PC \(hexStr(pc))"; return false }
        if insn & 0xFFE0001F == 0xD4200000 { status = "halted"; trapInfo = "BRK #\((insn >> 5) & 0xFFFF) at PC \(hexStr(pc))"; return false }
        if insn & 0xFFE0001F == 0xD4000001 { return trap("SVC", "#\((insn >> 5) & 0xFFFF)") }
        if insn == 0xD69F03E0 || insn == 0xD69F0BFF || insn == 0xD69F0FFF {   // ERET / ERETAA / ERETAB
            let spsr = sysregs[sysKey(3, 0, 4, 0, 0)] ?? 0                    // SPSR_EL1
            nFlag = Int((spsr >> 31) & 1); zFlag = Int((spsr >> 30) & 1)
            cFlag = Int((spsr >> 29) & 1); vFlag = Int((spsr >> 28) & 1)
            sysregs[sysKey(3, 0, 4, 2, 3)] = (spsr >> 22) & 1                 // PAN restored from SPSR_EL1.PAN (frontier 18)
            pc = sysregs[sysKey(3, 0, 4, 0, 1)] ?? 0                          // ELR_EL1
            return true
        }
        if insn & 0xFFFFF000 == 0xD5032000 {                                  // HINT space
            if (insn >> 5) & 0x7F == 3 {
                status = "wfi"
                trapInfo = "WFI at PC \(hexStr(pc)) — CPU idle, waiting for an interrupt"
                return false
            }
            pc = nextPc
            return true
        }
        if insn & 0xFFF0F000 == 0xD5033000 { pc = nextPc; return true }       // barriers
        if insn & 0xFFC00000 == 0xD5000000 {                                  // MSR/MRS + SYS (TLBI/DC/IC/AT)
            let l = (insn >> 21) & 1
            let op0 = Int((insn >> 19) & 3), op1 = Int((insn >> 16) & 7)
            let crn = Int((insn >> 12) & 15), crm = Int((insn >> 8) & 15), op2 = Int((insn >> 5) & 7)
            if l == 0 && crn == 7 {
                // SYS cache maintenance: Rt (rd field) holds the address for DC ops
                if crm == 4 && op2 == 1 {                                     // DC ZVA: zero a block
                    let a = getReg(rd) & ~UInt64(zvaSize - 1)
                    var i = 0
                    while i < zvaSize { try writeMem(a &+ UInt64(i), 8, 0); i += 8 }
                } else if crm == 8 || crm == 9 || ((crm == 10 || crm == 11) && op2 <= 1) {
                    // AT S1E1R/W, S1E0R/W, S12*, S1E2*: result (or failure) in PAR_EL1; never faults
                    let va = getReg(rd)
                    quietWalk = true
                    let pa = try walkTables(va)
                    quietWalk = false
                    if pa == nil { sysregs[sysKey(3, 0, 7, 4, 0)] = 1 | (UInt64(0x04 + lastWalkLevel) << 1) }
                    else { sysregs[sysKey(3, 0, 7, 4, 0)] = pa! & ~0xFFF }
                }
                // DC CIVAC/CVAC/CVAU/IVAC, IC IALLU*: no-ops in this model
                pc = nextPc
                return true
            }
            if l == 0 && crn == 8 { flushTlb(); pc = nextPc; return true }   // TLBI *
            if l == 0 && op0 == 0 && crn == 4 && op1 == 0 && op2 == 4 {
                // MSR PAN, #imm (PSTATE-field immediate; stage-5 frontier 18).
                // The generic path would file this under a nonsense key and
                // the kernel's rsr("pan") would read 0 forever. The immediate
                // lives in the CRm field; PAN is sysreg 3,0,4,2,3.
                sysregs[sysKey(3, 0, 4, 2, 3)] = UInt64(crm & 1)
                pc = nextPc
                return true
            }
            if l == 1 { setReg(rd, mrs(op0, op1, crn, crm, op2)) }
            else { msr(op0, op1, crn, crm, op2, getReg(rd)) }
            pc = nextPc
            return true
        }

        // --- AdvSIMD / FP ---
        if try simdStep(insn, rd: rd, rn: rn, rm: rm, nextPc: nextPc) { return true }
        if status != "ready" { return false }

        // --- ADR / ADRP ---
        if insn & 0x1F000000 == 0x10000000 {
            var imm = Int64(((insn >> 3) & 0x1FFFFC) | ((insn >> 29) & 3))
            if imm & 0x100000 != 0 { imm |= ~0x1FFFFF }
            if sf == 1 { setReg(rd, (pc & ~0xFFF) &+ UInt64(bitPattern: imm << 12)) }
            else { setReg(rd, pc &+ UInt64(bitPattern: imm)) }
            pc = nextPc
            return true
        }

        // --- data-processing immediate ---
        let dpi = Int((insn >> 25) & 0xF)
        if dpi == 8 || dpi == 9 {
            let op6 = Int((insn >> 23) & 0x3F)
            if op6 == 0x22 || op6 == 0x23 {                                   // ADD/SUB imm
                let isSub = (insn >> 30) & 1, setF = (insn >> 29) & 1
                var imm = UInt64((insn >> 10) & 0xFFF)
                if (insn >> 22) & 1 == 1 { imm <<= 12 }
                let a = getReg(rn, true) & wmask
                let r = isSub == 1 ? (a &- imm) & M64 : (a &+ imm) & M64
                if setF == 1 { if isSub == 1 { flagsSub(a, imm, r, bits) } else { flagsAdd(a, imm, r, bits) } }
                if !(setF == 1 && rd == 31) { setReg(rd, r & wmask, setF == 0) }
                pc = nextPc
                return true
            }
            if op6 == 0x24 {                                                  // logical imm
                let opc = Int((insn >> 29) & 3)
                guard let imm = decodeBitmask(Int((insn >> 22) & 1), Int((insn >> 16) & 0x3F), Int((insn >> 10) & 0x3F), bits) else {
                    return try undef(insn)
                }
                let a = getReg(rn) & wmask
                var r = opc == 1 ? (a | imm) : (opc == 2 ? (a ^ imm) : (a & imm))
                r &= wmask
                if opc == 3 { flagsLogic(r, bits) }
                if !(opc == 3 && rd == 31) { setReg(rd, r) }
                pc = nextPc
                return true
            }
            if op6 == 0x25 {                                                  // move wide
                let opc = Int((insn >> 29) & 3), hw = Int((insn >> 21) & 3) * 16
                let imm16 = UInt64((insn >> 5) & 0xFFFF)
                var r: UInt64
                if opc == 2 { r = imm16 << hw }
                else if opc == 0 { r = ~(imm16 << hw) & M64 }
                else if opc == 3 { r = (getReg(rd) & ~(0xFFFF << hw)) | (imm16 << hw) }
                else { return try undef(insn) }
                setReg(rd, r & wmask)
                pc = nextPc
                return true
            }
            if op6 == 0x26 {                                                  // bitfield
                let opc = Int((insn >> 29) & 3)
                if Int((insn >> 22) & 1) != sf { return try undef(insn) }
                let immr = Int((insn >> 16) & 0x3F), imms = Int((insn >> 10) & 0x3F)
                let src = getReg(rn) & wmask
                var r: UInt64
                if imms >= immr {
                    let width = imms - immr + 1
                    let m: UInt64 = width >= 64 ? M64 : (UInt64(1) << width) - 1
                    let field = (src >> immr) & m
                    if opc == 1 { r = ((getReg(rd) & wmask) & ~m) | field }          // BFM
                    else if opc == 0 { r = sext64(field, width) & wmask }             // SBFM
                    else { r = field }                                                // UBFM
                } else {
                    let m = ((UInt64(1) << (imms + 1)) - 1) << (bits - immr)
                    let field = (src << (bits - immr)) & m
                    if opc == 1 { r = ((getReg(rd) & wmask) & ~m) | field }
                    else if opc == 0 {                                                  // SBFIZ: sign-extended insert
                        // (ASR-immediate has imms = datasize-1, so it always lands
                        // in the extract branch above; this branch is the insert
                        // form. Stage-5 frontier 10: executing it as ASR returned
                        // ~0 for the kernel's sbfiz and zeroed a zone chunk base.)
                        let fv = src & ((UInt64(1) << (imms + 1)) - 1)
                        r = (sext64(fv, imms + 1) << (bits - immr)) & wmask
                    }
                    else { r = field }                                                // LSL form
                }
                setReg(rd, r & wmask)
                pc = nextPc
                return true
            }
            if op6 == 0x27 {                                                  // EXTR
                let lsb = Int((insn >> 10) & 0x3F)
                let hi = getReg(rn) & wmask, lo = getReg(rm) & wmask
                var r: UInt64
                if lsb == 0 { r = lo }
                else { r = ((lo >> lsb) | (hi << (bits - lsb))) & wmask }
                setReg(rd, r & wmask)
                pc = nextPc
                return true
            }
        }

        // --- branches ---
        if insn & 0x7C000000 == 0x14000000 {                                  // B / BL
            var imm = Int64(insn & 0x3FFFFFF)
            if imm & 0x2000000 != 0 { imm |= ~0x3FFFFFF }
            if insn >> 31 == 1 { setReg(30, nextPc) }
            pc = pc &+ UInt64(bitPattern: imm << 2)
            return true
        }
        if insn & 0xFF000010 == 0x54000000 {                                  // B.cond
            var imm = Int64((insn >> 5) & 0x7FFFF)
            if imm & 0x40000 != 0 { imm |= ~0x7FFFF }
            pc = condHolds(Int(insn & 0xF)) ? pc &+ UInt64(bitPattern: imm << 2) : nextPc
            return true
        }
        if insn & 0x7E000000 == 0x34000000 {                                  // CBZ / CBNZ
            var imm = Int64((insn >> 5) & 0x7FFFF)
            if imm & 0x40000 != 0 { imm |= ~0x7FFFF }
            let isz = (getReg(rd) & wmask) == 0
            pc = (((insn >> 24) & 1) == 1 ? !isz : isz) ? pc &+ UInt64(bitPattern: imm << 2) : nextPc
            return true
        }
        if insn & 0x7E000000 == 0x36000000 {                                  // TBZ / TBNZ
            let bpos = Int((insn >> 31) & 1) << 5 | Int((insn >> 19) & 0x1F)
            var imm = Int64((insn >> 5) & 0x3FFF)
            if imm & 0x2000 != 0 { imm |= ~0x3FFF }
            let bit = (getReg(rd) >> bpos) & 1
            pc = (((insn >> 24) & 1) == 1 ? bit == 1 : bit == 0) ? pc &+ UInt64(bitPattern: imm << 2) : nextPc
            return true
        }
        if insn & 0xFFFFFC1F == 0xD61F0000 { pc = getReg(rn); return true }   // BR
        if insn & 0xFFFFFC1F == 0xD63F0000 { setReg(30, nextPc); pc = getReg(rn); return true }  // BLR
        if insn == 0xD65F0BFF || insn == 0xD65F0FFF { pc = getReg(30); return true }             // RETAA / RETAB (auth not modelled)
        // Pointer-authenticated branches: BRAA/BRAB, BLRAA/BLRAB (target in Rn,
        // modifier in Rd), BRAAZ/BRABZ, BLRAAZ/BLRABZ (Rd = 11111). Auth not modelled.
        let top = insn & 0xFFFF0000
        if (top == 0xD71F0000 || top == 0xD73F0000) && ((insn >> 11) & 1) == 1 {
            if top == 0xD73F0000 { setReg(30, nextPc) }
            pc = getReg(rn)
            return true
        }
        if (top == 0xD61F0000 || top == 0xD63F0000) && ((insn >> 10) & 3) == 2 && (insn & 31) == 31 {
            if top == 0xD63F0000 { setReg(30, nextPc) }
            pc = getReg(rn)
            return true
        }
        if insn & 0xFFFFFC1F == 0xD65F0000 { pc = getReg(rn); return true }   // RET

        // --- loads & stores: pairs ---
        if insn & 0x7A000000 == 0x28000000 {
            let opc = Int((insn >> 30) & 3)
            if opc == 1 || opc == 3 { return try undef(insn) }                // SIMD pairs handled in simdStep
            let size = opc == 2 ? 8 : 4
            let l = (insn >> 22) & 1, mode = Int((insn >> 23) & 7)
            let rt2 = Int((insn >> 10) & 31)
            var imm = Int64((insn >> 15) & 0x7F)
            if imm & 0x40 != 0 { imm |= ~0x7F }
            imm *= Int64(size)
            let base = getReg(rn, true)
            var addr = base
            if mode == 2 || mode == 0 { addr = base &+ UInt64(bitPattern: imm) }
            else if mode == 3 || mode == 1 { addr = base &+ UInt64(bitPattern: imm) }
            else if mode == 6 || mode == 7 { addr = base &+ UInt64(bitPattern: imm) }
            else { return try undef(insn) }
            let isPre = mode == 3 || mode == 7, isPost = mode == 1 || mode == 5
            let a0 = isPost ? base : addr
            if l == 1 {
                setReg(rd, try readMem(a0, size))
                setReg(rt2, try readMem(a0 &+ UInt64(size), size))
            } else {
                try writeMem(a0, size, getReg(rd))
                try writeMem(a0 &+ UInt64(size), size, getReg(rt2))
            }
            if isPre || isPost { setReg(rn, addr, true) }
            pc = nextPc
            return true
        }

        // --- loads & stores: single ---
        if insn & 0xFFE0FC00 == 0x9AC03000 {                                  // PACGA (stage-5 frontier 16)
            // Pointer Authentication generic code: architecturally QARMA over
            // (Rn = data, Rm = modifier) keyed by APGAKey_EL1. The exact QARMA
            // variant is IMP-DEF; every kernel use on the boot path is
            // compute-and-compare (chained struct hashes), so the machine
            // provides a deterministic, key-dependent function — a 6-round ARX
            // mix over data/modifier/both key halves, transcribed from the
            // reference (including its double-rounded round constant).
            let klo = sysregs[sysKey(3, 0, 2, 3, 1)] ?? 0, khi = sysregs[sysKey(3, 0, 2, 3, 2)] ?? 0
            var x = (getReg(rn) ^ klo) & M64
            let mod = getReg(rm)
            func rot(_ v: UInt64, _ s: Int) -> UInt64 { ((v << s) | (v >> (64 - s))) & M64 }
            for i in 0..<6 {
                let termD = Double(0x9E3779B97F4A7C15) * Double(i)
                let term = UInt64(termD.truncatingRemainder(dividingBy: 0x1p64))
                x = (x &+ (mod ^ khi ^ term)) & M64
                x = rot(x, 23)
                x = (x &* 0xBF58476D1CE4E5B9) & M64
                x ^= x >> 29
                x = rot(x, 41)
                x = (x &* 0x94D049BB133111EB) & M64
                x ^= x >> 32
            }
            setReg(rd, x & M64)
            pc = nextPc
            return true
        }
        if insn & 0x3F000000 == 0x19000000 && ((insn >> 21) & 1) == 0 {
            // STLUR / LDAPUR + sign-extending LDAPURSB/SH/SW (stage-5 frontier 9):
            // unscaled ordered load/store, imm9 offset, no writeback; ordering
            // semantics are no-ops in this single-CPU model. Bit 23 =
            // sign-extending load family, bit 22 = load (or W-destination in
            // the sign family).
            let size = Int((insn >> 30) & 3), bytes = 1 << size
            var imm = Int64((insn >> 12) & 0x1FF)
            if imm & 0x100 != 0 { imm |= ~0x1FF }
            let addr = (getReg(rn, true) &+ UInt64(bitPattern: imm)) & M64
            let b23 = (insn >> 23) & 1, b22 = (insn >> 22) & 1
            if b23 == 0 && b22 == 0 { try writeMem(addr, bytes, getReg(rd)) }         // STLUR
            else if b23 == 0 { setReg(rd, try readMem(addr, bytes)) }                 // LDAPUR (zero-extended)
            else {                                                                    // LDAPURSB/SH/SW
                if size == 3 { return try undef(insn) }
                var val = sext64(try readMem(addr, bytes), bytes * 8)
                if b22 == 1 { val &= 0xFFFFFFFF }
                setReg(rd, val)
            }
            pc = nextPc
            return true
        }
        if insn & 0x3F000000 == 0x18000000 {                                  // LDR literal (V=0)
            let opc = Int((insn >> 30) & 3)
            if opc == 3 { pc = nextPc; return true }                          // PRFM literal: no-op
            var imm = Int64((insn >> 5) & 0x7FFFF)
            if imm & 0x40000 != 0 { imm |= ~0x7FFFF }
            let addr = pc &+ UInt64(bitPattern: imm << 2)
            if opc == 0 { setReg(rd, try readMem(addr, 4)) }
            else if opc == 1 { setReg(rd, try readMem(addr, 8)) }
            else { setReg(rd, sext64(try readMem(addr, 4), 32)) }             // LDRSW
            pc = nextPc
            return true
        }
        if insn & 0x3F200C00 == 0x38200000 {                                  // LSE atomics: LDADD/LDCLR/LDEOR/LDSET/LDSMAX/LDSMIN/LDUMAX/LDUMIN/SWP
            // bits 29:24 = 111010 with bit 21 = 1 AND bits 11:10 = 00
            // (stage-5 frontiers 6+8). These words also match the load/store
            // mask below, which used to claim them and execute e.g. LDADD as a
            // random unscaled load/store. The bits 11:10 = 00 term is
            // load-bearing: without it this block also claims LDR/STR
            // register-offset words (bits 11:10 = 10) — it executed the
            // chained-fixup veneer's ldrsw as an LDUMIN that zeroed the
            // jump-table entry it was reading. A/L ordering variants are
            // no-ops in this single-CPU model.
            let size = Int((insn >> 30) & 3), bytes = 1 << size
            let addr = getReg(rn, true)
            let rs = Int((insn >> 16) & 31), o3 = Int((insn >> 15) & 1), opc = Int((insn >> 12) & 7)
            let m: UInt64 = bytes == 8 ? M64 : (UInt64(1) << (bytes * 8)) - 1
            let old = try readMem(addr, bytes) & m, opnd = getReg(rs) & m
            func sgn(_ v: UInt64) -> Int64 { Int64(bitPattern: sext64(v, bytes * 8)) }
            if o3 == 1 && opc == 4 && rs == 31 {                              // LDAPR (stage-5 frontier 11)
                // Load-Acquire RCpc (register form) shares this space: bits
                // 15:12 = 1100 with Rs = 11111 (any other Rs is unallocated).
                // Plain load in this single-CPU model.
                setReg(rd, old)
                pc = nextPc
                return true
            }
            var nv: UInt64
            if o3 == 1 { if opc != 0 { return try undef(insn) }; nv = opnd }  // SWP
            else if opc == 0 { nv = (old &+ opnd) & m }                       // LDADD
            else if opc == 1 { nv = old & ~opnd & m }                         // LDCLR
            else if opc == 2 { nv = old ^ opnd }                              // LDEOR
            else if opc == 3 { nv = old | opnd }                              // LDSET
            else if opc == 4 { nv = sgn(old) >= sgn(opnd) ? old : opnd }      // LDSMAX
            else if opc == 5 { nv = sgn(old) <= sgn(opnd) ? old : opnd }      // LDSMIN
            else if opc == 6 { nv = old >= opnd ? old : opnd }                // LDUMAX
            else { nv = old <= opnd ? old : opnd }                            // LDUMIN
            try writeMem(addr, bytes, nv)
            setReg(rd, old)
            pc = nextPc
            return true
        }
        if insn & 0x3B000000 == 0x39000000 || insn & 0x3B000000 == 0x38000000 {
            let size = Int((insn >> 30) & 3), opc = Int((insn >> 22) & 3)
            let bytes = 1 << size
            if size == 3 && opc == 3 && (insn & 0x3B000000) == 0x39000000 { pc = nextPc; return true }  // PRFM
            let base = getReg(rn, true)
            var addr: UInt64 = 0
            var writeback: UInt64? = nil
            if insn & 0x3B000000 == 0x39000000 {                              // unsigned offset
                addr = base &+ UInt64((insn >> 10) & 0xFFF) * UInt64(bytes)
            } else if ((insn >> 21) & 1) == 1 && ((insn >> 10) & 3) == 2 {    // register offset
                let opt = Int((insn >> 13) & 7)
                let sh = ((insn >> 12) & 1) == 1 ? size : 0
                var ext = getReg(rm)
                if opt == 2 { ext &= 0xFFFFFFFF }
                else if opt == 6 { ext = sext64(ext & 0xFFFFFFFF, 32) }
                else if opt != 3 && opt != 7 { return try undef(insn) }
                addr = (base &+ ((ext << sh) & M64)) & M64
            } else {
                var imm = Int64((insn >> 12) & 0x1FF)
                if imm & 0x100 != 0 { imm |= ~0x1FF }
                let mode = Int((insn >> 10) & 3)
                if mode == 0 { addr = base &+ UInt64(bitPattern: imm) }                       // unscaled
                else if mode == 3 { addr = base &+ UInt64(bitPattern: imm); writeback = addr } // pre-index
                else if mode == 1 { addr = base; writeback = base &+ UInt64(bitPattern: imm) } // post-index
                else { return try undef(insn) }
            }
            if opc == 0 {
                try writeMem(addr, bytes, getReg(rd))
            } else {
                let raw = try readMem(addr, bytes)
                var val: UInt64
                if opc == 1 { val = raw }
                else if opc == 2 { val = sext64(raw, bytes * 8) & (sf == 1 ? M64 : 0xFFFFFFFF) }
                else { val = sext64(raw, bytes * 8) }
                setReg(rd, (sf == 1 || opc == 3) ? val : val & 0xFFFFFFFF)
            }
            if let wb = writeback { setReg(rn, wb, true) }
            pc = nextPc
            return true
        }
        if insn & 0x3F000000 == 0x08000000 {                                  // exclusives + CAS (stage-5 frontier 6)
            // This space was originally a "simple model" that treated every
            // word as a plain load or store — including CAS, which it
            // executed as a load that never stored. A CAS-based lock acquire
            // then "succeeded" without ever writing the lock word, and the
            // matching unlock panicked. Single-CPU model: exclusives always
            // succeed, CAS is exact.
            let size = Int((insn >> 30) & 3), bytes = 1 << size
            let addr = getReg(rn, true)
            let rs = Int((insn >> 16) & 31), rt2 = Int((insn >> 10) & 31)
            let m: UInt64 = bytes == 8 ? M64 : (UInt64(1) << (bytes * 8)) - 1
            let kind = Int((insn >> 21) & 3), bit23 = (insn >> 23) & 1, o3 = Int((insn >> 15) & 1)
            // This space also holds LDAR/STLR. True layout (capstone-
            // calibrated): with bit 23 set, kind 1 = CAS, kind 3 = CASA
            // (bit 15 = release for both), kind 0 + bit 15 + Rs/Rt2 = 11111
            // = STLR, kind 2 + bit 15 + Rs/Rt2 = 11111 = LDAR.
            if bit23 == 1 && (kind == 1 || kind == 3) {                       // CAS / CASL / CASA / CASAL
                if rt2 != 31 { return try undef(insn) }
                // ARM semantics: compare [Rn] against Rs; on match store Rt;
                // the OLD value is written back to **Rs**, not Rt (stage-5
                // frontier 15: writing it to Rt made every `casal Rs, Rt,
                // [Rn]; cmp Rs, #0` retry loop spin forever).
                let expected = getReg(rs) & m
                let old = try readMem(addr, bytes) & m
                if old == expected { try writeMem(addr, bytes, getReg(rd) & m) }
                setReg(rs, old)
                pc = nextPc
                return true
            }
            if bit23 == 1 && kind == 0 && o3 == 1 && rs == 31 && rt2 == 31 {  // STLR
                try writeMem(addr, bytes, getReg(rd))
                pc = nextPc
                return true
            }
            if bit23 == 1 && kind == 2 && o3 == 1 && rs == 31 && rt2 == 31 {  // LDAR
                setReg(rd, try readMem(addr, bytes))
                pc = nextPc
                return true
            }
            if bit23 == 1 { return try undef(insn) }
            // exclusives: kind 0 STXR, 1 STXP, 2 LDXR, 3 LDXP (bit 15 = acquire/release variant)
            if kind == 0 {
                try writeMem(addr, bytes, getReg(rd))
                if rs != 31 { setReg(rs, 0) }
            } else if kind == 1 {
                try writeMem(addr, bytes, getReg(rd))
                try writeMem(addr &+ UInt64(bytes), bytes, getReg(rt2))
                if rs != 31 { setReg(rs, 0) }
            } else if kind == 2 {
                setReg(rd, try readMem(addr, bytes))
            } else {
                setReg(rd, try readMem(addr, bytes))
                setReg(rt2, try readMem(addr &+ UInt64(bytes), bytes))
            }
            pc = nextPc
            return true
        }

        // --- data-processing register ---
        if insn & 0x1FE00000 == 0x0B200000 {                                  // ADD/SUB extended reg
            let isSub = (insn >> 30) & 1, setF = (insn >> 29) & 1
            let opt = Int((insn >> 13) & 7), sh = Int((insn >> 10) & 7)
            var ext = getReg(rm)
            let from = [8, 16, 32, 64][opt & 3]
            ext &= from == 64 ? M64 : (UInt64(1) << from) - 1
            if opt >= 4 { ext = sext64(ext, from) }
            ext = (ext << sh) & M64
            let a = getReg(rn, true) & wmask
            let r = isSub == 1 ? (a &- ext) & M64 : (a &+ ext) & M64
            if setF == 1 { if isSub == 1 { flagsSub(a, ext, r, bits) } else { flagsAdd(a, ext, r, bits) } }
            if !(setF == 1 && rd == 31) { setReg(rd, r & wmask, setF == 0) }
            pc = nextPc
            return true
        }
        if insn & 0x1F200000 == 0x0B000000 {                                  // ADD/SUB shifted reg
            let isSub = (insn >> 30) & 1, setF = (insn >> 29) & 1
            let sht = Int((insn >> 22) & 3), amt = Int((insn >> 10) & 0x3F)
            if sht == 3 { return try undef(insn) }
            let b = shiftReg(getReg(rm), sht, amt, bits)
            let a = getReg(rn) & wmask                                        // Rn/Rd 31 = XZR here, never SP
            let r = isSub == 1 ? (a &- b) & M64 : (a &+ b) & M64
            if setF == 1 { if isSub == 1 { flagsSub(a, b, r, bits) } else { flagsAdd(a, b, r, bits) } }
            if !(setF == 1 && rd == 31) { setReg(rd, r & wmask) }
            pc = nextPc
            return true
        }
        if insn & 0x1F000000 == 0x0A000000 {                                  // logical shifted reg
            let opc = Int((insn >> 29) & 3), sht = Int((insn >> 22) & 3), nin = (insn >> 21) & 1
            var b = shiftReg(getReg(rm), sht, Int((insn >> 10) & 0x3F), bits)
            if nin == 1 { b = ~b & wmask }
            let a = getReg(rn) & wmask
            var r = opc == 1 ? (a | b) : (opc == 2 ? (a ^ b) : (a & b))
            r &= wmask
            if opc == 3 { flagsLogic(r, bits) }
            if !(opc == 3 && rd == 31) { setReg(rd, r) }
            pc = nextPc
            return true
        }
        if insn & 0x1FE00000 == 0x1A000000 {                                  // ADC / SBC
            let isSub = (insn >> 30) & 1, setF = (insn >> 29) & 1
            let a = getReg(rn) & wmask
            var b = getReg(rm) & wmask
            if isSub == 1 { b = ~b & wmask }
            let r = (a &+ b &+ UInt64(cFlag)) & M64
            if setF == 1 {
                // exact carry/overflow (the reference's first flagsAdd call is fully overwritten)
                let sign: UInt64 = bits == 64 ? 0x8000000000000000 : 0x80000000
                var carry: Int
                if bits == 64 {
                    let s1 = a.addingReportingOverflow(b)
                    let s2 = s1.partialValue.addingReportingOverflow(UInt64(cFlag))
                    carry = (s1.overflow || s2.overflow) ? 1 : 0
                } else {
                    carry = Int(((a & wmask) + (b & wmask) + UInt64(cFlag)) >> 32 & 1)
                }
                nFlag = (r & sign) != 0 ? 1 : 0
                zFlag = (r & wmask) == 0 ? 1 : 0
                cFlag = carry
                vFlag = ((~(a ^ b) & (a ^ r)) & sign) != 0 ? 1 : 0
            }
            setReg(rd, r & wmask)
            pc = nextPc
            return true
        }
        if insn & 0x3FE00000 == 0x3A400000 {                                  // CCMP / CCMN (register + immediate)
            let isSub = (insn >> 30) & 1                                      // 1 = CCMP, 0 = CCMN
            let cond = Int((insn >> 12) & 0xF), nzcv = Int(insn & 0xF)
            let a = getReg(rn) & wmask
            let b: UInt64 = ((insn >> 11) & 1) == 1 ? UInt64((insn >> 16) & 0x1F) : (getReg(rm) & wmask)
            if condHolds(cond) {
                if isSub == 1 { let r = (a &- b) & M64; flagsSub(a, b, r, bits) }
                else { let r = (a &+ b) & M64; flagsAdd(a, b, r, bits) }
            } else {
                nFlag = (nzcv >> 3) & 1; zFlag = (nzcv >> 2) & 1
                cFlag = (nzcv >> 1) & 1; vFlag = nzcv & 1
            }
            pc = nextPc
            return true
        }
        if insn & 0x1FE00000 == 0x1A800000 {                                  // CSEL family
            let op = Int((insn >> 30) & 1), op2 = Int((insn >> 10) & 3)
            let cond = Int((insn >> 12) & 0xF)
            let a = getReg(rn) & wmask, b = getReg(rm) & wmask
            var alt: UInt64
            if op == 0 && op2 == 0 { alt = b }                                // CSEL
            else if op == 0 && op2 == 1 { alt = (b &+ 1) & M64 }              // CSINC
            else if op == 1 && op2 == 0 { alt = ~b & M64 }                    // CSINV
            else if op == 1 && op2 == 1 { alt = (0 &- b) & M64 }              // CSNEG
            else { return try undef(insn) }
            setReg(rd, (condHolds(cond) ? a : alt) & wmask)
            pc = nextPc
            return true
        }
        if insn & 0xFFFF0000 == 0xDAC10000 {                                  // PACIA/PACIB/.../XPAC: auth not modelled — no-op
            pc = nextPc
            return true
        }
        if insn & 0x5FE00000 == 0x5AC00000 {                                  // DP 1-source (must precede DP 2-source)
            let opc = Int((insn >> 10) & 0x3F)
            let a = getReg(rn) & wmask
            var r: UInt64 = 0
            if opc == 0 {                                                     // RBIT
                r = 0
                for i in 0..<bits { if (a >> i) & 1 == 1 { r |= UInt64(1) << (bits - 1 - i) } }
            } else if opc == 1 {                                              // REV16
                r = 0
                var i = 0
                while i < bits {
                    r |= ((a >> i) & 0xFF) << (i + 8) | ((a >> (i + 8)) & 0xFF) << i
                    i += 16
                }
            } else if opc == 2 || opc == 3 {                                  // REV (32/64-bit forms)
                r = 0
                let nb = bits / 8
                for i in 0..<nb { r |= ((a >> (8 * i)) & 0xFF) << (8 * (nb - 1 - i)) }
            } else if opc == 4 {                                              // CLZ
                r = UInt64(bits)
                var i = bits - 1
                while i >= 0 { if (a >> i) & 1 == 1 { r = UInt64(bits - 1 - i); break }; i -= 1 }
            } else if opc == 5 {                                              // CLS
                let sign = (a >> (bits - 1)) & 1
                r = UInt64(bits - 1)
                var i = bits - 2
                while i >= 0 {
                    if ((a >> i) & 1) != sign { r = UInt64(bits - 2 - i); break }
                    if i == 0 { r = UInt64(bits - 1) }
                    i -= 1
                }
            } else { return try undef(insn) }
            setReg(rd, r & wmask)
            pc = nextPc
            return true
        }
        if insn & 0x1FE00000 == 0x1AC00000 {                                  // DP 2-source
            let opc = Int((insn >> 10) & 0x3F)
            let a = getReg(rn) & wmask, b = getReg(rm) & wmask
            var r: UInt64 = 0
            if opc == 2 { r = b == 0 ? 0 : a / b }                            // UDIV
            else if opc == 3 {                                                // SDIV: unsigned divide of sign-extended patterns (reference semantics, probe-verified)
                if b == 0 { r = 0 }
                else {
                    let sa = sext64(a, bits), sb = sext64(b, bits)
                    r = (sa / sb) & wmask
                }
            }
            else if opc == 8 { r = shiftReg(a, 0, Int(b & UInt64(bits - 1)), bits) }    // LSLV
            else if opc == 9 { r = shiftReg(a, 1, Int(b & UInt64(bits - 1)), bits) }    // LSRV
            else if opc == 10 { r = shiftReg(a, 2, Int(b & UInt64(bits - 1)), bits) }   // ASRV
            else if opc == 11 { r = shiftReg(a, 3, Int(b & UInt64(bits - 1)), bits) }   // RORV
            else { return try undef(insn) }
            setReg(rd, r & wmask)
            pc = nextPc
            return true
        }
        if insn & 0x1FE00000 == 0x1B000000 {                                  // MADD / MSUB
            let ra = Int((insn >> 10) & 31), o0 = (insn >> 15) & 1
            let prod = (getReg(rn) & wmask) &* (getReg(rm) & wmask)
            let acc = getReg(ra) & wmask
            setReg(rd, (o0 == 1 ? (acc &- prod) : (acc &+ prod)) & wmask)
            pc = nextPc
            return true
        }
        if sf == 1 && (insn & 0x1FE00000 == 0x1B200000 || insn & 0x1FE00000 == 0x1B400000 ||
                       insn & 0x1FE00000 == 0x1BA00000 || insn & 0x1FE00000 == 0x1BC00000) {
            // Multiply long / high: SMADDL/SMSUBL (op31 1), SMULH (2), UMADDL/UMSUBL (5), UMULH (6)
            let op31 = Int((insn >> 21) & 7), o0 = (insn >> 15) & 1, ra = Int((insn >> 10) & 31)
            var r: UInt64 = 0
            if op31 == 2 || op31 == 6 {                                       // SMULH / UMULH
                if ra != 31 { return try undef(insn) }
                let a = getReg(rn), b = getReg(rm)
                if op31 == 2 {
                    r = UInt64(bitPattern: Int64(bitPattern: a).multipliedFullWidth(by: Int64(bitPattern: b)).high)
                } else {
                    r = a.multipliedFullWidth(by: b).high
                }
            } else {                                                          // SMADDL / UMADDL family (32-bit sources)
                let a32 = getReg(rn) & 0xFFFFFFFF, b32 = getReg(rm) & 0xFFFFFFFF
                var prod: UInt64
                if op31 == 1 {
                    let sa = Int64(bitPattern: sext64(a32, 32)), sb = Int64(bitPattern: sext64(b32, 32))
                    prod = UInt64(bitPattern: sa &* sb)
                } else { prod = a32 * b32 }
                r = o0 == 1 ? (getReg(ra) &- prod) : (getReg(ra) &+ prod)
            }
            setReg(rd, r & M64)
            pc = nextPc
            return true
        }

        return try undef(insn)
    }
}

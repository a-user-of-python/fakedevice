// SIMD.swift — FakeDeviceCore
//
// The AdvSIMD/FP blocks of stepBody, transcribed from emu.js at the
// same position in the decode order (after MSR/MRS, before ADR).
// Vector values are V128 (lo/hi UInt64), mirroring the reference's
// 128-bit BigInts. Returns true when the instruction was handled;
// faults propagate as throws exactly like the reference.

import Foundation

extension Machine {

    /// Sign-extend a lane value to a signed integer (the reference's asS).
    private func asSigned(_ val: UInt64, _ esize: Int) -> Int64 {
        if esize == 64 { return Int64(bitPattern: val) }
        if (val >> (esize - 1)) & 1 == 1 { return Int64(val) - Int64(1 << esize) }
        return Int64(val)
    }

    // 128-bit helpers: the reference does its shift/saturate math in
    // arbitrary-precision integers; these reproduce the same results for
    // values held as (lo, hi) two's-complement pairs.
    private func shrL128(_ lo: UInt64, _ hi: UInt64, _ s: Int) -> (lo: UInt64, hi: UInt64) {
        if s <= 0 { return (lo, hi) }
        if s >= 128 { return (0, 0) }
        if s == 64 { return (hi, 0) }
        if s > 64 { return (hi >> (s - 64), 0) }
        return ((lo >> s) | (hi << (64 - s)), hi >> s)
    }
    private func shrA128(_ lo: UInt64, _ hi: UInt64, _ s: Int) -> (lo: UInt64, hi: UInt64) {
        if s <= 0 { return (lo, hi) }
        let fill: UInt64 = (hi >> 63) == 1 ? M64 : 0
        if s >= 128 { return (fill, fill) }
        if s == 64 { return (hi, fill) }
        if s > 64 { return (UInt64(bitPattern: Int64(bitPattern: hi) >> (s - 64)), fill) }
        return ((lo >> s) | (hi << (64 - s)), UInt64(bitPattern: Int64(bitPattern: hi) >> s))
    }
    private func shl128(_ lo: UInt64, _ hi: UInt64, _ s: Int) -> (lo: UInt64, hi: UInt64) {
        if s <= 0 { return (lo, hi) }
        if s >= 128 { return (0, 0) }
        if s == 64 { return (0, lo) }
        if s > 64 { return (0, lo << (s - 64)) }
        return (lo << s, (hi << s) | (lo >> (64 - s)))
    }
    private func add128(_ alo: UInt64, _ ahi: UInt64, _ blo: UInt64, _ bhi: UInt64) -> (lo: UInt64, hi: UInt64) {
        let (lo, carry) = alo.addingReportingOverflow(blo)
        return (lo, ahi &+ bhi &+ (carry ? 1 : 0))
    }
    /// Sign-extend an esize-bit lane value to a 128-bit two's-complement pair.
    private func sext128(_ a: UInt64, _ esize: Int) -> (lo: UInt64, hi: UInt64) {
        let neg = esize == 64 ? (a >> 63) == 1 : ((a >> (esize - 1)) & 1) == 1
        return (sext64(a, esize), neg ? M64 : 0)
    }
    /// Sign-extend a w-bit value held in a (lo, hi) pair to 128 bits.
    private func sext128w(_ a: (lo: UInt64, hi: UInt64), _ w: Int) -> (lo: UInt64, hi: UInt64) {
        if w == 128 { return a }
        if w == 64 { return (a.lo, (a.lo >> 63) == 1 ? M64 : 0) }
        let neg = ((a.lo >> (w - 1)) & 1) == 1
        return (sext64(a.lo, w), neg ? M64 : 0)
    }
    /// True when the 128-bit two's-complement value fits in a signed esize-bit integer.
    private func fitsS128(_ lo: UInt64, _ hi: UInt64, _ esize: Int) -> Bool {
        let t = shrA128(lo, hi, esize - 1)
        return (t.lo == 0 && t.hi == 0) || (t.lo == M64 && t.hi == M64)
    }
    /// Clamp a 128-bit signed value to the signed esize range; returns the pattern & em.
    private func clampS128(_ lo: UInt64, _ hi: UInt64, _ esize: Int) -> UInt64 {
        let em = laneMask(esize)
        if fitsS128(lo, hi, esize) { return lo & em }
        let signB: UInt64 = esize == 64 ? 0x8000000000000000 : UInt64(1) << (esize - 1)
        return (hi >> 63) == 1 ? (0 &- signB) & em : (signB - 1) & em
    }
    /// Clamp a 128-bit signed value to the unsigned esize range [0, em].
    private func clampU128fromS(_ lo: UInt64, _ hi: UInt64, _ esize: Int) -> UInt64 {
        let em = laneMask(esize)
        if (hi >> 63) == 1 { return 0 }
        let t = shrL128(lo, hi, esize)
        if t.lo != 0 || t.hi != 0 { return em }
        return lo & em
    }
    /// Clamp a non-negative 128-bit value to at most em (unsigned saturation).
    private func clampU128(_ lo: UInt64, _ hi: UInt64, _ esize: Int) -> UInt64 {
        let em = laneMask(esize)
        let t = shrL128(lo, hi, esize)
        if t.lo != 0 || t.hi != 0 { return em }
        return lo & em
    }

    func simdStep(_ insn: UInt32, rd: Int, rn: Int, rm: Int, nextPc: UInt64) throws -> Bool {
        // LDR (literal, SIMD&FP)
        if insn & 0x3F000000 == 0x1C000000 {
            let opc = Int((insn >> 30) & 3)
            if opc == 3 { return try undef(insn) }
            let bytes = opc == 0 ? 4 : (opc == 1 ? 8 : 16)
            var imm = Int64((insn >> 5) & 0x7FFFF)
            if imm & 0x40000 != 0 { imm |= ~0x7FFFF }
            v[rd] = try readV((pc &+ UInt64(bitPattern: imm << 2)) & M64, bytes)
            pc = nextPc
            return true
        }
        // LDR / STR (SIMD&FP), single register
        if insn & 0x3F000000 == 0x3C000000 || insn & 0x3F000000 == 0x3D000000 {
            let size = Int((insn >> 30) & 3), opc = Int((insn >> 22) & 3)
            let bytes = (size == 0 && opc >= 2) ? 16 : (1 << size)
            let isLoad = (opc & 1) == 1
            let base = getReg(rn, true)
            var addr: UInt64 = 0
            if (insn >> 21) & 1 == 1 {                                        // register offset
                let rm2 = Int((insn >> 16) & 31), opt = Int((insn >> 13) & 7), sh = (insn >> 12) & 1
                var off = getReg(rm2)
                if opt == 2 { off &= 0xFFFFFFFF }                             // UXTW
                else if opt == 6 { off = sext64(off & 0xFFFFFFFF, 32) }       // SXTW
                if sh == 1 { off <<= (bytes == 16 ? 4 : size) }
                addr = base &+ off
            } else if insn & 0x3F000000 == 0x3D000000 {                       // unsigned offset
                addr = base &+ UInt64((insn >> 10) & 0xFFF) * UInt64(bytes)
            } else {                                                          // unscaled / post / pre
                var imm = Int64((insn >> 12) & 0x1FF)
                if imm & 0x100 != 0 { imm |= ~0x1FF }
                let mode = Int((insn >> 10) & 3)
                if mode == 0 { addr = base &+ UInt64(bitPattern: imm) }
                else if mode == 1 { addr = base; setReg(rn, base &+ UInt64(bitPattern: imm), true) }
                else if mode == 3 { addr = base &+ UInt64(bitPattern: imm); setReg(rn, addr, true) }
                else { return try undef(insn) }
            }
            if isLoad { v[rd] = try readV(addr, bytes) }
            else { try writeV(addr, v[rd], bytes) }
            pc = nextPc
            return true
        }
        // LDP / STP (SIMD&FP) + LDNP / STNP. The guard mask must NOT include
        // bit 30: opc (bits 31:30) selects S/D/Q, and D pairs (opc 1) have
        // bit 30 set — the old 0x7A mask made them unmatchable and they fell
        // through to the integer pair block's undef (stage-5 frontier 12).
        if insn & 0x3A000000 == 0x28000000 && ((insn >> 26) & 1) == 1 {
            let opc = Int((insn >> 30) & 3)
            if opc == 3 { return try undef(insn) }
            let size = opc == 0 ? 4 : (opc == 1 ? 8 : 16)
            let l = (insn >> 22) & 1, mode = Int((insn >> 23) & 7)
            let rt2 = Int((insn >> 10) & 31)
            var imm = Int64((insn >> 15) & 0x7F)
            if imm & 0x40 != 0 { imm |= ~0x7F }
            imm *= Int64(size)
            let base = getReg(rn, true)
            var addr: UInt64 = 0
            if mode == 2 || mode == 0 { addr = base &+ UInt64(bitPattern: imm) }
            else if mode == 3 || mode == 1 || mode == 6 || mode == 7 { addr = base &+ UInt64(bitPattern: imm) }
            else { return try undef(insn) }
            let isPre = mode == 3 || mode == 7, isPost = mode == 1 || mode == 5
            let a0 = isPost ? base : addr
            if l == 1 {
                v[rd] = try readV(a0, size)
                v[rt2] = try readV(a0 &+ UInt64(size), size)
            } else {
                try writeV(a0, v[rd], size)
                try writeV(a0 &+ UInt64(size), v[rt2], size)
            }
            if isPre || isPost { setReg(rn, addr, true) }
            pc = nextPc
            return true
        }
        // MOVI / MVNI (modified immediate)
        if insn & 0x9F000000 == 0x0F000000 && ((insn >> 19) & 0x1F) == 0 && ((insn >> 10) & 1) == 1 {
            let q = (insn >> 30) & 1, cmode = Int((insn >> 12) & 0xF)
            let imm8 = UInt64(((insn >> 16) & 7) << 5 | ((insn >> 5) & 31))
            var val = V128.zero
            if cmode == 0xE || cmode == 0xC {                                 // every byte = imm8
                let b = imm8 * 0x0101010101010101
                val = V128(lo: b, hi: b)
            } else if cmode == 0xF {                                          // bit-expanded
                var lo: UInt64 = 0
                for j in 0..<8 { if (imm8 >> j) & 1 == 1 { lo |= 0xFF << (j * 8) } }
                val = V128(lo: lo, hi: q == 1 ? lo : 0)
            } else if (cmode & 0x8) == 0 {                                    // 32-bit lanes
                let e = imm8 << (((cmode >> 1) & 3) * 8)
                let lo = e | (e << 32)
                val = V128(lo: lo, hi: q == 1 ? lo : 0)
            } else if (cmode & 0xE) == 0x8 {                                  // 16-bit lanes
                let e = imm8 << ((cmode & 1) * 8)
                var lo: UInt64 = 0
                for i in 0..<4 { lo |= e << (i * 16) }
                val = V128(lo: lo, hi: q == 1 ? lo : 0)
            } else { return try undef(insn) }
            if cmode != 0xE && ((insn >> 29) & 1) == 1 { val = ~val }         // MVNI
            v[rd] = q == 1 ? val : val.lowOnly
            pc = nextPc
            return true
        }
        // Advanced SIMD shift by immediate (stage-5 frontier 5). Opcode map
        // (bits 15:11 x U), calibrated against capstone in the reference:
        //   opc 0 SSHR/USHR    2 SSRA/USRA     4 SRSHR/URSHR   6 SRSRA/URSRA
        //   opc 8 SRI (U=1)   10 SHL/SLI      12 SQSHLU (U=1) 14 SQSHL/UQSHL
        //   opc 16 SHRN/SQSHRUN  17 RSHRN/SQRSHRUN  18 SQSHRN/UQSHRN
        //   opc 19 SQRSHRN/UQRSHRN          20 SSHLL/USHLL
        if insn & 0x9F000000 == 0x0F000000 && ((insn >> 19) & 0xF) != 0 && ((insn >> 10) & 1) == 1 {
            let u = (insn >> 29) & 1, q = (insn >> 30) & 1
            let immh = Int((insn >> 19) & 0xF), imm = Int((insn >> 16) & 0x7F), opc = Int((insn >> 11) & 0x1F)
            let esize = immh >= 8 ? 64 : (immh >= 4 ? 32 : (immh >= 2 ? 16 : 8))
            let em = laneMask(esize)
            let src = v[rn], dst = v[rd]
            if opc == 0 || opc == 2 || opc == 4 || opc == 6 || opc == 8 {     // right shifts
                let s = 2 * esize - imm                                       // 1...esize
                let round: UInt64 = UInt64(1) << (s - 1)
                let lanes = (q == 1 ? 128 : 64) / esize
                var r = V128.zero
                for i in 0..<lanes {
                    let a = src.lane(esize, i), d = dst.lane(esize, i)
                    let shU: UInt64 = s >= 64 ? 0 : (a >> s)
                    let sv = asSigned(a, esize)
                    let shS: UInt64 = s >= 64 ? (sv < 0 ? em : 0) : (UInt64(bitPattern: sv >> s) & em)
                    let (sumU, ofU) = a.addingReportingOverflow(round)        // (a + round) >> s, 65-bit sum
                    let shUR: UInt64 = s == 64 ? (ofU ? 1 : 0) : ((sumU >> s) | (ofU ? (UInt64(1) << (64 - s)) : 0))
                    let ext = sext128(a, esize)                               // (toS(a) + round) >> s, signed 128-bit
                    let sumS = add128(ext.lo, ext.hi, round, 0)
                    let shSR: UInt64 = shrA128(sumS.lo, sumS.hi, s).lo & em
                    var out: UInt64
                    if opc == 0 { out = u == 1 ? shU : shS }                  // SSHR / USHR
                    else if opc == 2 { out = (d &+ (u == 1 ? shU : shS)) & em }   // SSRA / USRA
                    else if opc == 4 { out = u == 1 ? shUR : shSR }           // SRSHR / URSHR
                    else if opc == 6 { out = (d &+ (u == 1 ? shUR : shSR)) & em } // SRSRA / URSRA
                    else { out = (d & (em ^ ((UInt64(1) << (esize - s)) - 1))) | shU }  // SRI: keep top s bits of dst
                    r.setLane(esize, i, out)
                }
                v[rd] = r
                pc = nextPc
                return true
            }
            if opc == 10 || opc == 12 || opc == 14 {                          // left shifts
                let s = imm - esize                                           // 0...esize-1
                let lanes = (q == 1 ? 128 : 64) / esize
                var r = V128.zero
                for i in 0..<lanes {
                    let a = src.lane(esize, i), d = dst.lane(esize, i)
                    var out: UInt64
                    if opc == 10 && u == 0 { out = (a << s) & em }            // SHL
                    else if opc == 10 { out = (d & ((UInt64(1) << s) - 1)) | ((a << s) & em) }  // SLI: keep low s bits of dst
                    else if opc == 12 && u == 1 {                             // SQSHLU
                        let ext = sext128(a, esize)
                        let x = shl128(ext.lo, ext.hi, s)
                        out = (x.hi >> 63) == 1 ? 0 : clampU128(x.lo, x.hi, esize)
                    }
                    else if opc == 14 && u == 0 {                             // SQSHL
                        let ext = sext128(a, esize)
                        let x = shl128(ext.lo, ext.hi, s)
                        out = clampS128(x.lo, x.hi, esize)
                    }
                    else if opc == 14 && u == 1 {                             // UQSHL
                        let x = shl128(a, 0, s)
                        out = clampU128(x.lo, x.hi, esize)
                    }
                    else { return try undef(insn) }
                    r.setLane(esize, i, out)
                }
                v[rd] = r
                pc = nextPc
                return true
            }
            if opc >= 16 && opc <= 19 {                                       // narrowing
                let w = 2 * esize
                let s = w - imm
                // The reference's round = 1 << (s-1); at s == 0 its BigInt
                // negative shift makes that 0.
                var roundLo: UInt64 = 0, roundHi: UInt64 = 0
                if s >= 1 && s - 1 < 64 { roundLo = UInt64(1) << (s - 1) }
                else if s - 1 >= 64 { roundHi = UInt64(1) << (s - 65) }
                let lanes = 64 / esize, srcLanes = q == 1 ? 2 * lanes : lanes
                var half = V128.zero
                for i in 0..<srcLanes {
                    // source lane i: w bits at bit offset i*w (zero beyond 128)
                    let off = i * w
                    let a128: (lo: UInt64, hi: UInt64)
                    if off >= 128 { a128 = (0, 0) }
                    else if w == 128 { a128 = (src.lo, src.hi) }
                    else if w == 64 { a128 = (off == 0 ? src.lo : src.hi, 0) }
                    else { a128 = (src.lane(w, i), 0) }
                    let sv128 = sext128w(a128, w)
                    var out: UInt64
                    if opc == 16 && u == 0 { out = shrL128(a128.lo, a128.hi, s).lo & em }        // SHRN
                    else if opc == 16 {                                                          // SQSHRUN
                        let x = shrA128(sv128.lo, sv128.hi, s)
                        out = clampU128fromS(x.lo, x.hi, esize)
                    }
                    else if opc == 17 && u == 0 {                                                // RSHRN
                        let sum = add128(a128.lo, a128.hi, roundLo, roundHi)
                        out = shrL128(sum.lo, sum.hi, s).lo & em
                    }
                    else if opc == 17 {                                                          // SQRSHRUN
                        let sum = add128(sv128.lo, sv128.hi, roundLo, roundHi)
                        let x = shrA128(sum.lo, sum.hi, s)
                        out = clampU128fromS(x.lo, x.hi, esize)
                    }
                    else if opc == 18 && u == 0 {                                                // SQSHRN
                        let x = shrA128(sv128.lo, sv128.hi, s)
                        out = clampS128(x.lo, x.hi, esize)
                    }
                    else if opc == 18 {                                                          // UQSHRN
                        let x = shrL128(a128.lo, a128.hi, s)
                        out = clampU128(x.lo, x.hi, esize)
                    }
                    else if u == 0 {                                                             // SQRSHRN (opc 19)
                        let sum = add128(sv128.lo, sv128.hi, roundLo, roundHi)
                        let x = shrA128(sum.lo, sum.hi, s)
                        out = clampS128(x.lo, x.hi, esize)
                    }
                    else {                                                                       // UQRSHRN (opc 19)
                        let sum = add128(a128.lo, a128.hi, roundLo, roundHi)
                        let x = shrL128(sum.lo, sum.hi, s)
                        out = clampU128(x.lo, x.hi, esize)
                    }
                    half.setLane(esize, i, out)
                }
                v[rd] = q == 1 ? V128(lo: dst.lo, hi: half.lo) : half
                pc = nextPc
                return true
            }
            if opc == 20 {                                                    // widening: SSHLL / USHLL
                let s = imm - esize
                let dem = laneMask(2 * esize)
                let lanes = 64 / esize, off = q == 1 ? 64 : 0
                var r = V128.zero
                for i in 0..<lanes {
                    let a = src.lane(esize, off / esize + i)
                    let ext = u == 1 ? (lo: a, hi: UInt64(0)) : sext128(a, esize)
                    let x = shl128(ext.lo, ext.hi, s)
                    if 2 * esize == 128 { r = V128(lo: x.lo, hi: x.hi) }
                    else { r.setLane(2 * esize, i, x.lo & dem) }
                }
                v[rd] = r
                pc = nextPc
                return true
            }
            return try undef(insn)
        }
        // Load/store MULTIPLE structures (LD1-LD4 / ST1-ST4, register lists;
        // stage-5 frontier 5). Bit 22 = L, bit 23 = post-index present,
        // Rm = post-index register (31 = immediate, amount = bytes
        // transferred), bits 15:12 select count/interleave.
        if insn & 0xBF000000 == 0x0C000000 && ((insn >> 21) & 1) == 0 {
            let isLoad = ((insn >> 22) & 1) == 1, post = ((insn >> 23) & 1) == 1
            let rm2 = Int((insn >> 16) & 31), opcS = Int((insn >> 12) & 0xF), size = Int((insn >> 10) & 3)
            let nregs = (opcS == 0 || opcS == 2) ? 4 : ((opcS == 4 || opcS == 6) ? 3 : (opcS == 7 ? 1 : 2))
            let nstruct = opcS == 0 ? 4 : (opcS == 4 ? 3 : (opcS == 8 ? 2 : 1))
            let q = (insn >> 30) & 1, esize = 8 << size, ebytes = esize / 8
            let lanes = (q == 1 ? 128 : 64) / esize, em = laneMask(esize)
            if size == 3 && q == 0 && nregs > 1 { return try undef(insn) }
            let addr = getReg(rn, true)
            let total = UInt64(nregs * lanes * ebytes)
            // element (lane j, register i) sits at memory element
            // j*nstruct + i for interleaved forms, or i*lanes + j for
            // LD1/ST1 (nstruct = 1: each register's lanes are contiguous).
            func elemAddr(_ j: Int, _ i: Int) -> UInt64 {
                addr &+ UInt64((nstruct == 1 ? i * lanes + j : j * nstruct + i) * ebytes)
            }
            if isLoad {
                var nv = [V128](repeating: .zero, count: nregs)
                for j in 0..<lanes {
                    for i in 0..<nregs {
                        let val = try readV(elemAddr(j, i), ebytes).lo & em
                        nv[i].setLane(esize, j, val)
                    }
                }
                for i in 0..<nregs { v[(rd + i) & 31] = nv[i] }
            } else {
                for j in 0..<lanes {
                    for i in 0..<nregs {
                        try writeV(elemAddr(j, i), V128(lo: v[(rd + i) & 31].lane(esize, j) & em, hi: 0), ebytes)
                    }
                }
            }
            if post { setReg(rn, addr &+ (rm2 == 31 ? total : getReg(rm2)), true) }
            pc = nextPc
            return true
        }
        // three-same LOGICAL: AND/BIC/ORR/ORN (U=0), EOR/BIT/BSL/BIF (U=1)
        if insn & 0x9F000000 == 0x0E000000 && (insn & 0xF800) == 0x1800 && ((insn >> 21) & 1) == 1 {
            let u = (insn >> 29) & 1, sel = Int((insn >> 22) & 3), q = (insn >> 30) & 1
            let a = v[rn], b = v[rm]
            var r: V128
            if u == 0 {
                r = sel == 0 ? (a & b) : (sel == 1 ? (a & ~b) : (sel == 2 ? (a | b) : (a | ~b)))
            } else {
                r = sel == 0 ? (a ^ b)
                    : (sel == 1 ? ((a & b) | (v[rd] & ~b))
                    : (sel == 2 ? ((v[rd] & a) | (~v[rd] & b))
                    : ((a & ~b) | (v[rd] & b))))
            }
            v[rd] = q == 1 ? r : r.lowOnly
            pc = nextPc
            return true
        }
        // ADD / SUB (vector, integer lanes)
        if insn & 0x9F000000 == 0x0E000000 && (insn & 0xF800) == 0x8000 && ((insn >> 21) & 1) == 1 {
            let u = (insn >> 29) & 1, size = Int((insn >> 22) & 3), q = (insn >> 30) & 1
            let esize = 8 << size, lanes = (q == 1 ? 128 : 64) / esize, em = laneMask(esize)
            var r = V128.zero
            for i in 0..<lanes {
                let a = v[rn].lane(esize, i), b = v[rm].lane(esize, i)
                r.setLane(esize, i, (u == 1 ? (a &- b) : (a &+ b)) & em)
            }
            v[rd] = r
            pc = nextPc
            return true
        }
        // three-same compares / min / max / abs-diff / multiply (lane-wise)
        if insn & 0x9F000000 == 0x0E000000 && ((insn >> 21) & 1) == 1 && [13, 15, 25, 27, 29, 35, 37, 39].contains(Int((insn >> 10) & 0x3F)) {
            let u = (insn >> 29) & 1, size = Int((insn >> 22) & 3), q = (insn >> 30) & 1
            let opc = Int((insn >> 10) & 0x3F)
            let esize = 8 << size, lanes = (q == 1 ? 128 : 64) / esize, em = laneMask(esize)
            var r = V128.zero
            for i in 0..<lanes {
                let a = v[rn].lane(esize, i), b = v[rm].lane(esize, i)
                var out: UInt64 = 0
                if opc == 13 { out = (u == 1 ? a > b : asSigned(a, esize) > asSigned(b, esize)) ? em : 0 }        // CMHI / CMGT
                else if opc == 15 { out = (u == 1 ? a >= b : asSigned(a, esize) >= asSigned(b, esize)) ? em : 0 } // CMHS / CMGE
                else if opc == 35 { out = (u == 1 ? a == b : (a & b) != 0) ? em : 0 }                              // CMEQ / CMTST
                else if opc == 25 { out = u == 1 ? max(a, b) : (asSigned(a, esize) > asSigned(b, esize) ? a : b) } // UMAX / SMAX
                else if opc == 27 { out = u == 1 ? min(a, b) : (asSigned(a, esize) < asSigned(b, esize) ? a : b) } // UMIN / SMIN
                else if opc == 29 {                                                                               // UABD / SABD
                    if u == 1 { out = (a > b ? a - b : b - a) & em }
                    else {
                        let d = Int64(bitPattern: UInt64(bitPattern: asSigned(a, esize)) &- UInt64(bitPattern: asSigned(b, esize)))
                        out = (d == Int64.min ? 0x8000000000000000 : UInt64(d < 0 ? -d : d)) & em
                    }
                }
                else if opc == 37 {                                                                               // MLS / MLA
                    let cur = v[rd].lane(esize, i)
                    out = (u == 1 ? (cur &- (a &* b)) : (cur &+ (a &* b))) & em
                }
                else { out = (a &* b) & em }                                                                      // MUL (39)
                r.setLane(esize, i, out)
            }
            v[rd] = q == 1 ? r : r.lowOnly
            pc = nextPc
            return true
        }
        // three-same SHIFT BY REGISTER (stage-5 frontier 13): opc5 8 =
        // SSHL/USHL, 9 = SQSHL/UQSHL, 10 = SRSHL/URSHL, 11 = SQRSHL/UQRSHL.
        // Per lane, the shift count is the low byte of the Rm lane as a
        // signed value: >= 0 shifts left, < 0 shifts right by its negation.
        if insn & 0x9F000000 == 0x0E000000 && ((insn >> 21) & 1) == 1 && [8, 9, 10, 11].contains(Int((insn >> 11) & 0x1F)) {
            let u = (insn >> 29) & 1, size = Int((insn >> 22) & 3), q = (insn >> 30) & 1
            let opc5 = Int((insn >> 11) & 0x1F)
            let esize = 8 << size, lanes = (q == 1 ? 128 : 64) / esize, em = laneMask(esize)
            let sat = opc5 == 9 || opc5 == 11, rnd = opc5 == 10 || opc5 == 11
            var r = V128.zero
            for i in 0..<lanes {
                let a = v[rn].lane(esize, i), b = v[rm].lane(esize, i)
                var sb = Int(b & 0xFF)
                if sb >= 128 { sb -= 256 }
                var out: UInt64
                if sb >= 0 {
                    if !sat { out = sb >= 64 ? 0 : ((a << sb) & em) }
                    else if u == 1 {                                          // UQSHL / UQRSHL (left)
                        let x = shl128(a, 0, sb)
                        out = clampU128(x.lo, x.hi, esize)
                    } else {                                                  // SQSHL / SQRSHL (left)
                        let ext = sext128(a, esize)
                        let x = shl128(ext.lo, ext.hi, sb)
                        out = clampS128(x.lo, x.hi, esize)
                    }
                } else {
                    let n = -sb                                               // 1...128
                    var rLo: UInt64 = 0, rHi: UInt64 = 0                      // 2^(n-1) as a 128-bit value
                    if n - 1 < 64 { rLo = UInt64(1) << (n - 1) } else { rHi = UInt64(1) << (n - 65) }
                    if u == 1 {
                        if rnd {                                              // URSHL / UQRSHL (right)
                            let sum = add128(a, 0, rLo, rHi)
                            out = shrL128(sum.lo, sum.hi, n).lo & em
                        } else {                                              // USHL (right)
                            out = n >= esize ? 0 : ((a >> n) & em)
                        }
                    } else {
                        let sa = asSigned(a, esize)
                        if rnd {                                              // SRSHL / SQRSHL (right)
                            let ext = sext128(a, esize)
                            let sum = add128(ext.lo, ext.hi, rLo, rHi)
                            out = shrA128(sum.lo, sum.hi, n).lo & em
                        } else {                                              // SSHL (right)
                            out = n >= esize ? (sa < 0 ? em : 0) : (UInt64(bitPattern: sa >> n) & em)
                        }
                    }
                }
                r.setLane(esize, i, out)
            }
            v[rd] = q == 1 ? r : r.lowOnly
            pc = nextPc
            return true
        }
        // vector reductions: ADDV / SMINV / UMINV / SMAXV / UMAXV
        if insn & 0x9F000000 == 0x0E000000 && ((insn >> 17) & 0x1F) == 0x18 && ((insn >> 10) & 3) == 2 {
            let u = (insn >> 29) & 1, size = Int((insn >> 22) & 3), q = (insn >> 30) & 1
            let opc = Int((insn >> 12) & 0x1F)
            let esize = 8 << size, lanes = (q == 1 ? 128 : 64) / esize, em = laneMask(esize)
            var r: UInt64 = 0
            if opc == 0x1B {                                                  // ADDV
                var sum: UInt64 = 0
                for i in 0..<lanes { sum = sum &+ v[rn].lane(esize, i) }
                r = sum & em
            } else if opc == 0x03 {                                           // SADDLV / UADDLV (stage-5 frontier 17)
                if esize == 64 {
                    // The result lane is 2*esize = 128 bits wide and the
                    // reference accumulates in arbitrary precision — do the
                    // same with a 128-bit add (sign-extended lanes for S).
                    var lo: UInt64 = 0, hi: UInt64 = 0
                    for i in 0..<lanes {
                        let a = v[rn].lane(64, i)
                        let (nlo, carry) = lo.addingReportingOverflow(a)
                        lo = nlo
                        hi = hi &+ (carry ? 1 : 0) &+ (u == 0 && (a >> 63) == 1 ? M64 : 0)
                    }
                    v[rd] = V128(lo: lo, hi: hi)
                    pc = nextPc
                    return true
                }
                var sum: Int64 = 0
                for i in 0..<lanes {
                    let lane = v[rn].lane(esize, i)
                    sum = sum &+ (u == 1 ? Int64(bitPattern: lane) : asSigned(lane, esize))
                }
                r = UInt64(bitPattern: sum) & ((UInt64(1) << (esize * 2)) - 1)
            } else if opc == 0x1A || opc == 0x0A {                            // MINV (11010) / MAXV (01010)
                let isMin = opc == 0x1A
                var bestKey: Int64? = nil
                var bestLane: UInt64 = 0
                for i in 0..<lanes {
                    let lane = v[rn].lane(esize, i)
                    let key: Int64 = u == 1 ? Int64(bitPattern: lane) : asSigned(lane, esize)
                    // JS compares unsigned lanes as BigInts for U forms; emulate via unsigned compare
                    if bestKey == nil || (u == 1 ? (isMin ? lane < bestLane : lane > bestLane)
                                                  : (isMin ? key < bestKey! : key > bestKey!)) {
                        bestKey = key
                        bestLane = lane
                    }
                }
                r = bestLane
            } else { return try undef(insn) }
            v[rd] = V128(lo: r, hi: 0)
            pc = nextPc
            return true
        }
        // FMOV register moves
        if insn & 0xFFFFFC00 == 0x9E670000 { v[rd] = V128(lo: getReg(rn), hi: 0); pc = nextPc; return true }        // FMOV Dd, Xn
        if insn & 0xFFFFFC00 == 0x9E660000 { setReg(rd, v[rn].lo); pc = nextPc; return true }                        // FMOV Xd, Dn
        if insn & 0xFFFFFC00 == 0x1E270000 { v[rd] = V128(lo: getReg(rn) & 0xFFFFFFFF, hi: 0); pc = nextPc; return true }  // FMOV Sd, Wn
        if insn & 0xFFFFFC00 == 0x1E260000 { setReg(rd, v[rn].lo & 0xFFFFFFFF); pc = nextPc; return true }           // FMOV Wd, Sn
        if insn & 0xFFFFFC00 == 0x1E204000 { v[rd] = V128(lo: v[rn].lo & 0xFFFFFFFF, hi: 0); pc = nextPc; return true }    // FMOV Sd, Sn
        if insn & 0xFFFFFC00 == 0x1E604000 { v[rd] = V128(lo: v[rn].lo, hi: 0); pc = nextPc; return true }            // FMOV Dd, Dn
        // EXT (byte extract from concatenated pair)
        if insn & 0xBFE08400 == 0x2E000000 {
            let q = (insn >> 30) & 1, imm4 = Int((insn >> 11) & 0xF), size = q == 1 ? 16 : 8
            var cat = [UInt8]()
            for i in 0..<size { cat.append(UInt8(v[rn].lane(8, i))) }
            for i in 0..<size { cat.append(UInt8(v[rm].lane(8, i))) }
            var r = V128.zero
            for i in 0..<size { r.setLane(8, i, UInt64(cat[imm4 + i])) }
            v[rd] = r
            pc = nextPc
            return true
        }
        // DUP (element): replicate one lane of Vn
        if insn & 0xBFE0FC00 == 0x0E000400 {
            let imm5 = Int((insn >> 16) & 31)
            var tz = 0
            while tz < 5 && ((imm5 >> tz) & 1) == 0 { tz += 1 }
            let esize = 8 << tz, idx = imm5 >> (tz + 1)
            let q = (insn >> 30) & 1
            let val = v[rn].lane(esize, idx)
            var r = V128.zero
            let lanes = (q == 1 ? 128 : 64) / esize
            for i in 0..<lanes { r.setLane(esize, i, val) }
            v[rd] = r
            pc = nextPc
            return true
        }
        // DUP / INS / UMOV+SMOV (copy between GPR and vector lanes)
        let fam = insn & 0x9F00FC00
        if fam == 0x0E000C00 || fam == 0x0E001C00 || fam == 0x0E003C00 {
            let imm5 = Int((insn >> 16) & 31)
            var tz = 0
            while tz < 5 && ((imm5 >> tz) & 1) == 0 { tz += 1 }
            let esize = 8 << tz, idx = imm5 >> (tz + 1), em = laneMask(esize)
            let q = (insn >> 30) & 1
            if fam == 0x0E000C00 {                                            // DUP (general)
                let val = getReg(rn) & em
                var r = V128.zero
                let lanes = (q == 1 ? 128 : 64) / esize
                for i in 0..<lanes { r.setLane(esize, i, val) }
                v[rd] = r
            } else if fam == 0x0E001C00 {                                     // INS (general)
                var nv = v[rd]
                nv.setLane(esize, idx, getReg(rn) & em)
                v[rd] = nv
            } else {                                                          // UMOV / SMOV
                var val = v[rn].lane(esize, idx)
                if ((insn >> 29) & 1) == 1 { val = sext64(val, esize) }       // SMOV sign-extend
                setReg(rd, val)
            }
            pc = nextPc
            return true
        }
        return false
    }
}

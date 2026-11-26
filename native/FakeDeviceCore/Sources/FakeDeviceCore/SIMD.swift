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
        // LDP / STP (SIMD&FP) + LDNP / STNP
        if insn & 0x7A000000 == 0x28000000 && ((insn >> 26) & 1) == 1 {
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

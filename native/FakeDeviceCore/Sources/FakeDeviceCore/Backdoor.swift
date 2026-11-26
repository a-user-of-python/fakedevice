// Backdoor.swift — FakeDeviceCore
//
// The backdoor console: the same commands as the web page's backdoor
// (help/regs/sysregs/status/lastpc/mmio/peek/peekp/poke/pokep/setreg/
// bp/bplist/bpclear/step/run/patch/uartin), with the same output text.
// All numbers are hex. peek/poke go through the kernel's page tables;
// peekp/pokep touch raw physical memory. Quiet accesses never disturb
// the CPU state.

import Foundation

public enum Backdoor {
    struct Failure: Error { let message: String }

    public static func run(_ m: Machine, _ raw: String) -> String {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return "" }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init)
        let cmd = parts[0].lowercased()
        do {
            return try dispatch(m, line: line, parts: parts, cmd: cmd)
        } catch let f as Failure {
            return "error: \(f.message)"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    private static func parseNum(_ s: String?) throws -> UInt64 {
        guard var t = s?.trimmingCharacters(in: .whitespaces) else { throw Failure(message: "missing number") }
        if t.lowercased().hasPrefix("0x") { t = String(t.dropFirst(2)) }
        guard !t.isEmpty, let v = UInt64(t, radix: 16) else { throw Failure(message: "bad number '\(s ?? "")'") }
        return v
    }

    private static func parseBytes(_ s: String) -> [UInt8] {
        let hex = s.filter { $0.isHexDigit }
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if j == hex.index(after: i) { break }
            if let b = UInt8(hex[i..<j], radix: 16) { out.append(b) }
            i = j
        }
        return out
    }

    private static func hexDump(_ addr: UInt64, _ bytes: [UInt8]) -> String {
        var lines = [String]()
        var i = 0
        while i < bytes.count {
            var h = "", a = ""
            var j = i
            while j < min(i + 16, bytes.count) {
                let b = bytes[j]
                let bs = String(b, radix: 16)
                h += (bs.count == 1 ? "0" + bs : bs) + " "
                a += (b >= 32 && b < 127) ? String(UnicodeScalar(b)) : "."
                j += 1
            }
            while h.count < 48 { h += " " }
            lines.append(hexStr(addr &+ UInt64(i)) + "  " + h + " " + a)
            i += 16
        }
        return lines.joined(separator: "\n")
    }

    private static func dispatch(_ m: Machine, line: String, parts: [String], cmd: String) throws -> String {
        if cmd == "help" {
            return """
            regs | sysregs | status | lastpc | mmio
            peek <addr> [len] — memory through the page tables (kernel's view)
            peekp <addr> [len] — raw physical memory
            poke <addr> <hexbytes> | pokep <addr> <hexbytes>
            setreg <x0..x30|sp|pc> <value>
            bp <addr> | bplist | bpclear — breakpoints
            step [n] | run [n] — execute (run default 1,000,000, cap 20,000,000)
            patch <addr> <word> — overwrite one 4-byte instruction (hex, e.g. d503201f = nop)
            uartin <text> — type text into the fake phone's serial port
            """
        }
        switch cmd {
        case "status":
            var s = "status: \(m.status) | instructions: \(m.icount) | PC: \(hexStr(m.pc)) | SP: \(hexStr(m.sp)) | MMU: \(m.mmuOn ? "ON" : "off") | exceptions: \(m.exceptions)"
            if !m.lastException.isEmpty { s += "\nlast exception: \(m.lastException)" }
            if !m.trapInfo.isEmpty { s += "\nstop reason: \(m.trapInfo)" }
            return s
        case "regs":
            var out = [String]()
            for i in 0...30 { out.append("X\(i) = \(hexStr(m.x[i]))") }
            out.append("SP = \(hexStr(m.sp)) | PC = \(hexStr(m.pc)) | status = \(m.status)")
            return out.joined(separator: "\n")
        case "sysregs":
            let rows = m.sysregs.map { "S(\($0.key)) = \(hexStr($0.value))" }.sorted()
            return rows.isEmpty ? "(no system registers written yet)" : rows.joined(separator: "\n")
        case "lastpc":
            return m.lastPcs(16).map { hexStr($0) }.joined(separator: " ")
        case "mmio":
            let rows = m.mmioLog.map { "\($0.key) touched x\($0.count)" }
            return rows.isEmpty ? "(no stub-MMIO touches yet)" : rows.joined(separator: "\n")
        case "peek", "peekp":
            let addr = try parseNum(parts.count > 1 ? parts[1] : nil)
            var len = parts.count > 2 ? Int(try parseNum(parts[2])) : 64
            if len > 4096 { len = 4096 }
            var bytes = [UInt8]()
            if cmd == "peek" {
                bytes = m.peekQuiet(addr, len)
            } else {
                for q in 0..<len { bytes.append(UInt8(m.readPhys(addr &+ UInt64(q), 1) & 0xFF)) }
            }
            return hexDump(addr, bytes)
        case "poke", "pokep":
            let addr = try parseNum(parts.count > 1 ? parts[1] : nil)
            let bs = parseBytes(parts.dropFirst(2).joined())
            if cmd == "poke" {
                m.pokeQuiet(addr, bs)
            } else {
                for (w, b) in bs.enumerated() { m.writePhys(addr &+ UInt64(w), UInt64(b), 1) }
            }
            return "wrote \(bs.count) byte(s) at \(hexStr(addr))"
        case "setreg":
            let name = (parts.count > 1 ? parts[1] : "").lowercased()
            let val = try parseNum(parts.count > 2 ? parts[2] : nil)
            if name == "pc" { m.pc = val & M64 }
            else if name == "sp" { m.sp = val & M64 }
            else if name.hasPrefix("x"), let idx = Int(name.dropFirst()), idx >= 0 && idx <= 30 { m.x[idx] = val }
            else { return "unknown register: \(name)" }
            return "\(name) = \(hexStr(val))"
        case "bp":
            let addr = try parseNum(parts.count > 1 ? parts[1] : nil)
            m.addBreakpoint(addr)
            return "breakpoint set at \(parts.count > 1 ? parts[1] : "")"
        case "bplist":
            return m.breakpointList.isEmpty ? "(no breakpoints)" : m.breakpointList.joined(separator: ", ")
        case "bpclear":
            m.clearBreakpoints()
            return "breakpoints cleared"
        case "step":
            var n = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
            if n > 100000 { n = 100000 }
            var done = 0
            while done < n && m.step() { done += 1 }
            return "stepped \(done) — PC \(hexStr(m.pc)), status \(m.status)"
        case "run":
            var n = parts.count > 1 ? (Int(parts[1]) ?? 1000000) : 1000000
            if n > 20000000 { n = 20000000 }
            m.run(n)
            return "ran — PC \(hexStr(m.pc)), status \(m.status)" + (m.trapInfo.isEmpty ? "" : " — \(m.trapInfo)")
        case "patch":
            let addr = try parseNum(parts.count > 1 ? parts[1] : nil)
            let word = try parseNum(parts.count > 2 ? parts[2] : nil) & 0xFFFFFFFF
            let bs: [UInt8] = [UInt8(word & 0xFF), UInt8((word >> 8) & 0xFF), UInt8((word >> 16) & 0xFF), UInt8((word >> 24) & 0xFF)]
            m.pokeQuiet(addr, bs)
            var ws = String(word, radix: 16)
            while ws.count < 8 { ws = "0" + ws }
            return "patched instruction at \(hexStr(addr)) -> 0x\(ws)"
        case "uartin":
            let text = line.count > 7 ? String(line.dropFirst(7)) : ""
            m.queueUartRx(text + "\n")
            return "queued serial input: \(text)"
        default:
            return "unknown command — type help"
        }
    }
}

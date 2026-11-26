// fakedevice-check — headless acceptance harness for the FakeDeviceCore
// Swift port. Applies the same checks the JavaScript reference passes:
//
//   keytest     — MRS stubs (CurrentEL / MPIDR / Apple core register)
//   self-test   — built-in program prints "test" then "55", 77 instructions
//   sdiv        — the reference's SDIV semantics (probe-verified against JS)
//   simd        — test_simd.mjs's 30 checks on the same program bytes
//   mul         — test_mul.mjs's 14 checks on the same program bytes
//   adt         — buildADT length is 2,740 bytes, like the reference
//   kernel boot — with a kernelcache path argument: the Swift core must
//                 reach the reference's exact endpoint, measured from the
//                 JS core the same day (the boot frontier moves as the
//                 reference improves): the first exception (an undefined
//                 instruction) is delivered at instruction 17,723,144 and
//                 the kernel parks at 0xFFFFFFF0081BA410.
//
// The machine definition arrives as DATA: the harness loads the
// translator pack (argv[2], else the repo's build/ copy) exactly like
// the apps do. Exit code 0 only if every check passes.

import Foundation
import FakeDeviceCore

var pass = 0, fail = 0
func chk(_ name: String, _ cond: Bool) {
    if cond { pass += 1 } else { fail += 1; print("FAIL: \(name)") }
}
func chkEq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got == want { pass += 1 } else { fail += 1; print("FAIL: \(name) — got \(got), want \(want)") }
}

// MARK: translator pack (the machine definition, as data)
let packPath: String? = {
    if CommandLine.arguments.count > 2 { return CommandLine.arguments[2] }
    for candidate in ["build/translator-pack-iphone11.json",
                      "../build/translator-pack-iphone11.json",
                      "../../build/translator-pack-iphone11.json",
                      "translator-pack-iphone11.json"] {
        if FileManager.default.fileExists(atPath: candidate) { return candidate }
    }
    return nil
}()
guard let packPath, let packData = FileManager.default.contents(atPath: packPath),
      let pack = try? TranslatorPack.load(packData) else {
    print("FAIL: translator pack not found/loadable (pass its path as argv[2])")
    exit(2)
}
let def = pack.machineDefinition
let dramBase = pack.dramBase
print("translator pack: \(pack.displayName) from \(packPath)")
chkEq("pack DRAM base", pack.dramBase, 0x800000000)
chkEq("pack kernel phys base", pack.kernelPhysBase, 0x801004000)
chkEq("pack kernel virt base", pack.kernelVirtBase, 0xFFFFFFF007004000)
chkEq("pack UART base", pack.uartBase, 0x235200000)
chkEq("pack CPU count", pack.cpus.list.count, 6)
chkEq("pack boot CPU state", pack.cpus.list[0].state, "running")

func wordsMachine(_ words: [UInt32]) -> Machine {
    let m = Machine(onUart: { _ in }, onLog: { _ in }, definition: def)
    var bytes = [UInt8]()
    for w in words { bytes += [UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF), UInt8((w >> 16) & 0xFF), UInt8((w >> 24) & 0xFF)] }
    m.loadBytes(dramBase, bytes)
    m.pc = dramBase
    return m
}

// MARK: keytest
do {
    let m = wordsMachine([0xd5384240, 0xd53800a1, 0xd53cf082, 0xd4400000])
    m.run(10)
    chkEq("keytest CurrentEL (x0)", m.x[0], 4)
    chkEq("keytest MPIDR (x1)", m.x[1], 0)
    chkEq("keytest S3_4_C15_C0_4 (x2)", m.x[2], 2)
}

// MARK: self-test
do {
    var uart = [UInt8]()
    let m = Machine(onUart: { uart.append($0) }, onLog: { _ in }, definition: def)
    m.loadBytes(dramBase, selfTestProgram)
    m.sp = dramBase + 0x100000
    m.pc = dramBase
    m.run(100000)
    chkEq("self-test UART", String(bytes: uart, encoding: .utf8) ?? "", "test\n55\n")
    chkEq("self-test status", m.status, "halted")
    chkEq("self-test icount", m.icount, 77)
}

// MARK: SDIV reference semantics (unsigned divide of sign-extended patterns)
do {
    let mx = wordsMachine([0x928000A0, 0xD2800041, 0x9AC10C02, 0xD4400000])   // x0=-6, x1=2, sdiv x2
    mx.run(10)
    chkEq("sdiv x -6/2 (reference semantics)", mx.x[2], 0x7FFFFFFFFFFFFFFD)
    let mw = wordsMachine([0x128000A0, 0x52800041, 0x1AC10C02, 0xD4400000])   // w0=-6, w1=2, sdiv w2
    mw.run(10)
    chkEq("sdiv w -6/2 (reference semantics)", mw.x[2], 0xFFFFFFFD)
}

// MARK: SIMD (test_simd.mjs's checks, same program bytes)
do {
    let m = Machine(onUart: { _ in }, onLog: { _ in }, definition: def)
    m.loadBytes(0x800010000, testSimdProgram)
    m.pc = 0x800010000
    m.run(100000)
    func bytesAt(_ addr: Int, _ n: Int) -> [UInt8] {
        (0..<n).map { UInt8(m.readPhys(UInt64(addr + $0), 1) & 0xFF) }
    }
    let R = 0x800020000
    chkEq("simd halted with wfi", m.status, "wfi")
    chkEq("simd icount", m.icount, 94)
    chkEq("movi 2d #0", bytesAt(R + 0x00, 16), [UInt8](repeating: 0, count: 16))
    chkEq("movi 16b #0x41", bytesAt(R + 0x10, 16), [UInt8](repeating: 0x41, count: 16))
    chkEq("movi 4s #1 lsl8", bytesAt(R + 0x20, 16), (0..<16).map { [0, 1, 0, 0][$0 % 4] as UInt8 })
    chkEq("mvni 4s #0", bytesAt(R + 0x30, 16), [UInt8](repeating: 0xFF, count: 16))
    chkEq("movi 8h #0xff", bytesAt(R + 0x40, 16), (0..<16).map { $0 % 2 == 0 ? 0xFF : 0 as UInt8 })
    let A = (0..<16).map { UInt8($0) }, B = (0..<16).map { UInt8(16 + $0) }
    chkEq("add 16b", bytesAt(R + 0x50, 16), (0..<16).map { (A[$0] &+ B[$0]) })
    chkEq("sub 16b", bytesAt(R + 0x60, 16), (0..<16).map { (B[$0] &- A[$0]) })
    chkEq("and 16b", bytesAt(R + 0x70, 16), (0..<16).map { A[$0] & B[$0] })
    chkEq("orr 16b", bytesAt(R + 0x80, 16), (0..<16).map { A[$0] | B[$0] })
    chkEq("eor 16b", bytesAt(R + 0x90, 16), (0..<16).map { A[$0] ^ B[$0] })
    let CONST: UInt64 = 0xDEADBEEF12345678
    chkEq("fmov d + str d", bytesAt(R + 0xa0, 8), (0..<8).map { UInt8((CONST >> ($0 * 8)) & 0xFF) })
    chkEq("fmov x9, d13", m.x[9], CONST)
    chkEq("dup 16b", bytesAt(R + 0xb0, 16), [UInt8](repeating: 0xAB, count: 16))
    chkEq("ins b[3]", bytesAt(R + 0xc0, 16), (0..<16).map { $0 == 3 ? 0xCD : 0 as UInt8 })
    chkEq("umov w11", m.x[11], 0xCD)
    chkEq("ldp q1 restore", bytesAt(R + 0xd0, 16), [UInt8](repeating: 0x41, count: 16))
    chkEq("ldp q2 restore", bytesAt(R + 0xe0, 16), (0..<16).map { [0, 1, 0, 0][$0 % 4] as UInt8 })
    chkEq("sp restored", m.sp, 0x800030000)
    chkEq("ldnp x2", m.x[2], 0x1111111111111111)
    chkEq("ldnp x3", m.x[3], 0x2222222222222222)
    var rb: UInt64 = 0
    let s: UInt64 = 0x1111111111111111
    for i in 0..<64 { if (s >> i) & 1 == 1 { rb |= UInt64(1) << (63 - i) } }
    chkEq("rbit x12", m.x[12], rb)
    chkEq("clz x13", m.x[13], 51)
    chkEq("rev x14", m.x[14], 0x1111111111111111)
    chkEq("retaa sub returned, x16", m.x[16], 0x1234)
    chkEq("stur q", bytesAt(R + 0xf0, 16), [UInt8](repeating: 0x5A, count: 16))
    chkEq("ldur q", bytesAt(R + 0x110, 16), [UInt8](repeating: 0x5A, count: 16))
    chkEq("str s", bytesAt(R + 0x120, 4), [0xDD, 0xCC, 0xBB, 0xAA] as [UInt8])
    chkEq("ldr s round trip", bytesAt(R + 0x124, 4), [0xDD, 0xCC, 0xBB, 0xAA] as [UInt8])
    chkEq("movi 2d #ff", bytesAt(R + 0x130, 16), [UInt8](repeating: 0xFF, count: 16))
}

// MARK: MUL (test_mul.mjs's checks, same program bytes)
do {
    let m = Machine(onUart: { _ in }, onLog: { _ in }, definition: def)
    m.loadBytes(0x800010000, testMulProgram)
    m.pc = 0x800010000
    m.run(100000)
    func bytesAt(_ addr: Int, _ n: Int) -> [UInt8] {
        (0..<n).map { UInt8(m.readPhys(UInt64(addr + $0), 1) & 0xFF) }
    }
    let R = 0x800020000
    chkEq("mul status wfi", m.status, "wfi")
    chkEq("smull", m.x[10], 0xFFFFFFFFFFFFFFEB)
    chkEq("smaddl", m.x[11], 79)
    chkEq("smsubl", m.x[12], 121)
    chkEq("smulh pos", m.x[13], 1)
    chkEq("smulh neg", m.x[14], 0xFFFFFFFFFFFFFFFF)
    chkEq("umull", m.x[15], 0xFFFFFFFE00000001)
    chkEq("umaddl", m.x[16], 0xFFFFFFFE00000006)
    chkEq("umsubl", m.x[17], 0xFFFFFFFFFFFFFFFE)
    chkEq("umulh", m.x[18], 0xFFFFFFFFFFFFFFFE)
    chkEq("x5 sentinel (ldr literal did not touch GPR)", m.x[5], 0x777)
    chkEq("ldr q literal bytes", bytesAt(R, 16), (0..<16).map { UInt8($0) })
    chkEq("ldr d literal bytes", bytesAt(R + 16, 8), [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11] as [UInt8])
    chkEq("ldr s literal bytes", bytesAt(R + 24, 4), [0xbe, 0xba, 0xfe, 0xca] as [UInt8])
}

// MARK: ADT
chkEq("ADT length", buildADT(pack).count, 2740)

// MARK: kernel boot parity (needs the kernelcache path)
if CommandLine.arguments.count > 1 {
    let path = CommandLine.arguments[1]
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let core = FakeDeviceCoreMachine()
    var logs = [String]()
    core.onLog = { logs.append($0) }
    do {
        try core.loadTranslatorPack(packData)
        chkEq("adapter reports pack name", core.translatorPackName, pack.displayName)
        try core.boot(kernelData: data)
        chk("boot chain completed", true)
        chk("boot log names BootROM stage", logs.contains { $0.hasPrefix("BootROM:") })
        let m = core.machine
        m.run(17_000_000)
        chkEq("icount before final approach", m.icount, 17_000_000)
        var guardSteps = 0
        while m.exceptions == 0 && guardSteps < 2_000_000 { _ = m.step(); guardSteps += 1 }
        chkEq("first exception delivered at icount", m.icount, 17_723_144)
        chkEq("exceptions after delivery", m.exceptions, 1)
        chkEq("ESR_EL1", m.sysregValue(3, 0, 5, 2, 0), 0x2000000)
        chkEq("FAR_EL1", m.sysregValue(3, 0, 6, 0, 0), 0)
        chkEq("ELR_EL1", m.sysregValue(3, 0, 4, 0, 1), 0xFFFFFFF007A9AFD8)
        chkEq("SPSR_EL1", m.sysregValue(3, 0, 4, 0, 0), 0x600003C5)
        chkEq("PC after delivery (VBAR+0x200)", m.pc, 0xFFFFFFF0081B9200)
        chkEq("lastException text", m.lastException, "undefined instruction, ELR 0xfffffff007a9afd8 -> vector 0xfffffff0081b9200")
        // step on until the kernel parks itself in its own hang loop
        var parkSteps = 0
        while m.pc != 0xFFFFFFF0081BA410 && parkSteps < 1_000_000 { _ = m.step(); parkSteps += 1 }
        chkEq("parked PC", m.pc, 0xFFFFFFF0081BA410)
        chkEq("icount at park", m.icount, 17_723_155)
        chkEq("parked SP", m.sp, 0xFFFFFFF009C03D20)
        let pcAtPark = m.pc
        m.run(2_000_000)
        chk("kernel stays parked (PC unmoved over 2M more)", m.pc == pcAtPark)
        chkEq("exceptions total", m.exceptions, 1)
        chk("MMU on at park", m.mmuOn)
        chkEq("status at park", m.status, "ready")
        // backdoor smoke on the booted machine
        let regs = core.backdoor("regs")
        chk("backdoor regs answers", regs.contains("X0 = 0x"))
        let peek = core.backdoor("peekp 801004000 10")
        chk("backdoor peekp sees Mach-O magic", peek.contains("cf fa ed fe"))
        let st = core.backdoor("status")
        chk("backdoor status answers", st.contains("parked") || st.contains("ready") || st.contains("instructions:"))
    } catch {
        chk("boot chain completed (\(error.localizedDescription))", false)
    }
} else {
    print("note: no kernelcache path argument — kernel boot parity checks skipped")
}

// MARK: inflate (PuffInflate — the fetcher's DEFLATE decoder)
runInflateTests()

print("fakedevice-check: \(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)

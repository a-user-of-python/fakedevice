// FakeDeviceCoreMachine.swift — FakeDeviceCore
//
// The EmulatorCore conformance: wraps the Swift Machine + boot chain +
// backdoor behind the protocol the SwiftUI app talks to. Threading
// matches the contract: the view model calls everything from its
// emulator queue; onUART/onLog fire on that same queue.

import Foundation

public final class FakeDeviceCoreMachine: EmulatorCore {
    public var onUART: ((UInt8) -> Void)?
    public var onLog: ((String) -> Void)?

    public let machine: Machine

    public init() {
        machine = Machine(onUart: { _ in }, onLog: { _ in })
        machine.onUart = { [weak self] b in self?.onUART?(b) }
        machine.onLog = { [weak self] line in self?.onLog?(line) }
    }

    public func boot(kernelData: Data) throws {
        machine.reset()
        _ = try bootKernel(machine, [UInt8](kernelData)) { [weak self] line in
            self?.onLog?(line)
        }
    }

    /// The built-in self-test, loaded exactly the way the reference's
    /// test harness loads it (program at DRAM_BASE, SP one megabyte in).
    public func runSelfTest() throws {
        machine.reset()
        machine.loadBytes(DRAM_BASE, selfTestProgram)
        machine.sp = DRAM_BASE + 0x100000
        machine.pc = DRAM_BASE
    }

    @discardableResult
    public func runChunk(_ maxInstructions: Int) -> EmulatorStatus {
        machine.run(maxInstructions)
        return status()
    }

    public func status() -> EmulatorStatus {
        var s = EmulatorStatus()
        s.status = machine.status
        s.icount = UInt64(machine.icount)
        s.pc = machine.pc
        s.sp = machine.sp
        s.mmuOn = machine.mmuOn
        s.exceptions = UInt64(machine.exceptions)
        s.lastException = machine.lastException
        s.trapInfo = machine.trapInfo
        return s
    }

    public func backdoor(_ line: String) -> String {
        Backdoor.run(machine, line)
    }

    public func reset() {
        machine.reset()
    }
}

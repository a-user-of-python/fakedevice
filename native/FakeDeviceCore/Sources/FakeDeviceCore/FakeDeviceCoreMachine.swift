// FakeDeviceCoreMachine.swift — FakeDeviceCore
//
// The EmulatorCore adapter over the native Swift core. The machine is
// created with an EMPTY definition (nothing is RAM, no UART) and only
// becomes a device when a translator pack is loaded — the app ships
// as a shell + interpreter; the fake hardware arrives as data.
// Threading matches the contract: the view model calls everything
// from its emulator queue; onUART/onLog fire on that same queue.

import Foundation

public final class FakeDeviceCoreMachine: EmulatorCore {
    public var onUART: ((UInt8) -> Void)?
    public var onLog: ((String) -> Void)?

    /// The loaded translator pack, if any.
    public private(set) var pack: TranslatorPack?
    public var translatorPackName: String? { pack?.displayName }

    public private(set) var machine: Machine

    public init() {
        machine = Machine(onUart: { _ in }, onLog: { _ in },
                          definition: MachineDefinition(dramBase: 0, dramSize: 0, uartBase: 0, uartSize: 0,
                                                        uartUtrstat: 0, uartUtxh: 0, uartUrxh: 0))
        wireCallbacks()
    }

    private func wireCallbacks() {
        machine.onUart = { [weak self] byte in self?.onUART?(byte) }
        machine.onLog = { [weak self] line in self?.onLog?(line) }
    }

    public func loadTranslatorPack(_ data: Data) throws {
        let loaded = try TranslatorPack.load(data)
        pack = loaded
        machine = Machine(onUart: { _ in }, onLog: { _ in }, definition: loaded.machineDefinition)
        wireCallbacks()
        onLog?("Translator pack loaded: \(loaded.displayName) — \(loaded.machine), \(loaded.socName)")
    }

    private func requirePack() throws -> TranslatorPack {
        guard let pack else {
            throw BootError("No translator pack loaded — import a translator pack first (the app ships without a machine definition).")
        }
        return pack
    }

    public func boot(kernelData: Data) throws {
        let pack = try requirePack()
        machine.reset()
        _ = try bootKernel(machine, [UInt8](kernelData), pack) { [weak self] line in self?.onLog?(line) }
    }

    public func runSelfTest() throws {
        let pack = try requirePack()
        machine.reset()
        let base = pack.dramBase
        machine.loadBytes(base, selfTestProgram)
        machine.sp = base &+ 0x100000
        machine.pc = base
    }

    public func runChunk(_ maxInstructions: Int) -> EmulatorStatus {
        _ = machine.run(maxInstructions)
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

    public func backdoor(_ command: String) -> String {
        Backdoor.run(machine, command)
    }

    public func reset() {
        machine.reset()
    }
}

// TranslatorPack.swift — FakeDeviceCore
//
// A translator pack is a DATA file (JSON) defining one machine: the
// complete t8030 definition the core runs against. The schema is owned
// by the reference implementation — see build/PACK.md next to
// translator-pack-iphone11.json; this struct mirrors that schema field
// for field. The apps ship as a shell + this interpreter and contain
// no machine constants of their own. All 64-bit addresses/sizes are
// hex strings in the JSON: JSON numbers cannot hold them exactly.

import Foundation

public struct TranslatorPack: Codable {
    public var packVersion: Int
    public var machine: String
    public var machineName: String
    public var soc: String
    public var socName: String
    public var description: String
    public var memory: Memory
    public var bootLayout: BootLayout
    public var uart: Uart
    public var armIo: ArmIo
    public var cpus: Cpus
    public var deviceTree: DeviceTree
    public var bootArgs: BootArgs
    public var aic: Aic
    public var timer: Timer
    public var defaults: Defaults
    public var lockRegs: LockRegs

    public struct Memory: Codable {
        public var dramBase: String
        public var memSize: String
        public var kernelPhysBase: String
        public var kernelVirtBase: String
        public var pageSize: String
    }
    public struct BootLayout: Codable {
        public var bootArgsOffsetFromKernelTop: String
        public var adtOffsetFromBootArgs: String
    }
    public struct Uart: Codable {
        public var name: String
        public var base: String
        public var size: String
        public var compatible: String
        public var interrupts: [UInt32]
        public var phandle: UInt32
        public var registers: Registers
        public struct Registers: Codable { public var utrstat: String; public var utxh: String; public var urxh: String }
    }
    public struct ArmIo: Codable {
        public var name: String
        public var compatible: String
        public var deviceType: String
        public var addressCells: UInt32
        public var sizeCells: UInt32
        public var regAddress: String
        public var regSize: String
        public var ranges: [Range]
        public var phandle: UInt32
        public var interruptParent: UInt32
        public struct Range: Codable {
            public var childAddress: String
            public var parentAddress: String
            public var size: String
        }
    }
    // The interrupt controller under arm-io (stage-5 frontier 21): PE's
    // pe_arm_map_interrupt_controller looks up a node whose
    // "interrupt-controller" property reads "master", and IOKit's DT
    // interrupt resolution follows arm-io's interrupt-parent phandle to
    // this node. "reg" is an offset within arm-io, like the uart's.
    public struct Aic: Codable {
        public var name: String
        public var compatible: String
        public var deviceType: String
        public var regOffset: String
        public var regSize: String
        public var interruptControllerValue: String
        public var interruptCells: UInt32
        public var aicVersion: UInt32
        public var phandle: UInt32
    }
    // The "timer" device PE maps alongside the interrupt controller
    // (stage-5 frontier 21); also a child of arm-io, reg as an offset.
    public struct Timer: Codable {
        public var name: String
        public var compatible: String
        public var deviceType: String
        public var regOffset: String
        public var regSize: String
        public var phandle: UInt32
    }
    // The root-level "defaults" node (stage-5 frontier 22): its
    // serial-device property (built in Boot.swift) carries the console
    // UART's phandle.
    public struct Defaults: Codable {
        public var name: String
    }
    public struct LockRegs: Codable {
        public var name: String
        public var amcc: Amcc
        public var ctrrA: CtrrA
        public struct Reg: Codable {
            public var name: String
            public var offset: UInt32
            public var mask: UInt32
            public var value: UInt32?
        }
        public struct Amcc: Codable {
            public var name: String
            public var apertureCount: UInt32
            public var apertureSize: String
            public var planeCount: UInt32
            public var planeStride: UInt32
            public var aperturePhysAddr: [String]
            public var cacheStatus: UInt32
            public var regs: [Reg]
        }
        public struct CtrrA: Codable {
            public var name: String
            public var pageSizeShift: UInt32
            public var lowerLimit: String
            public var upperLimit: String
            public var lock: UInt32
            public var enable: UInt32
            public var writeDisable: UInt32
            public var regs: [Reg]
        }
    }
    public struct Cpus: Codable {
        public var name: String
        public var addressCells: UInt32
        public var sizeCells: UInt32
        public var deviceType: String
        public var list: [Cpu]
        public struct Cpu: Codable {
            public var name: String
            public var reg: UInt32
            public var compatible: String
            public var clusterType: UInt32
            public var clusterName: String
            public var state: String
        }
    }
    public struct DeviceTree: Codable {
        public var rootName: String
        public var rootCompatible: String
        public var model: String
        public var rootAddressCells: UInt32
        public var rootSizeCells: UInt32
        public var memoryNodeName: String
        public var chosenNodeName: String
        public var randomSeedHex: String
    }
    public struct BootArgs: Codable {
        public var revision: Int
        public var version: Int
        public var structSize: Int
        public var machineType: UInt32
        public var commandLine: String
        public var bootFlags: String
        public var layout: Layout
        public struct Layout: Codable {
            public var revision: Int
            public var version: Int
            public var virtBase: Int
            public var physBase: Int
            public var memSize: Int
            public var topOfKernelData: Int
            public var video: Int
            public var machineType: Int
            public var deviceTreeP: Int
            public var deviceTreeLength: Int
            public var commandLine: Int
            public var bootFlags: Int
            public var memSizeActual: Int
        }
    }

    public static func load(_ data: Data) throws -> TranslatorPack {
        let pack: TranslatorPack
        do {
            pack = try JSONDecoder().decode(TranslatorPack.self, from: data)
        } catch {
            throw BootError("translator pack is not valid pack JSON: \(error.localizedDescription)")
        }
        guard pack.packVersion == 1 else {
            throw BootError("translator pack version \(pack.packVersion) is not understood (this build reads packVersion 1)")
        }
        // Validate every hex field the core dereferences, so a malformed
        // pack fails at import time, not mid-boot.
        let hexFields = [pack.memory.dramBase, pack.memory.memSize, pack.memory.kernelPhysBase,
                         pack.memory.kernelVirtBase, pack.memory.pageSize,
                         pack.bootLayout.bootArgsOffsetFromKernelTop, pack.bootLayout.adtOffsetFromBootArgs,
                         pack.uart.base, pack.uart.size, pack.uart.registers.utrstat,
                         pack.uart.registers.utxh, pack.uart.registers.urxh,
                         pack.armIo.regAddress, pack.armIo.regSize, pack.bootArgs.bootFlags]
            + pack.armIo.ranges.flatMap { [$0.childAddress, $0.parentAddress, $0.size] }
            + [pack.aic.regOffset, pack.aic.regSize, pack.timer.regOffset, pack.timer.regSize]
            + [pack.lockRegs.amcc.apertureSize, pack.lockRegs.ctrrA.lowerLimit, pack.lockRegs.ctrrA.upperLimit]
            + pack.lockRegs.amcc.aperturePhysAddr
        for hex in hexFields where TranslatorPack.parseHex(hex) == nil {
            throw BootError("translator pack has a bad hex value: \(hex)")
        }
        guard pack.randomSeed.count == 64 else {
            throw BootError("translator pack deviceTree.randomSeedHex must decode to 64 bytes")
        }
        return pack
    }

    static func parseHex(_ s: String) -> UInt64? {
        var t = s
        if t.lowercased().hasPrefix("0x") { t = String(t.dropFirst(2)) }
        return UInt64(t, radix: 16)
    }
    static func hex(_ s: String) -> UInt64 { parseHex(s) ?? 0 }

    // MARK: Parsed values
    public var dramBase: UInt64 { Self.hex(memory.dramBase) }
    public var dramSize: UInt64 { Self.hex(memory.memSize) }
    public var kernelPhysBase: UInt64 { Self.hex(memory.kernelPhysBase) }
    public var kernelVirtBase: UInt64 { Self.hex(memory.kernelVirtBase) }
    public var pageSize: UInt64 { Self.hex(memory.pageSize) }
    public var uartBase: UInt64 { Self.hex(uart.base) }
    public var uartSize: UInt64 { Self.hex(uart.size) }
    public var displayName: String { "\(machineName) (\(soc))" }
    public var randomSeed: [UInt8] {
        let hex = deviceTree.randomSeedHex
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if j == hex.index(after: i) { break }
            guard let b = UInt8(hex[i..<j], radix: 16) else { break }
            out.append(b)
            i = j
        }
        return out
    }

    /// The subset of the pack the interpreter core itself consults.
    public var machineDefinition: MachineDefinition {
        MachineDefinition(dramBase: dramBase, dramSize: dramSize,
                          uartBase: uartBase, uartSize: uartSize,
                          uartUtrstat: Self.hex(uart.registers.utrstat),
                          uartUtxh: Self.hex(uart.registers.utxh),
                          uartUrxh: Self.hex(uart.registers.urxh))
    }
}

/// The machine definition the interpreter runs against — loaded from a
/// translator pack, never compiled in.
public struct MachineDefinition {
    public var dramBase: UInt64
    public var dramSize: UInt64
    public var uartBase: UInt64
    public var uartSize: UInt64
    public var uartUtrstat: UInt64
    public var uartUtxh: UInt64
    public var uartUrxh: UInt64
    public init(dramBase: UInt64, dramSize: UInt64, uartBase: UInt64, uartSize: UInt64,
                uartUtrstat: UInt64, uartUtxh: UInt64, uartUrxh: UInt64) {
        self.dramBase = dramBase; self.dramSize = dramSize
        self.uartBase = uartBase; self.uartSize = uartSize
        self.uartUtrstat = uartUtrstat; self.uartUtxh = uartUtxh; self.uartUrxh = uartUrxh
    }
    public var dramEnd: UInt64 { dramBase &+ dramSize }
}

import Foundation

/// Status snapshot of the emulated machine, mirroring what the web page's
/// status pane shows (stage 4: status, instruction count, PC/SP, MMU,
/// exceptions delivered, last exception, stop reason).
public struct EmulatorStatus: Equatable {
    public var status: String = "idle"          // ready | halted | trap | undefined | wfi | breakpoint | idle
    public var icount: UInt64 = 0
    public var pc: UInt64 = 0
    public var sp: UInt64 = 0
    public var mmuOn: Bool = false
    public var exceptions: UInt64 = 0
    public var lastException: String = ""
    public var trapInfo: String = ""

    public init() {}

    public var pcHex: String { "0x" + String(pc, radix: 16) }
    public var spHex: String { "0x" + String(sp, radix: 16) }
}

/// The contract the native Swift core (FakeDeviceCore, ported from the
/// canonical emu.js / boot.js) conforms to. The iPad UI talks only to this
/// protocol, so the core can evolve without touching the views.
///
/// Threading: all methods are called from the view model's emulator queue,
/// never from the main thread. `onUART` / `onLog` fire on that same queue.
public protocol EmulatorCore: AnyObject {
    var onUART: ((UInt8) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }

    /// Load a translator pack (the machine definition, as data). The
    /// app ships as a shell + interpreter with no machine definition
    /// baked in; boot and the self-test refuse until a pack is loaded.
    func loadTranslatorPack(_ data: Data) throws

    /// Name of the loaded translator pack, if any.
    var translatorPackName: String? { get }

    /// Run the fake boot chain (BootROM -> LLB -> iBoot) and load the given
    /// kernelcache bytes. Throws with a human-readable message on failure.
    func boot(kernelData: Data) throws

    /// Load and run the built-in self-test program (no kernel file needed).
    func runSelfTest() throws

    /// Execute up to `maxInstructions` instructions (the web page uses
    /// 2,000,000 per chunk) and return the resulting status.
    @discardableResult
    func runChunk(_ maxInstructions: Int) -> EmulatorStatus

    /// Current status without executing anything.
    func status() -> EmulatorStatus

    /// Run one backdoor console command (help, regs, peek, poke, bp, step,
    /// run, patch, uartin, ... — same set as the web page) and return the
    /// text it prints.
    func backdoor(_ line: String) -> String

    /// Reset the machine to a blank state.
    func reset()
}

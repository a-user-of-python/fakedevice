import Foundation
import SwiftUI

/// Drives the emulator core the same way the web page does: run in
/// 2,000,000-instruction chunks, publish status after each chunk, and treat
/// "PC did not move for a whole chunk while still ready" as the kernel
/// having parked itself in its own hang loop (stage 4 behaviour).
@MainActor
final class EmulatorViewModel: ObservableObject {
    // Published UI state
    @Published var logText: String = ""
    @Published var uartText: String = ""
    @Published var consoleText: String = "Backdoor ready. Type \"help\" and press Run.\nAll numbers are hex. peek/poke go through the kernel's page tables; peekp/pokep touch raw physical memory.\n"
    @Published var status = EmulatorStatus()
    @Published var isRunning: Bool = false
    @Published var kernels: [KernelFile] = []
    @Published var selectedKernelID: KernelFile.ID?
    @Published var packs: [PackFile] = []
    @Published var selectedPackID: PackFile.ID?
    /// Display name of the pack the core has actually loaded, if any.
    @Published var loadedPackName: String?

    let core: EmulatorCore
    private let emuQueue = DispatchQueue(label: "fakedevice.emulator")
    private var runGeneration: Int = 0

    private static let textCap = 120_000

    struct KernelFile: Identifiable, Equatable {
        let url: URL
        var id: URL { url }
        var name: String { url.lastPathComponent }
        var sizeText: String {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    /// A translator pack in the library: a JSON file holding the whole
    /// machine definition (memory map, UART, CPU topology, device tree,
    /// boot_args layout) as data. The app ships without one — everything
    /// about the fake hardware arrives in this file.
    struct PackFile: Identifiable, Equatable {
        let url: URL
        var id: URL { url }
        var name: String { url.lastPathComponent }
        var sizeText: String {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    init(core: EmulatorCore) {
        self.core = core
        core.onUART = { [weak self] byte in
            self?.appendUART(byte)
        }
        core.onLog = { [weak self] line in
            self?.appendLog(line)
        }
        refreshKernels()
    }

    // MARK: - Kernel library (Documents folder)

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// One Documents scan feeds both libraries: `.json` files are
    /// translator packs, everything else is a kernel image.
    func refreshKernels() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.documentsURL,
                                                includingPropertiesForKeys: nil)) ?? []
        let visible = urls
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        packs = visible
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { PackFile(url: $0) }
        kernels = visible
            .filter { $0.pathExtension.lowercased() != "json" }
            .map { KernelFile(url: $0) }
        if selectedKernelID == nil { selectedKernelID = kernels.first?.id }
        if selectedPackID == nil { selectedPackID = packs.first?.id }
        if loadedPackName == nil, let pack = selectedPack { applyPack(pack) }
    }

    /// Copy a picked file into Documents so it shows in the in-app list and
    /// in Files (file sharing is enabled for this app).
    func importKernel(from picked: URL) {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let dest = Self.documentsURL.appendingPathComponent(picked.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: picked, to: dest)
            refreshKernels()
            selectedKernelID = dest
            appendConsole("Imported \(picked.lastPathComponent) into the app Documents folder.")
        } catch {
            appendConsole("Import failed: \(error.localizedDescription)")
        }
    }

    func deleteKernel(_ file: KernelFile) {
        try? FileManager.default.removeItem(at: file.url)
        if selectedKernelID == file.id { selectedKernelID = nil }
        refreshKernels()
    }

    var selectedKernel: KernelFile? {
        kernels.first { $0.id == selectedKernelID }
    }

    // MARK: - Translator pack library

    func importPack(from picked: URL) {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let dest = Self.documentsURL.appendingPathComponent(picked.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: picked, to: dest)
            refreshKernels()
            selectPack(PackFile(url: dest))
            appendConsole("Imported translator pack \(picked.lastPathComponent) into the app Documents folder.")
        } catch {
            appendConsole("Pack import failed: \(error.localizedDescription)")
        }
    }

    func deletePack(_ file: PackFile) {
        try? FileManager.default.removeItem(at: file.url)
        if selectedPackID == file.id {
            selectedPackID = nil
            loadedPackName = nil
        }
        refreshKernels()
    }

    var selectedPack: PackFile? {
        packs.first { $0.id == selectedPackID }
    }

    /// Select a pack and hand it to the core (on the emulator queue).
    func selectPack(_ file: PackFile) {
        selectedPackID = file.id
        applyPack(file)
    }

    private func applyPack(_ file: PackFile) {
        emuQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: file.url)
                try self.core.loadTranslatorPack(data)
                let name = self.core.translatorPackName
                DispatchQueue.main.async { self.loadedPackName = name }
            } catch {
                self.appendConsole("Translator pack failed to load: \(error.localizedDescription)")
            }
        }
    }

    /// Load the selected pack into the core. Call on the emulator queue
    /// before boot / self-test so the core always runs the pack the UI
    /// shows as selected. Throws a user-readable error if none is picked.
    private func loadSelectedPackOnQueue() throws {
        guard let file = selectedPack else {
            throw NSError(domain: "FakeDevice", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No translator pack selected — import a translator pack (e.g. translator-pack-iphone11.json) first. The app ships without a machine definition; the pack is the fake hardware, as data."])
        }
        let data = try Data(contentsOf: file.url)
        try core.loadTranslatorPack(data)
        let name = core.translatorPackName
        DispatchQueue.main.async { [weak self] in self?.loadedPackName = name }
    }

    // MARK: - Controls

    func runSelfTest() {
        stop()
        uartText = ""
        logText = ""
        emuQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.loadSelectedPackOnQueue()
                try self.core.runSelfTest()
                self.publishStatus(self.core.status())
                self.startLoop()
            } catch {
                self.appendConsole("Self-test failed: \(error.localizedDescription)")
            }
        }
    }

    func bootSelectedKernel() {
        guard let file = selectedKernel else {
            appendConsole("Pick a kernel file first (import kernelcache.raw if the list is empty).")
            return
        }
        stop()
        uartText = ""
        logText = ""
        emuQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.loadSelectedPackOnQueue()
                let data = try Data(contentsOf: file.url)
                try self.core.boot(kernelData: data)
                self.appendLog("[app] boot chain finished — kernel running.")
                self.publishStatus(self.core.status())
                self.startLoop()
            } catch {
                self.appendConsole("Boot failed: \(error.localizedDescription)")
            }
        }
    }

    func pause() { stop() }

    private func startLoop() {
        runGeneration += 1
        let generation = runGeneration
        DispatchQueue.main.async { self.isRunning = true }
        tick(generation: generation)
    }

    private func tick(generation: Int) {
        emuQueue.async { [weak self] in
            guard let self, generation == self.runGeneration else { return }
            let pcBefore = self.core.status().pc
            let st = self.core.runChunk(2_000_000)
            self.publishStatus(st)
            if st.status == "ready" && st.pc == pcBefore {
                self.appendConsole("Kernel parked — PC has not moved for a whole run chunk (\(st.pcHex)). The kernel is sitting in its own hang loop; that's its doing, not the emulator stopping it.")
                DispatchQueue.main.async { self.isRunning = false }
                return
            }
            if st.status == "ready" {
                self.emuQueue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    self?.tick(generation: generation)
                }
            } else {
                self.appendConsole("Machine stopped: \(st.status)\(st.trapInfo.isEmpty ? "" : " — \(st.trapInfo)")")
                DispatchQueue.main.async { self.isRunning = false }
            }
        }
    }

    private func stop() {
        runGeneration += 1
        isRunning = false
    }

    // MARK: - Backdoor console

    func runBackdoor(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendConsole("> " + trimmed)
        emuQueue.async { [weak self] in
            guard let self else { return }
            let out = self.core.backdoor(trimmed)
            if !out.isEmpty { self.appendConsole(out) }
            self.publishStatus(self.core.status())
        }
    }

    // MARK: - Text plumbing (callbacks arrive on the emulator queue)

    private func appendUART(_ byte: UInt8) {
        let ch = String(UnicodeScalar(byte))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.uartText += ch
            if self.uartText.count > Self.textCap {
                self.uartText = String(self.uartText.suffix(Self.textCap))
            }
        }
    }

    private func appendLog(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logText += line + "\n"
            if self.logText.count > Self.textCap {
                self.logText = String(self.logText.suffix(Self.textCap))
            }
        }
    }

    func appendConsole(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.consoleText += line + "\n"
            if self.consoleText.count > Self.textCap {
                self.consoleText = String(self.consoleText.suffix(Self.textCap))
            }
        }
    }

    private func publishStatus(_ st: EmulatorStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.status = st
        }
    }
}

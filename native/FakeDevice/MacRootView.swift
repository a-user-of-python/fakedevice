import SwiftUI
import UniformTypeIdentifiers

/// FakeDevice on macOS: control column (kernel library / controls /
/// status) on the left, machine log + serial + backdoor panes on the
/// right. Same view model and core contract as the iPad layout.
/// High contrast, low clutter, natural text sizes throughout.
struct MacRootView: View {
    @StateObject private var vm: EmulatorViewModel
    @State private var consoleInput: String = ""
    @State private var importing: Bool = false
    @State private var importingPack: Bool = false

    init(core: EmulatorCore) {
        _vm = StateObject(wrappedValue: EmulatorViewModel(core: core))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                packCard
                libraryCard
                controlsCard
                statusCard
                Spacer(minLength: 0)
            }
            .frame(width: 350)

            VStack(spacing: 12) {
                pane(title: "Machine log", text: vm.logText, tint: .white)
                    .frame(maxHeight: .infinity)
                pane(title: "Serial output (UART)", text: vm.uartText, tint: Color(red: 0.62, green: 0.91, blue: 0.66))
                    .frame(height: 150)
                consolePane
                    .frame(height: 210)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.importKernel(from: url)
            }
        }
        .fileImporter(isPresented: $importingPack,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.importPack(from: url)
            }
        }
        .onAppear { vm.refreshKernels() }
    }

    // MARK: - Cards

    private var packCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Translator pack").font(.headline)
                Spacer()
                Button("Import") { importingPack = true }
            }
            if vm.packs.isEmpty {
                Text("No translator pack yet. Import translator-pack-iphone11.json — the app ships without a machine definition; the pack is the fake hardware (memory map, UART, CPUs, device tree), as data.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(vm.packs) { file in
                        Button {
                            vm.selectPack(file)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name).font(.callout).lineLimit(1)
                                    Text(file.sizeText).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if vm.selectedPackID == file.id {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) { vm.deletePack(file) }
                        }
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 44)
                if let loaded = vm.loadedPackName {
                    Text("Loaded: \(loaded)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .glassCard()
    }

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Kernel files").font(.headline)
                Spacer()
                Button("Import") { importing = true }
            }
            if vm.kernels.isEmpty {
                Text("No kernel files yet. Import kernelcache.raw (iOS 14.8, iPhone 11) — it is copied into this app's Documents folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(vm.kernels) { file in
                        Button {
                            vm.selectedKernelID = file.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name).font(.callout).lineLimit(1)
                                    Text(file.sizeText).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if vm.selectedKernelID == file.id {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) { vm.deleteKernel(file) }
                        }
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 60)
            }
        }
        .padding(12)
        .glassCard()
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FakeDevice").font(.title2.bold())
            Text("A fake device running a real XNU kernel, interpreted natively on this Mac. The machine itself comes from the translator pack above.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Run self-test") { vm.runSelfTest() }
                    .buttonStyle(.bordered)
                Button("Boot kernel") { vm.bootSelectedKernel() }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.selectedKernel == nil || vm.selectedPack == nil)
                Button("Pause") { vm.pause() }
                    .buttonStyle(.bordered)
                    .disabled(!vm.isRunning)
            }
        }
        .padding(12)
        .glassCard()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status").font(.headline)
            statusRow("State", vm.status.status)
            statusRow("Instructions", vm.status.icount.formatted())
            statusRow("PC", vm.status.pcHex)
            statusRow("SP", vm.status.spHex)
            statusRow("MMU", vm.status.mmuOn ? "ON" : "off")
            statusRow("Exceptions delivered", "\(vm.status.exceptions)")
            if !vm.status.lastException.isEmpty {
                statusRow("Last exception", vm.status.lastException)
            }
            if !vm.status.trapInfo.isEmpty {
                statusRow("Stop reason", vm.status.trapInfo)
            }
        }
        .padding(12)
        .glassCard()
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced()).multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Panes

    private func pane(title: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.footnote.monospaced())
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .glassCard()
    }

    private var consolePane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Backdoor console").font(.headline)
            ScrollView {
                Text(vm.consoleText)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Color(red: 0.79, green: 0.84, blue: 1.0))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                TextField("help", text: $consoleInput)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled(true)
                    .onSubmit { submitConsole() }
                Button("Run") { submitConsole() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .glassCard()
    }

    private func submitConsole() {
        let line = consoleInput
        consoleInput = ""
        vm.runBackdoor(line)
    }
}

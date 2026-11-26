import SwiftUI
import UniformTypeIdentifiers

/// FakeDevice on iPad: full-screen layout for the 11-inch panel
/// (1180x820 pt). Landscape gets a control column + stacked panes;
/// portrait stacks the controls and switches between panes.
/// High contrast, low clutter, natural text sizes throughout.
struct iPadRootView: View {
    @StateObject private var vm: EmulatorViewModel
    @State private var consoleInput: String = ""
    @State private var importing: Bool = false
    @State private var portraitPane: Pane = .log

    enum Pane: String, CaseIterable, Identifiable {
        case log = "Log"
        case serial = "Serial"
        case console = "Backdoor"
        var id: String { rawValue }
    }

    init(core: EmulatorCore) {
        _vm = StateObject(wrappedValue: EmulatorViewModel(core: core))
    }

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= geo.size.height {
                landscape
            } else {
                portrait
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.importKernel(from: url)
            }
        }
        .onAppear { vm.refreshKernels() }
    }

    // MARK: - Landscape (1180x820)

    private var landscape: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                libraryCard
                controlsCard
                statusCard
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
    }

    // MARK: - Portrait

    private var portrait: some View {
        VStack(spacing: 12) {
            controlsCard
            statusCard
            Picker("Pane", selection: $portraitPane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)

            switch portraitPane {
            case .log:
                pane(title: "Machine log", text: vm.logText, tint: .white)
            case .serial:
                pane(title: "Serial output (UART)", text: vm.uartText, tint: Color(red: 0.62, green: 0.91, blue: 0.66))
            case .console:
                consolePane
            }

            libraryCard
                .frame(maxHeight: 220)
        }
        .padding(12)
    }

    // MARK: - Cards

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Kernel files").font(.headline)
                Spacer()
                Button("Import") { importing = true }
            }
            if vm.kernels.isEmpty {
                Text("No kernel files yet. Import kernelcache.raw (iOS 14.8, iPhone 11), or drop it into this app's folder in Files — file sharing is on.")
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
                        .swipeActions {
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
            Text("A fake iPhone (t8030) running the real iOS kernel, interpreted natively on this iPad.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Run self-test") { vm.runSelfTest() }
                    .buttonStyle(.bordered)
                Button("Boot kernel") { vm.bootSelectedKernel() }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.selectedKernel == nil)
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
                    .fdNoAutocapitalization()
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

private extension View {
    /// .textInputAutocapitalization exists only on iOS; this file also
    /// compiles for macOS (same multiplatform target), so route through
    /// a guarded helper.
    @ViewBuilder func fdNoAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}

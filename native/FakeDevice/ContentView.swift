import SwiftUI

/// Platform root: the Mac gets the desktop layout, iPad (and iPhone) the
/// touch layout. Both drive the same EmulatorViewModel and EmulatorCore.
struct ContentView: View {
    let core: EmulatorCore

    var body: some View {
#if os(macOS)
        MacRootView(core: core)
#else
        iPadRootView(core: core)
#endif
    }
}

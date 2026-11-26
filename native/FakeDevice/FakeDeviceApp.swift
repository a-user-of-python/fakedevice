import SwiftUI

/// FakeDevice — a fake iPhone (t8030) that runs the real iOS 14.8
/// kernelcache by interpreting its ARM64 code with a native Swift core
/// (FakeDeviceCore). No JavaScript anywhere in the app.
///
/// Until the FakeDeviceCore port is wired into this target, the app runs
/// on CorePendingPlaceholder, which says so openly in the UI. Swap the
/// placeholder for FakeDeviceCoreMachine() when the core lands.
@main
struct FakeDeviceApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(core: CorePendingPlaceholder())
        }
#if os(macOS)
        .defaultSize(width: 1180, height: 820)
#endif
    }
}

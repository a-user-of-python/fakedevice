import SwiftUI

/// FakeDevice — a fake iPhone (t8030) that runs the real iOS 14.8
/// kernelcache by interpreting its ARM64 code with a native Swift core
/// (FakeDeviceCore). No JavaScript anywhere in the app.
///
/// The core is FakeDeviceCoreMachine (native/FakeDeviceCore), which
/// conforms to the EmulatorCore protocol the views and view model use.
@main
struct FakeDeviceApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(core: FakeDeviceCoreMachine())
        }
#if os(macOS)
        .defaultSize(width: 1180, height: 820)
#endif
    }
}

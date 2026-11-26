// swift-tools-version: 5.9
import PackageDescription

// FakeDeviceCore: the native Swift port of the FakeDevice emulator
// (ARM64 interpreter + page-table walker + fake boot chain + backdoor).
// The SwiftUI app target compiles these same sources directly; this
// package exists so the core builds and is acceptance-checked headlessly
// (fakedevice-check) without Xcode — including on Linux CI.
let package = Package(
    name: "FakeDeviceCore",
    products: [
        .library(name: "FakeDeviceCore", targets: ["FakeDeviceCore"]),
        .executable(name: "fakedevice-check", targets: ["fakedevice-check"]),
    ],
    targets: [
        .target(name: "FakeDeviceCore"),
        .executableTarget(name: "fakedevice-check", dependencies: ["FakeDeviceCore"],
                          resources: [.copy("TestData/deflate-fixture-8m.bin")]),
    ]
)

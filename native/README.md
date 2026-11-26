# FakeDevice — native apps

One SwiftUI app target (`FakeDevice.xcodeproj`, bundle id
`com.user.fakedevice`) serving three lanes from a single multiplatform
target (`SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx`):

- **macOS arm64** — `.github/workflows/build-macos-arm64.yml` builds the
  Mac app for Apple Silicon on a standard `macos-26` runner.
- **macOS x86_64** — sibling lane: adds the Intel build (universal binary)
  on top of this same project.
- **iPadOS** — `.github/workflows/build-ipa.yml` builds the unsigned IPA
  (sideloaded via Signulous) and verifies in the built app: the bundle id,
  both file-sharing keys, and that **no JavaScript emulator files**
  (`emu.js` / `boot.js` / `bridge.js`) are inside the `.app`.

## Rules of the house

- The emulator core is **native Swift** (`FakeDeviceCore`). The native
  apps never run the emulator on JavaScript — no JavaScriptCore, no
  bundled `.js` core, ever. The JavaScript implementation under `../build/`
  is the reference the Swift port mirrors, and it stays a web-only artifact.
- UI is SwiftUI with Liquid Glass where the OS supports it: the shared
  `glassCard()` modifier (`FakeDevice/GlassCard.swift`) uses
  `glassEffect` behind `#available(iOS 26.0, macOS 26.0, *)` and falls
  back to `.regularMaterial`. Deployment targets stay at iOS 17 /
  macOS 14 so those guards are real.
- High contrast, low clutter, natural text sizes (no artificially
  inflated UI).

## Layout

- `FakeDevice/` — the app: `FakeDeviceApp.swift` (entry),
  `ContentView.swift` (picks the platform layout), `MacRootView.swift`,
  `iPadRootView.swift`, `EmulatorViewModel.swift` (chunked run loop,
  Documents kernel library, backdoor plumbing), `EmulatorCore.swift`
  (the `EmulatorCore` protocol + `EmulatorStatus` contract, plus a
  clearly-labelled `CorePendingPlaceholder` used only until the real
  core is wired in), `GlassCard.swift`, `Assets.xcassets`.
- `FakeDeviceCore/` — the Swift port of the emulator (SwiftPM package):
  the ARM64 interpreter, page-table walker, boot chain, and backdoor,
  plus `fakedevice-check`, a headless harness that proves the port
  against the reference implementation's known results. The app target
  compiles the core's sources directly; the package exists so the core
  can be built and checked without Xcode.

## Wiring the core in

`FakeDeviceApp.swift` constructs the core. Until the port landed it used
`CorePendingPlaceholder()`; the real core is `FakeDeviceCoreMachine()`,
which conforms to the same `EmulatorCore` protocol, so the swap is one
line and the views never change.

## macOS x86_64 (Intel) notes

- The Intel lane's CI is `.github/workflows/build-macos-intel.yml`: the
  app is built for x86_64 **natively** on `macos-26-intel` (a standard
  GitHub-hosted runner — 4-core Intel, free on public repos; the larger
  Intel label `macos-26-large` is paid and never used), and a second job
  on `macos-26` builds the universal binary and proves with `lipo` that
  it contains both `arm64` and `x86_64` slices. A third job runs the
  core's `fakedevice-check` harness natively on Intel once the
  FakeDeviceCore package lands.
- The project target sets `ARCHS = "$(ARCHS_STANDARD)"` explicitly, so a
  plain Release build for macOS is universal (arm64 + x86_64); the
  iphoneos SDK still resolves the same setting to arm64 only.
- Performance on Intel: the core is compiled Swift on both
  architectures — there is no JavaScript/JIT layer in the native apps at
  all, so the x86_64 build runs the interpreter as native compiled code,
  with the full app memory headroom a browser tab never gets. The
  interpreter's speed characteristics (a straightforward instruction
  interpreter) are otherwise the same on both architectures.

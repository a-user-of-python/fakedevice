# FakeDevice

A lightweight fake iPhone (t8030, iPhone 11) that runs the **real** iOS kernel —
the genuine `kernelcache` Mach-O, not converted and not recompiled — by
interpreting its ARM64 machine code instruction by instruction, with a fake
boot chain (BootROM → LLB → iBoot) and fake hardware underneath it.

The kernel binary itself is **not** in this repository (it is Apple's; see
`kernelcache/PROVENANCE.md` for exactly which kernel is used and how it was
obtained).

## Everything is separate — and the first run is autonomous

The native apps (macOS + iPadOS) ship as a **shell + a native Swift
interpreter**. No kernel and no machine definition are baked in. The machine
arrives as two files:

1. **Translator pack** — `build/translator-pack-iphone11.json` (schema in
   `build/PACK.md`): a JSON data file defining the machine — memory map,
   load bases, UART, CPU topology, device tree, `boot_args` layout. The web
   core and the native Swift core consume the same pack, so they cannot
   drift (`packcheck.mjs` proves the web core's built-in copy and this file
   agree).
2. **Kernelcache** — the iOS 14.8 (18H17) kernel for iPhone 11, which is
   Apple's binary and is never hosted here.

On **first open the app fetches both files itself** — no file hunting:

- the translator pack is downloaded from this repo and validated;
- the kernel is **extracted from Apple's own IPSW on Apple's CDN**: the app
  resolves the iOS 14.8 IPSW via the ipsw.me API, range-requests only the
  ~16 MB kernelcache ZIP entry (not the ~6 GB IPSW), inflates it,
  unwraps the IM4P, LZFSE-decompresses it, and files it **only after**
  its size, Mach-O magic, and SHA-256 match the known 14.8 build.
  Progress is shown in the app's log; any failure is reported plainly
  there and the manual import UI remains as the fallback.

Manual import of a kernelcache and a pack is always available as the
alternative path (and is how other versions will be tried later).

## Current status (honest)

**Version 0.1.2.**

- The fake boot chain runs end to end: BootROM verifies the image, LLB
  brings up (sparse, paged) DRAM, iBoot loads the kernel segments, builds
  the `boot_args` record and the device tree (ADT), and jumps to the
  kernel's true entry point.
- The kernel runs its own start code, programs TTBR0/TTBR1/TCR, turns its
  MMU on, parses the device tree, and builds its CPU topology. Faults and
  undefined instructions are delivered to the kernel's own exception
  vector (VBAR) with ESR/FAR/ELR/SPSR set the way hardware sets them, and
  `ERET` returns from them.
- **Boot progress:** the reference core now runs the kernel **past
  200 million instructions with zero exceptions delivered**. The current
  frontier is characterizing what the kernel is doing at that point —
  still working through initialization, or waiting on something the fake
  machine does not yet provide (the leading suspect is timer interrupts:
  the fake machine has none yet). There is **no serial (UART) output
  yet** — the console is not awake that early — so this is not a full
  boot, and no claim of one is made.
- **Native Swift core synced to the reference (2026-11-26):**
  `FakeDeviceCore` is a from-scratch Swift port of the emulator (no
  JavaScript anywhere in the native apps), now ported forward through
  stage-5 frontiers 3–20: little-endian ADT with real arm-io ranges,
  `/chosen` dram-base/size and the lock-regs subtree (the ADT is now
  4,148 bytes from the pack), SIMD shift-by-immediate and
  shift-by-register groups, LD/ST multiple structures, LSE atomics with
  exact CAS, STLUR/LDAPUR and LDAPR, PACGA, PSTATE.PAN, and the CNTV
  timer timebase. Its headless acceptance harness, `fakedevice-check`,
  runs in CI against the real kernelcache (range-fetched from Apple's
  IPSW inside the job) and asserts the reference's exact trajectory:
  identical PC at 50M / 100M / 150M / 200M instructions with zero
  exceptions delivered. This sync is intermediate work, not a release —
  the next version ships when the reference reaches a full boot.
- A backdoor console (web page and native apps) gives open access to the
  fake phone: inspect/patch memory and registers, set breakpoints,
  single-step, and type into its serial port.

### 0.1.2 changes

- **Kernel download fixed.** The autonomous fetch failed on a real iPad
  at the inflate step: the Compression framework's zlib decoder,
  driven with a hand-made header over the raw deflate stream, reported
  an error on the genuine kernelcache entry. The ZIP-entry inflate is
  now `PuffInflate` (in `FakeDeviceCore`), a self-contained pure-Swift
  port of puff.c with no stream framing to get wrong. It is proven by
  execution in CI: `fakedevice-check` inflates stored-block,
  fixed-Huffman, and dynamic-Huffman streams (the last one ~1.3 MB
  inflating to 8 MiB) and byte-compares every output.
- **Full screen on iPad.** The app previously declared no launch
  screen at all, so iPadOS presented it letterboxed with black bars.
  It now declares a launch screen and requires full screen, and fills
  the display edge to edge in both orientations.
- 0.1.1 (for the record) fixed a launch crash in the first-run fetcher
  and hardened the whole download path so a failed or malformed
  download can never take the app down.

## Layout

- `build/` — the web implementation and reference core, with its test
  harnesses:
  - `emu.js` — the emulator core: ARM64 interpreter (integer + AdvSIMD/FP
    subset), the kernel's own page tables walked for translation,
    exception delivery, paged sparse RAM, t8030 UART + stub MMIO.
  - `boot.js` — the fake boot chain (`stageBootROM` → `stageLLB` →
    `stageIBoot`), Mach-O loader, `boot_args` and ADT builders.
  - `translator-pack-iphone11.json` + `PACK.md` — the machine definition
    as DATA (see above).
  - `page4_template.html` — the stage-4 page template (kernel embedded,
    backdoor console in-page). `build_page4.mjs` assembles the final
    page; `build_page.mjs` builds the earlier stage-3 page.
  - Tests: `test_emu.mjs` (self-test: prints `test` / `55` through the
    UART), `test_simd.mjs`, `test_mul.mjs`, `keytest.mjs`, `adtcheck.mjs`
    (ADT parse-back), `packcheck.mjs`, `verify_page*.mjs`.
- `kernelcache/` — `PROVENANCE.md` only. `kernelcache.raw` is git-ignored.
- `native/` — the native apps: a SwiftUI shell for macOS and iPadOS
  hosting **FakeDeviceCore**, the native Swift emulator core (the same
  sources are compiled into the app target and into the SwiftPM package
  whose `fakedevice-check` harness acceptance-tests them headlessly).
  See `native/README.md`.

## Building the web page

You need Node and a `kernelcache.raw` in `kernelcache/` (see
`kernelcache/PROVENANCE.md`):

```sh
cd build
node build_page4.mjs
```

This writes the single-file stage-4 page to `../../your_files/` relative
to `build/` (the author's local layout; edit the last line of
`build_page4.mjs` if you want it somewhere else). Open the page, press
**Boot the kernel** — the kernel is embedded, no file picking needed.

Run the emulator tests with:

```sh
cd build
node test_emu.mjs     # expects ./test.bin (checked in) — prints EMULATOR TEST PASS
node test_simd.mjs    # 30 checks
node test_mul.mjs     # 14 checks
node keytest.mjs
node adtcheck.mjs
node packcheck.mjs
```

## License

All rights reserved — published for viewing only. See `LICENSE`. The iOS
kernelcache used with this project is the property of Apple Inc. and is
not included here.

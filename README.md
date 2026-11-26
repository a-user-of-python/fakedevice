# FakeDevice

A lightweight fake iPhone (t8030, iPhone 11) that runs the **real** iOS kernel —
the genuine `kernelcache` Mach-O, not converted and not recompiled — by
interpreting its ARM64 machine code instruction by instruction, with a fake
boot chain (BootROM → LLB → iBoot) and fake hardware underneath it.

The kernel binary itself is **not** in this repository (it is Apple's; see
`kernelcache/PROVENANCE.md` for exactly which kernel is used and how it was
obtained). Bring your own `kernelcache.raw` and place it in `kernelcache/`.

## Current status (honest)

Work in progress. Current status (the `build/` copy of `emu.js`/`boot.js`
is the stage-4 snapshot; the translator pack files there are current):

- The fake boot chain runs end to end: BootROM verifies the image, LLB brings
  up (sparse, paged) DRAM, iBoot loads the kernel segments, builds the
  `boot_args` record and the device tree (ADT), and jumps to the kernel's true
  entry point.
- The kernel runs its own start code, programs TTBR0/TTBR1/TCR, turns its MMU
  on, parses the device tree, builds its CPU topology, and executes roughly
  **17.7 million instructions** before the first delivered exception (the
  count moves as the boot work progresses; the native Swift core is verified
  to reach the identical endpoint — see `native/README.md`).
- Faults and undefined instructions are delivered to the kernel's own
  exception vector (VBAR) with ESR/FAR/ELR/SPSR set the way hardware sets
  them, and `ERET` returns from them.
- The boot currently ends when the kernel executes an instruction word the
  emulator does not yet decode; the exception is delivered, the kernel's own
  handler runs, and the kernel parks in its stack-guard hang loop — it hangs
  rather than corrupt memory. Decoding that frontier is the next piece of
  work. The serial console is not awake that early, so the serial pane stays
  empty for now.
- **Everything is separate in the native apps:** the app is a shell + the
  Swift interpreter — no kernel and no machine definition are baked in.
  On first open the user imports a kernelcache AND a **translator pack**
  (`build/translator-pack-iphone11.json`, schema in `build/PACK.md`): a
  JSON data file defining the machine — memory map, load bases, UART,
  CPU topology, device tree, boot_args layout. Web and native consume
  the same pack so they cannot drift.
- A backdoor console (web page and native app) gives open access to the fake
  phone: inspect/patch memory and registers, set breakpoints, single-step,
  and type into its serial port.

## Layout

- `build/` — the web implementation and its test harnesses:
  - `emu.js` — the emulator core: ARM64 interpreter (integer + AdvSIMD/FP
    subset), the kernel's own page tables walked for translation, exception
    delivery, paged sparse RAM, t8030 UART + stub MMIO.
  - `boot.js` — the fake boot chain (`stageBootROM` → `stageLLB` →
    `stageIBoot`), Mach-O loader, `boot_args` and ADT builders.
  - `translator-pack-iphone11.json` + `PACK.md` — the machine definition
    as DATA (see above), consumed by both the web core and the native
    Swift core; `packcheck.mjs` proves the web core's built-in copy and
    this file agree.
  - `page4_template.html` — the stage-4 page template (kernel embedded,
    backdoor console in-page). `build_page4.mjs` assembles the final page;
    `build_page.mjs` builds the earlier stage-3 page.
  - Tests: `test_emu.mjs` (self-test: prints `test` / `55` through the UART),
    `test_simd.mjs`, `test_mul.mjs`, `keytest.mjs`, `adtcheck.mjs`
    (ADT parse-back), `verify_page*.mjs` (verify the shipped pages in Node).
- `kernelcache/` — `PROVENANCE.md` only. `kernelcache.raw` is git-ignored.
- `native/` — the native SwiftUI app (macOS + iPadOS) that hosts the same
  JS core in JavaScriptCore, so the emulator gets a native app's memory
  headroom instead of a browser tab's. See `native/README.md`.

## Building the web page

You need Node and a `kernelcache.raw` in `kernelcache/` (see
`kernelcache/PROVENANCE.md`):

```sh
cd build
node build_page4.mjs
```

This writes the single-file stage-4 page to `../../your_files/` relative to
`build/` (the author's local layout; edit the last line of `build_page4.mjs`
if you want it somewhere else). Open the page, press **Boot the kernel** —
the kernel is embedded, no file picking needed.

Run the emulator tests with:

```sh
cd build
node test_emu.mjs     # expects ./test.bin (checked in) — prints EMULATOR TEST PASS
node test_simd.mjs    # 30 checks
node test_mul.mjs     # 14 checks
node keytest.mjs
node adtcheck.mjs
```

## License

All rights reserved — published for viewing only. See `LICENSE`. The iOS
kernelcache used with this project is the property of Apple Inc. and is not
included here.

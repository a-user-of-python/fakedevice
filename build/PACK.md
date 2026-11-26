# FakeDevice Translator Pack — schema

A translator pack is the complete definition of one machine, as DATA. The
emulator core (the web JS core today; the native Swift core in the macOS /
iPadOS apps) contains **no machine constants**: on first open the app imports
two files — an XNU kernelcache and a translator pack — and everything the
core needs to know about the target machine comes from the pack.

Canonical file for this machine: `translator-pack-iphone11.json`
(iPhone 11, iPhone12,1, t8030 / A13).

Conventions:

- 64-bit addresses and sizes are JSON strings in hex (`"0xFFFFFFF007004000"`),
  so no value ever loses precision in a JSON parser.
- Small enumerations, counts, and byte offsets are plain JSON numbers.
- `packVersion` versions the SCHEMA, not the machine. Consumers must refuse
  a pack whose `packVersion` they do not understand.

## Top level

| Field | Meaning |
|---|---|
| `packVersion` | Schema version (currently 1). |
| `machine` | Device identifier the kernel expects (`iPhone12,1`). |
| `machineName` | Human-readable device name (`iPhone 11`). |
| `soc` | SoC identifier (`t8030`). |
| `socName` | Human-readable SoC name (`Apple A13 Bionic`). |
| `description` | Free-text summary of the pack. |

## `memory` — DRAM and kernel placement

| Field | Meaning |
|---|---|
| `dramBase` | Physical address where DRAM starts (`0x800000000` on t8030). The core's sparse RAM window is anchored here. |
| `memSize` | DRAM size (`0x100000000` = 4 GiB, as on the iPhone 11). Written into boot_args `memSize`/`memSizeActual` and the ADT `/memory` reg. |
| `kernelPhysBase` | Physical load address for the kernelcache image. This kernelcache's own early page tables assume exactly this placement; any other base breaks the post-MMU jump (proven in stage 3). |
| `kernelVirtBase` | The kernelcache's link-time virtual base. Physical placement of each segment = `kernelPhysBase + (segment.vmaddr − kernelVirtBase)`. |
| `pageSize` | Boot-chain page size (`0x4000`, 16 KiB) used to align boot_args / ADT / topOfKernelData. |

## `bootLayout` — where the fake iBoot puts things

| Field | Meaning |
|---|---|
| `bootArgsOffsetFromKernelTop` | Offset from the page-aligned end of the loaded kernel image to the boot_args structure (`0x0`: immediately at kernel top). |
| `adtOffsetFromBootArgs` | Offset from boot_args to the flattened device tree (`0x4000`: the next page). |

`topOfKernelData` (a boot_args field) is computed, not stored: the end of
the ADT, page-aligned.

## `uart` — the serial console (fake hardware)

| Field | Meaning |
|---|---|
| `name` | ADT node name (`uart0`). |
| `base` | MMIO base of UART0 on t8030 (`0x235200000`). The core traps accesses in `[base, base+size)`. |
| `size` | MMIO window size (`0x1000`). |
| `compatible` | ADT `compatible` string (`samsung,uart` — the A13 UART is Samsung-style). |
| `interrupts` | ADT `interrupts` cell triple `[0, 81, 0]` (SPI 81, level). |
| `registers.utrstat` | Offset of the status register (`0x10`); bit 1 = TX ready, bit 0 = RX ready. |
| `registers.utxh` | Offset of the TX holding register (`0x20`); a byte write emits one console character. |
| `registers.urxh` | Offset of the RX holding register (`0x24`); a read pops one queued input byte. |

## `armIo` — the `arm-io` root device node

| Field | Meaning |
|---|---|
| `name`, `compatible`, `deviceType` | ADT node name / `compatible` / `device_type` (`arm-io`, `arm-io,t8030`, `arm-io`). The kernel keys SoC bring-up off these strings. |
| `addressCells`, `sizeCells` | ADT `#address-cells` / `#size-cells` for children (2/2). |
| `regAddress`, `regSize` | The `reg` window covering all SoC MMIO (`0x200000000`, size `0x100000000`). |
| `rangesEmpty` | If true, the node carries an empty `ranges` property (present on the real tree; the kernel tolerates/requires it as shipped in stage 3). |

## `cpus` — CPU topology

`name` is the ADT node name (`cpus`); `addressCells`/`sizeCells` are its
`#address-cells`/`#size-cells`; `deviceType` is every child's `device_type`
(`cpu`). `list` is the per-CPU table the kernel's `ml_parse_cpu_topology`
reads — every field is load-bearing:

| Field | Meaning |
|---|---|
| `name` | ADT child node name (`cpu@0` … `cpu@5`). |
| `reg` | The CPU's MPIDR affinity value (0–3 = Thunder cores, 256/257 = Lightning). Also the DT `reg` property. |
| `compatible` | `apple,thunder` (efficiency) or `apple,lightning` (performance). |
| `clusterType` | DT `cluster-type` cell: 69 (`'E'`) or 80 (`'P'`). |
| `clusterName` | Human-readable form of `clusterType` (`E`/`P`). Documentation only. |
| `state` | DT `state` string. Exactly one CPU — the boot CPU — is `"running"`; the rest are `"idle"`. The kernel panics in topology parsing without this. |

## `deviceTree` — the flattened tree's static content

| Field | Meaning |
|---|---|
| `rootName` | Root node name (`/`). |
| `rootCompatible` | Root `compatible` (`apple,t8030`). |
| `model` | Root `model` (`iPhone12,1`). |
| `rootAddressCells`, `rootSizeCells` | Root `#address-cells` / `#size-cells` (2/2). |
| `memoryNodeName` | Name of the memory node (`memory`); its `reg` is built from `memory.dramBase`/`memory.memSize`. |
| `chosenNodeName` | Name of the chosen node (`chosen`). |
| `randomSeedHex` | The `/chosen/random-seed` bytes, hex-encoded. Real iBoot fills this from the hardware RNG; the pack's fixed bytes keep every run deterministic. |

## `bootArgs` — the boot_args structure (pexpert boot.h, revision 2)

`revision` / `version`: the structure revision the kernel checks (2/2).
`structSize`: bytes zeroed before fields are written (1152).
`machineType`: written verbatim (0). `commandLine`: the kernel command line
string (`"-v"`). `bootFlags`: the `bootFlags` field (0).

`layout` gives the byte offset of every field the boot chain writes. These
offsets are part of the machine/boot contract — a native core must write the
same fields at the same offsets:

| Key | Offset | Written value |
|---|---|---|
| `revision` | 0 | `bootArgs.revision` (u16) |
| `version` | 2 | `bootArgs.version` (u16) |
| `virtBase` | 8 | `memory.kernelVirtBase` |
| `physBase` | 16 | `memory.kernelPhysBase` |
| `memSize` | 24 | `memory.memSize` |
| `topOfKernelData` | 32 | computed (see `bootLayout`) — a PHYSICAL address |
| `video` | 40 | 48 bytes, all zero = no framebuffer, serial console only |
| `machineType` | 88 | `bootArgs.machineType` (u32) |
| `deviceTreeP` | 96 | the ADT's **virtual** address (see below) |
| `deviceTreeLength` | 104 | ADT byte length (u32) |
| `commandLine` | 112 | `bootArgs.commandLine`, NUL-padded by the zeroed struct |
| `bootFlags` | 1136 | `bootArgs.bootFlags` |
| `memSizeActual` | 1144 | mirrors `memory.memSize` |

**`deviceTreeP` is a virtual address.** In boot.h it is a `void *`, unlike
the explicitly-physical `topOfKernelData`. The kernel stores it raw into
`PE_state.deviceTreeHead` / `DTRootNode` and dereferences it as a VA, and
`SecureDTIsLockedDown()` `kvtophys()`es it. Real iBoot passes
`phystokv(adtPhys) = adtPhys − kernelPhysBase + kernelVirtBase`. Passing the
physical address instead makes the lockdown check read the tree as sitting
below the kernel, takes the CTRR EXTRADATA path with a raw PA as
`segLOWEST`, and corrupts the physmap — this was stage-5 frontier 2; the
distinction is part of the pack contract, not an implementation detail.

## Consumers

- `boot.js` (web core): `bootKernel(machine, kernelBytes, log, pack?)`.
  With no pack it uses `BUILTIN_PACK`, a copy of the iPhone 11 pack kept in
  the file for the single-file web page; `packcheck.mjs` proves the copy and
  `translator-pack-iphone11.json` are deep-equal, and that `emu.js`'s
  compiled-in `DRAM_BASE`/`UART_BASE` agree with the pack.
- Native cores: load the JSON, take every value from it. If a value the core
  needs is not in the pack, that is a schema bug — extend the schema (and
  bump `packVersion` if the change is not purely additive), never hardcode.

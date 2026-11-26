# kernelcache.raw — provenance

- **What:** Decompressed iOS kernelcache (raw Mach-O 64, ARM64) for **iPhone 11
  (iPhone12,1, A13)**, iOS **14.8**, build **18H17**.
- **Source IPSW:** `iPhone11,8,iPhone12,1_14.8_18H17_Restore.ipsw`
  (updates.cdn-apple.com, via api.ipsw.me v4 device/iPhone12,1).
- **ZIP entry:** `kernelcache.release.iphone12b` (the release kernelcache for
  the iPhone12,1; the same IPSW also carries `iphone11b` = iPhone XR/A12 and a
  `research.iphone12b` variant — neither was used).
- **How:**
  1. `fetch_kernelcache.py` — HTTP Range reads only: ZIP64 EOCD + central
     directory from the tail of the 5.96 GB IPSW, then range-downloaded just
     the kernelcache entry (16,102,034 compressed bytes) and inflated it to
     `kernelcache.im4p` (16,112,522 bytes, IM4P fourcc `krnl`).
  2. `unwrap_kernelcache.py` (venv python, `pyimg4` + `lzfse`) — IM4P unwrap +
     LZFSE decompress → `kernelcache.raw`.
- **Result:** `kernelcache.raw` — 46,748,272 bytes, Mach-O magic `cf fa ed fe`,
  cputype ARM64, filetype EXECUTE, 26 load commands.
- **SHA-256:** `2bf684f41f79bd309e70398b6116eb2054e217892daa52e919bdfd7634e4f246`

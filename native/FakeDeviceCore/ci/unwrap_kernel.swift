// unwrap_kernel.swift — CI helper: unwrap an IM4P kernelcache and
// LZFSE-decompress its payload to the raw Mach-O kernelcache.
//
// Usage: unwrap_kernel <in.im4p> <out.raw>
//
// IM4P layout (verified byte-for-byte against the real 14.8 kernelcache):
//   SEQUENCE {
//     IA5String "IM4P",
//     IA5String "krnl",
//     IA5String description (e.g. "KernelCacheBuilder_release-..."),
//     OCTET STRING  -- the LZFSE-compressed payload (starts with a bvx*
//                      block magic),
//     ...           -- anything after the payload is ignored
//   }
// The decompression uses the Compression framework's LZFSE decoder — the
// same decoder the app's own first-run fetcher uses. No force unwraps:
// every structural problem exits with a message instead.

import Foundation
import Compression

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("unwrap_kernel: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    die("usage: unwrap_kernel <in.im4p> <out.raw>")
}
let inPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

guard let data = FileManager.default.contents(atPath: inPath) else {
    die("cannot read \(inPath)")
}
let bytes = [UInt8](data)

// Minimal DER length reader: returns (length, nextOffset).
func readLength(_ b: [UInt8], _ offset: Int) -> (Int, Int)? {
    guard offset < b.count else { return nil }
    let first = b[offset]
    if first < 0x80 { return (Int(first), offset + 1) }
    let n = Int(first & 0x7F)
    guard n >= 1, n <= 4, offset + 1 + n <= b.count else { return nil }
    var value = 0
    for i in 0..<n { value = (value << 8) | Int(b[offset + 1 + i]) }
    return (value, offset + 1 + n)
}

// Skip one TLV element starting at `offset`; returns the offset just past it.
func skipElement(_ b: [UInt8], _ offset: Int) -> Int? {
    guard offset < b.count, let (len, contentStart) = readLength(b, offset + 1) else { return nil }
    let end = contentStart + len
    guard end <= b.count else { return nil }
    return end
}

guard bytes.count > 2, bytes[0] == 0x30, let (_, contentStart) = readLength(bytes, 1) else {
    die("not an IM4P (missing outer SEQUENCE)")
}
var pos = contentStart
// Three IA5 strings: "IM4P", the fourcc, the description.
for _ in 0..<3 {
    guard pos < bytes.count, bytes[pos] == 0x16, let next = skipElement(bytes, pos) else {
        die("IM4P header: expected an IA5String element")
    }
    pos = next
}
guard pos < bytes.count, bytes[pos] == 0x04, let (payloadLen, payloadStart) = readLength(bytes, pos + 1),
      payloadStart + payloadLen <= bytes.count else {
    die("IM4P: payload OCTET STRING missing or truncated")
}
let payload = Array(bytes[payloadStart..<(payloadStart + payloadLen)])
print("IM4P payload: \(payloadLen) bytes, magic \(String(bytes: payload.prefix(4), encoding: .ascii) ?? "????")")

// LZFSE-decompress. The 14.8 kernelcache decompresses to 46,748,272
// bytes; allocate with headroom and verify the size afterwards.
let capacity = max(payloadLen * 4, 1 << 26)
var out = [UInt8](repeating: 0, count: capacity)
let scratchSize = compression_decode_scratch_buffer_size(COMPRESSION_LZFSE)
var scratch = [UInt8](repeating: 0, count: scratchSize)
let written = payload.withUnsafeBufferPointer { src in
    out.withUnsafeMutableBufferPointer { dst in
        scratch.withUnsafeMutableBufferPointer { scr in
            compression_decode_buffer(dst.baseAddress!, capacity,
                                      src.baseAddress!, payloadLen,
                                      scr.baseAddress!, COMPRESSION_LZFSE)
        }
    }
}
guard written > 0 else { die("LZFSE decode failed") }
out.removeLast(capacity - written)
guard out.count == 46_748_272 else { die("decompressed size \(out.count), want 46748272") }
guard Array(out.prefix(4)) == [0xCF, 0xFA, 0xED, 0xFE] else { die("decompressed data is not a Mach-O 64") }
do {
    try Data(out).write(to: URL(fileURLWithPath: outPath))
} catch {
    die("cannot write \(outPath): \(error.localizedDescription)")
}
print("wrote \(outPath): \(out.count) bytes")

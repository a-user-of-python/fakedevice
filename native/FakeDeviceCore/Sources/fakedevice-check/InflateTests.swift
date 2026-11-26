// InflateTests.swift — fakedevice-check
//
// Execution proof for PuffInflate (the pure-Swift DEFLATE decoder
// that replaced the Compression-framework zlib wrapper in 0.1.2,
// after the wrapper reported an error on a real iPad halfway through
// the autonomous kernel download). All test data is synthetic —
// generated locally with Python's zlib from the generators below;
// no bytes from any real firmware are used.
//
//   (a) stored-block stream   — hand-built stored block, exact bytes
//   (b) fixed-Huffman stream  — zlib Z_FIXED output, exact bytes
//   (c) dynamic-Huffman stream — TestData/deflate-fixture-8m.bin
//       (1,258,286 bytes) inflating to 8 MiB of synthetic data from
//       syntheticPlaintext(); the output is byte-compared against a
//       regenerated original, so the check is a full byte compare,
//       not a hash or a spot check.
//   negatives — truncated stream, wrong expected sizes, garbage and
//       empty input must all throw, never crash and never "succeed".

import Foundation
import FakeDeviceCore

private enum InflateVectors {
    static let storedStream: [UInt8] = [
        1, 83, 0, 172, 255, 70, 97, 107, 101, 68, 101, 118,
        105, 99, 101, 32, 115, 116, 111, 114, 101, 100, 45, 98,
        108, 111, 99, 107, 32, 118, 101, 99, 116, 111, 114, 58,
        32, 112, 97, 99, 107, 32, 109, 121, 32, 98, 111, 120,
        32, 119, 105, 116, 104, 32, 102, 105, 118, 101, 32, 100,
        111, 122, 101, 110, 32, 108, 105, 113, 117, 111, 114, 32,
        106, 117, 103, 115, 46, 32, 48, 49, 50, 51, 52, 53,
        54, 55, 56, 57,
    ]
    static let fixedStream: [UInt8] = [
        43, 201, 72, 85, 72, 75, 204, 78, 85, 72, 73, 45,
        203, 76, 78, 85, 40, 78, 204, 76, 81, 40, 1, 10,
        102, 167, 22, 229, 165, 230, 40, 148, 231, 151, 230, 164,
        40, 36, 229, 231, 151, 232, 40, 36, 230, 161, 72, 129,
        4, 83, 83, 172, 193, 66, 24, 70, 100, 150, 40, 36,
        166, 39, 102, 230, 65, 116, 129, 153, 32, 49, 136, 30,
        61, 236, 122, 134, 173, 181, 0,
    ]
}

/// The synthetic plaintext generator for fixture (c). This is the
/// exact twin of the Python generator that produced the fixture:
/// 64 KiB blocks cycling pattern text / hashed small-alphabet noise /
/// single-byte runs / strided pattern. Pure function of the index,
/// so the test regenerates the expected 8 MiB and byte-compares.
private func syntheticPlaintext(_ n: Int) -> [UInt8] {
    let pattern = [UInt8]("FakeDevice stage-5 boot log: page frame init ok. ".utf8)
    var out = [UInt8](repeating: 0, count: n)
    for i in 0..<n {
        let block = i >> 16
        switch block % 4 {
        case 0:
            out[i] = pattern[i % pattern.count]
        case 1:
            var h = UInt32(truncatingIfNeeded: i) ^ 0x9E3779B9
            h = h &* 2654435761
            h ^= (h >> 15)
            h = h &* 2246822519
            h ^= (h >> 13)
            out[i] = 0x61 + UInt8(h >> 28)
        case 2:
            out[i] = 0x30 + UInt8(block % 10)
        default:
            out[i] = pattern[(i * 7) % pattern.count]
        }
    }
    return out
}

private func loadInflateFixture() -> Data? {
    // Next to this source file (CI builds and runs from a checkout).
    let srcDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let beside = srcDir.appendingPathComponent("TestData/deflate-fixture-8m.bin")
    if let d = try? Data(contentsOf: beside) { return d }
    // The SPM resource bundle.
    if let url = Bundle.module.url(forResource: "deflate-fixture-8m", withExtension: "bin", subdirectory: "TestData"),
       let d = try? Data(contentsOf: url) { return d }
    // CWD-relative fallbacks.
    for p in ["native/FakeDeviceCore/Sources/fakedevice-check/TestData/deflate-fixture-8m.bin",
              "Sources/fakedevice-check/TestData/deflate-fixture-8m.bin",
              "TestData/deflate-fixture-8m.bin"] {
        if let d = FileManager.default.contents(atPath: p) { return d }
    }
    return nil
}

func runInflateTests() {
    // (a) Stored block.
    let storedPlain = [UInt8]("FakeDevice stored-block vector: pack my box with five dozen liquor jugs. 0123456789".utf8)
    let storedOut = try? PuffInflate.inflate(Data(InflateVectors.storedStream), expectedSize: storedPlain.count)
    chk("inflate stored-block vector (byte-exact)", storedOut == Data(storedPlain))

    // (b) Fixed Huffman.
    let sentence = "the fake device said the kernel would boot, and the kernel booted; the fake device said it again, and again it booted. "
    let fixedPlain = [UInt8]((sentence + sentence + sentence).utf8)
    chkEq("fixed-Huffman vector plaintext size", fixedPlain.count, 357)
    let fixedOut = try? PuffInflate.inflate(Data(InflateVectors.fixedStream), expectedSize: fixedPlain.count)
    chk("inflate fixed-Huffman vector (byte-exact)", fixedOut == Data(fixedPlain))

    // (c) Dynamic Huffman, multi-MB, full byte compare.
    if let fixture = loadInflateFixture() {
        chkEq("dynamic fixture stream size", fixture.count, 1_258_286)
        let expected = syntheticPlaintext(8 * 1024 * 1024)
        let start = Date()
        let out = try? PuffInflate.inflate(fixture, expectedSize: expected.count)
        let elapsed = Date().timeIntervalSince(start)
        chk("inflate dynamic-Huffman 8 MiB stream (byte-exact)", out == Data(expected))
        print(String(format: "inflate dynamic fixture: %.2f s for 8 MiB", elapsed))

        // Negatives on the real-shaped stream.
        chk("inflate truncated stream throws",
            (try? PuffInflate.inflate(fixture.prefix(1000), expectedSize: expected.count)) == nil)
        chk("inflate too-small expected size throws",
            (try? PuffInflate.inflate(fixture, expectedSize: 1024)) == nil)
        chk("inflate too-big expected size throws",
            (try? PuffInflate.inflate(fixture, expectedSize: expected.count + 1)) == nil)
    } else {
        chk("dynamic-Huffman fixture found", false)
    }

    // Negatives: garbage and empty input throw, never crash.
    chk("inflate garbage throws",
        (try? PuffInflate.inflate(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), expectedSize: 16)) == nil)
    chk("inflate empty input throws",
        (try? PuffInflate.inflate(Data(), expectedSize: 0)) == nil)
}

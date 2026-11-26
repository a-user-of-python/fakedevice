// Inflate.swift — FakeDeviceCore
//
// A self-contained, pure-Swift DEFLATE (RFC 1951) decoder: a faithful
// port of Mark Adler's puff.c (version 2.3, 21 Jan 2013 — zlib
// license, copyright (C) 2002-2013 Mark Adler), using puff's simple
// bit-at-a-time decode(). It exists because of a device-proven
// failure: 0.1.0/0.1.1 inflated the IPSW kernelcache entry through
// the Compression framework by prepending a 2-byte zlib header to the
// raw deflate stream and driving COMPRESSION_ZLIB — on a real iPad
// that decoder reported an error on the genuine stream (after the
// full 16 MB had downloaded fine), so the autonomous first-run
// kernel fetch failed at its last step. This decoder has no framing
// assumptions at all: raw deflate in, bytes out, and its output is
// verified by the caller against the ZIP directory size and the
// kernel's known SHA-256 before anything is filed.
//
// Proven by execution, not by inspection:
//  - During development the C original (both decode() variants) was
//    run on the actual kernelcache entry stream taken from Apple's
//    IPSW: byte-identical output to the reference pipeline
//    (16,112,522 bytes, matching SHA-256).
//  - fakedevice-check runs the vectors in InflateTests.swift on every
//    CI build: a stored-block stream, a fixed-Huffman stream, and a
//    ~1.3 MB dynamic-Huffman stream that inflates to 8 MiB of
//    synthetic data, byte-compared against the regenerated originals,
//    plus negative tests (truncated / garbage / wrong size throw
//    instead of crashing).
//
// The port mirrors puff's structure and error codes:
//    2  input did not terminate (ran out of input)
//    1  output space exhausted before inflate completed
//   -1  invalid block type        -7/-8  invalid dynamic code lengths
//   -2  stored length mismatch    -9     missing end-of-block code
//   -3  too many codes            -10    invalid code
//   -4  length codes incomplete   -11    distance too far back
//   -5  repeat with no first      -6     too many lengths

import Foundation

public enum PuffInflate {
    public struct InflateError: Error, CustomStringConvertible {
        /// The puff return code for the failure (see the table above).
        public let code: Int
        public init(code: Int) { self.code = code }
        public var description: String { "deflate stream error (puff code \(code))" }
    }

    /// Inflate a raw DEFLATE stream that must produce exactly
    /// `expectedSize` bytes. Throws InflateError on any malformed,
    /// truncated, or over/under-producing stream.
    public static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else { throw InflateError(code: 1) }
        let decoder = Decoder(input: [UInt8](data), capacity: expectedSize)
        try decoder.run()
        guard decoder.outcnt == expectedSize else { throw InflateError(code: 2) }
        return Data(decoder.out)
    }
}

private final class Decoder {
    // Output state: a fixed-size buffer of exactly the expected size,
    // like puff's dest — producing more is error 1, less is caught by
    // the caller's count check.
    private(set) var out: [UInt8]
    private(set) var outcnt = 0

    // Input state.
    private let input: [UInt8]
    private var incnt = 0
    private var bitbuf = 0
    private var bitcnt = 0

    init(input: [UInt8], capacity: Int) {
        self.input = input
        self.out = [UInt8](repeating: 0, count: capacity)
    }

    /// puff's longjmp out of bits()/decode() when input runs out.
    private struct OutOfInput: Error {}

    // MARK: bits() — return `need` bits from the input stream.
    private func bits(_ need: Int) throws -> Int {
        var val = bitbuf
        while bitcnt < need {
            if incnt == input.count { throw OutOfInput() }
            val |= (Int(input[incnt]) << bitcnt)
            incnt += 1
            bitcnt += 8
        }
        bitbuf = val >> need
        bitcnt -= need
        return val & ((1 << need) - 1)
    }

    // MARK: Huffman table (puff's struct huffman)
    private struct Huffman {
        var count = [Int](repeating: 0, count: 16)  // codes of each length (MAXBITS+1)
        var symbol: [Int] = []                      // canonically ordered symbols
    }

    // MARK: decode() — puff's simple version: walk the canonical code
    // one bit at a time. Returns the symbol, or -10 if the code does
    // not resolve within 15 bits.
    private func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1...15 {
            code |= try bits(1)
            let count = h.count[len]
            if code - count < first {
                return h.symbol[index + (code - first)]
            }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        return -10
    }

    // MARK: construct() — build count/symbol tables from code lengths.
    // Returns 0 for a complete code, negative for over-subscribed,
    // positive for incomplete (puff semantics).
    private func construct(_ h: inout Huffman, _ lengths: [Int], _ offset: Int, _ n: Int) -> Int {
        for len in 0...15 { h.count[len] = 0 }
        for symbol in 0..<n {
            h.count[lengths[offset + symbol]] += 1
        }
        h.symbol = [Int](repeating: 0, count: n)
        if h.count[0] == n { return 0 }  // no codes

        var left = 1
        for len in 1...15 {
            left <<= 1
            left -= h.count[len]
            if left < 0 { return left }  // over-subscribed
        }

        var offs = [Int](repeating: 0, count: 16)
        offs[1] = 0
        for len in 1..<15 {
            offs[len + 1] = offs[len] + h.count[len]
        }
        for symbol in 0..<n where lengths[offset + symbol] != 0 {
            let len = lengths[offset + symbol]
            h.symbol[offs[len]] = symbol
            offs[len] += 1
        }
        return left
    }

    // MARK: stored() — process a stored (uncompressed) block.
    private func stored() throws {
        // Discard leftover bits from the current byte.
        bitbuf = 0
        bitcnt = 0

        // Length, checked against its one's complement.
        if incnt + 4 > input.count { throw PuffInflate.InflateError(code: 2) }
        var len = Int(input[incnt]); incnt += 1
        len |= (Int(input[incnt]) << 8); incnt += 1
        let comp1 = Int(input[incnt]); incnt += 1
        let comp2 = Int(input[incnt]); incnt += 1
        if comp1 != (~len & 0xff) || comp2 != ((~len >> 8) & 0xff) {
            throw PuffInflate.InflateError(code: -2)
        }

        if incnt + len > input.count { throw PuffInflate.InflateError(code: 2) }
        if outcnt + len > out.count { throw PuffInflate.InflateError(code: 1) }
        while len > 0 {
            out[outcnt] = input[incnt]
            outcnt += 1
            incnt += 1
            len -= 1
        }
    }

    // MARK: codes() — decode literals and length/distance pairs until
    // the end-of-block symbol.
    private func codes(_ lencode: Huffman, _ distcode: Huffman) throws {
        // Size base / extra bits for length codes 257...285.
        let lens: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                           35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        let lext: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                           3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        // Offset base / extra bits for distance codes 0...29.
        let dists: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                            257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                            8193, 12289, 16385, 24577]
        let dext: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                           7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

        var symbol = 0
        repeat {
            symbol = try decode(lencode)
            if symbol < 0 { throw PuffInflate.InflateError(code: symbol) }
            if symbol < 256 {
                // Literal: the symbol is the byte.
                if outcnt == out.count { throw PuffInflate.InflateError(code: 1) }
                out[outcnt] = UInt8(symbol)
                outcnt += 1
            } else if symbol > 256 {
                // Length/distance pair.
                var sym = symbol - 257
                if sym >= 29 { throw PuffInflate.InflateError(code: -10) }
                let len = lens[sym] + (try bits(lext[sym]))

                sym = try decode(distcode)
                if sym < 0 { throw PuffInflate.InflateError(code: sym) }
                let dist = dists[sym] + (try bits(dext[sym]))
                if dist > outcnt { throw PuffInflate.InflateError(code: -11) }

                if outcnt + len > out.count { throw PuffInflate.InflateError(code: 1) }
                var remaining = len
                while remaining > 0 {
                    // Forward copy: handles overlapping matches.
                    out[outcnt] = out[outcnt - dist]
                    outcnt += 1
                    remaining -= 1
                }
            }
        } while symbol != 256
    }

    // MARK: fixed() — process a fixed-codes block.
    private func fixed() throws {
        var lengths = [Int](repeating: 0, count: 288)  // FIXLCODES
        for s in 0..<144 { lengths[s] = 8 }
        for s in 144..<256 { lengths[s] = 9 }
        for s in 256..<280 { lengths[s] = 7 }
        for s in 280..<288 { lengths[s] = 8 }
        var lencode = Huffman()
        _ = construct(&lencode, lengths, 0, 288)

        let distLengths = [Int](repeating: 5, count: 30)  // MAXDCODES
        var distcode = Huffman()
        _ = construct(&distcode, distLengths, 0, 30)

        try codes(lencode, distcode)
    }

    // MARK: dynamic() — process a dynamic-codes block.
    private func dynamic() throws {
        // Permutation of the code-length code lengths.
        let order: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var lengths = [Int](repeating: 0, count: 316)  // MAXCODES = 286 + 30

        let nlen = try bits(5) + 257
        let ndist = try bits(5) + 1
        let ncode = try bits(4) + 4
        if nlen > 286 || ndist > 30 { throw PuffInflate.InflateError(code: -3) }

        // Read the code-length code lengths; missing lengths are zero.
        for index in 0..<ncode {
            lengths[order[index]] = try bits(3)
        }
        for index in ncode..<19 {
            lengths[order[index]] = 0
        }

        // Build the code-length Huffman table (in lencode, temporarily).
        var lencode = Huffman()
        var err = construct(&lencode, lengths, 0, 19)
        if err != 0 { throw PuffInflate.InflateError(code: -4) }  // must be complete

        // Read the literal/length and distance lengths as one list.
        var index = 0
        while index < nlen + ndist {
            let symbol = try decode(lencode)
            if symbol < 0 { throw PuffInflate.InflateError(code: symbol) }
            if symbol < 16 {
                lengths[index] = symbol
                index += 1
            } else {
                var len = 0  // assume repeating zeros
                var rep: Int
                if symbol == 16 {
                    if index == 0 { throw PuffInflate.InflateError(code: -5) }
                    len = lengths[index - 1]
                    rep = 3 + (try bits(2))
                } else if symbol == 17 {
                    rep = 3 + (try bits(3))
                } else {  // symbol == 18
                    rep = 11 + (try bits(7))
                }
                if index + rep > nlen + ndist { throw PuffInflate.InflateError(code: -6) }
                while rep > 0 {
                    lengths[index] = len
                    index += 1
                    rep -= 1
                }
            }
        }

        // There better be an end-of-block code.
        if lengths[256] == 0 { throw PuffInflate.InflateError(code: -9) }

        // Literal/length table: an incomplete code is allowed only for
        // a single length-1 code.
        err = construct(&lencode, lengths, 0, nlen)
        if err != 0 && (err < 0 || nlen != lencode.count[0] + lencode.count[1]) {
            throw PuffInflate.InflateError(code: -7)
        }

        // Distance table: same single-symbol allowance.
        var distcode = Huffman()
        err = construct(&distcode, lengths, nlen, ndist)
        if err != 0 && (err < 0 || ndist != distcode.count[0] + distcode.count[1]) {
            throw PuffInflate.InflateError(code: -8)
        }

        try codes(lencode, distcode)
    }

    // MARK: puff() — process blocks until the last block or an error.
    func run() throws {
        do {
            var last = false
            while !last {
                last = try bits(1) == 1
                let type = try bits(2)
                switch type {
                case 0: try stored()
                case 1: try fixed()
                case 2: try dynamic()
                default: throw PuffInflate.InflateError(code: -1)
                }
            }
        } catch is OutOfInput {
            throw PuffInflate.InflateError(code: 2)
        }
    }
}

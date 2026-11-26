// FirstRunFetcher.swift — FakeDevice app
//
// Fully autonomous first-run acquisition: on first open the app fetches
// BOTH files itself — no file hunting, no manual steps for the standard
// setup.
//
//   1. Translator pack: downloaded straight from this project's repo
//      (it is the project's own data file).
//   2. Kernelcache: extracted from Apple's own iOS 14.8 IPSW using the
//      exact technique proven in build/../kernelcache (see
//      PROVENANCE.md there): resolve the IPSW URL via the ipsw.me API,
//      range-request ONLY the kernelcache ZIP entry (~16 MB of the
//      ~6 GB IPSW) from Apple's CDN, inflate it, unwrap the IM4P,
//      LZFSE-decompress with the Compression framework, then verify
//      size + SHA-256 + Mach-O magic before filing it in the library.
//
// The kernel is Apple's binary: it travels Apple -> this device
// directly and is never hosted by this project. Any failure throws a
// plain-language error; the caller logs it and the manual import UI
// remains as the fallback. Nothing here fakes success — the kernel is
// only filed after its SHA-256 matches the known 14.8 build.

import Foundation
import Compression
import CryptoKit

enum FetcherError: Error, LocalizedError {
    case http(String)
    case badData(String)
    case verify(String)
    var errorDescription: String? {
        switch self {
        case .http(let m), .badData(let m), .verify(let m): return m
        }
    }
}

struct FirstRunFetcher {
    typealias Log = (String) -> Void

    static let packFileName = "translator-pack-iphone11.json"
    static let kernelFileName = "kernelcache.raw"
    static let kernelEntryName = "kernelcache.release.iphone12b"
    static let expectedKernelSize = 46_748_272
    static let expectedKernelSHA256 = "2bf684f41f79bd309e70398b6116eb2054e217892daa52e919bdfd7634e4f246"

    private static let ipswAPI = URL(string: "https://api.ipsw.me/v4/device/iPhone12,1?type=ipsw")!

    // MARK: - Translator pack

    static func fetchPack(into dir: URL, log: @escaping Log) async throws -> URL {
        log("[setup] Downloading translator pack from the project repo…")
        let (data, response) = try await URLSession.shared.data(from: DownloadLinks.translatorPack)
        try checkHTTP(response, "translator pack download")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["packVersion"] as? NSNumber)?.intValue == 1 else {
            throw FetcherError.badData("the downloaded translator pack is not a valid packVersion 1 file")
        }
        let dest = dir.appendingPathComponent(packFileName)
        try data.write(to: dest, options: .atomic)
        log("[setup] Translator pack saved (\(data.count) bytes) — \(((obj["machineName"] as? String) ?? "iPhone 11")).")
        return dest
    }

    // MARK: - Kernelcache (extracted from Apple's IPSW)

    static func fetchKernel(into dir: URL, log: @escaping Log) async throws -> URL {
        // 1. Resolve the iOS 14.8 (18H17) IPSW URL from the ipsw.me API.
        log("[setup] Resolving the iOS 14.8 IPSW for iPhone 11 (iPhone12,1) via ipsw.me…")
        let (apiData, apiResponse) = try await URLSession.shared.data(from: ipswAPI)
        try checkHTTP(apiResponse, "ipsw.me API")
        guard let root = try? JSONSerialization.jsonObject(with: apiData) as? [String: Any],
              let firmwares = root["firmwares"] as? [[String: Any]],
              let fw = firmwares.first(where: { ($0["version"] as? String) == "14.8" && ($0["buildid"] as? String) == "18H17" }),
              let urlString = fw["url"] as? String,
              let ipswURL = URL(string: urlString) else {
            throw FetcherError.badData("ipsw.me did not list an iOS 14.8 (18H17) IPSW for iPhone12,1")
        }
        log("[setup] IPSW: \(ipswURL.lastPathComponent) — hosted on Apple's CDN. Downloading only the kernelcache entry (~16 MB), not the whole IPSW.")

        // 2. ZIP surgery over range requests: total size, EOCD (ZIP64),
        //    central directory, the one entry we need.
        let total = try await totalSize(ipswURL)
        let tailLen = min(total, 1 << 20)
        let tail = try await range(ipswURL, total - tailLen, total - 1)
        guard let cd = try await centralDirectory(ipswURL, tail: tail, total: total) else {
            throw FetcherError.badData("could not read the IPSW's ZIP central directory")
        }
        guard let entry = cd.entries[kernelEntryName] ?? cd.entries.first(where: { $0.key.contains("kernelcache.release.") && $0.key.contains("iphone12b") })?.value else {
            throw FetcherError.badData("no \(kernelEntryName) entry in the IPSW")
        }
        log("[setup] Found \(kernelEntryName): \(entry.usize) bytes in the archive (method \(entry.method)).")

        // 3. Local header -> data start; download the entry in chunks.
        let lh = try await range(ipswURL, entry.lhofs, entry.lhofs + 29)
        guard lh.count >= 30, u32(lh, 0) == 0x04034B50 else { throw FetcherError.badData("bad ZIP local header") }
        let dataStart = entry.lhofs + 30 + Int(u16(lh, 26)) + Int(u16(lh, 28))
        var compressed = Data()
        compressed.reserveCapacity(entry.csize)
        let chunk = 4 << 20
        var pos = 0
        while pos < entry.csize {
            let n = min(chunk, entry.csize - pos)
            compressed += try await range(ipswURL, dataStart + pos, dataStart + pos + n - 1)
            pos += n
            log("[setup] Kernelcache download: \(pos / 1_000_000) of \(entry.csize / 1_000_000) MB…")
        }
        guard compressed.count == entry.csize else {
            throw FetcherError.badData("kernelcache download truncated (\(compressed.count) of \(entry.csize) bytes)")
        }

        // 4. Inflate (ZIP deflate) if needed -> the IM4P file.
        let im4p: Data
        switch entry.method {
        case 0: im4p = compressed
        case 8: im4p = try inflateRawDeflate(compressed, expectedSize: entry.usize)
        default: throw FetcherError.badData("unsupported ZIP method \(entry.method) for the kernelcache entry")
        }
        guard im4p.count == entry.usize else {
            throw FetcherError.badData("inflated kernelcache entry has the wrong size (\(im4p.count), want \(entry.usize))")
        }

        // 5. Unwrap the IM4P -> LZFSE payload; decompress.
        log("[setup] Unwrapping the IM4P and LZFSE-decompressing the kernel…")
        let payload = try im4pPayload(im4p)
        let raw = try lzfseDecompress(payload, expectedSize: expectedKernelSize)

        // 6. Verify before filing: size, Mach-O magic, SHA-256.
        guard raw.count == expectedKernelSize else {
            throw FetcherError.verify("kernel size mismatch: got \(raw.count), want \(expectedKernelSize) — not filing it")
        }
        guard raw.prefix(4).elementsEqual([0xCF, 0xFA, 0xED, 0xFE]) else {
            throw FetcherError.verify("decompressed kernel does not start with the Mach-O arm64 magic — not filing it")
        }
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedKernelSHA256 else {
            throw FetcherError.verify("kernel SHA-256 mismatch (got \(digest)) — not filing it")
        }
        let dest = dir.appendingPathComponent(kernelFileName)
        try raw.write(to: dest, options: .atomic)
        log("[setup] Kernel verified: \(raw.count) bytes, SHA-256 matches the known iOS 14.8 build. Saved to the library.")
        return dest
    }

    // MARK: - HTTP helpers

    private static func checkHTTP(_ response: URLResponse, _ what: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FetcherError.http("\(what) failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))")
        }
    }

    private static func range(_ url: URL, _ start: Int, _ end: Int) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            throw FetcherError.http("range request \(start)-\(end) was not honoured (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        return data
    }

    private static func totalSize(_ url: URL) async throws -> Int {
        var req = URLRequest(url: url)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              let cr = http.value(forHTTPHeaderField: "Content-Range"),
              let total = Int(cr.split(separator: "/").last ?? "") else {
            throw FetcherError.http("could not learn the IPSW size from its Content-Range")
        }
        return total
    }

    // MARK: - ZIP central directory (mirrors fetch_kernelcache.py)

    private struct ZipEntry { var method: Int; var csize: Int; var usize: Int; var lhofs: Int }

    private static func u16(_ d: Data, _ off: Int) -> UInt16 {
        UInt16(d[off]) | UInt16(d[off + 1]) << 8
    }
    private static func u32(_ d: Data, _ off: Int) -> UInt32 {
        UInt32(d[off]) | UInt32(d[off + 1]) << 8 | UInt32(d[off + 2]) << 16 | UInt32(d[off + 3]) << 24
    }
    private static func u64(_ d: Data, _ off: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[off + i]) << (8 * i) }
        return v
    }

    private static func centralDirectory(_ url: URL, tail: Data, total: Int) async throws -> (entries: [String: ZipEntry], count: Int)? {
        // EOCD is the last PK\x05\x06 in the tail.
        var eocdOff = -1
        var i = tail.count - 22
        while i >= 0 {
            if u32(tail, i) == 0x06054B50 { eocdOff = i; break }
            i -= 1
        }
        guard eocdOff >= 0 else { return nil }
        var cdSize = Int(u32(tail, eocdOff + 12))
        var cdOff = Int(u32(tail, eocdOff + 16))
        var nTotal = Int(u16(tail, eocdOff + 10))
        if cdOff == 0xFFFFFFFF || cdSize == 0xFFFFFFFF || nTotal == 0xFFFF {
            // ZIP64: the locator sits in the 20 bytes before the EOCD.
            let loc = eocdOff - 20
            guard loc >= 0, u32(tail, loc) == 0x07064B50 else { return nil }
            let z64Off = Int(u64(tail, loc + 8))
            let rec = try await range(url, z64Off, z64Off + 55)
            guard rec.count >= 56, u32(rec, 0) == 0x06064B50 else { return nil }
            nTotal = Int(u64(rec, 32))
            cdSize = Int(u64(rec, 40))
            cdOff = Int(u64(rec, 48))
        }
        let cd = try await range(url, cdOff, cdOff + cdSize - 1)
        guard cd.count >= 4, u32(cd, 0) == 0x02014B50 else { return nil }
        var entries: [String: ZipEntry] = [:]
        var pos = 0
        while pos + 46 <= cd.count, u32(cd, pos) == 0x02014B50 {
            let method = Int(u16(cd, pos + 10))
            var csize = Int(u32(cd, pos + 20))
            var usize = Int(u32(cd, pos + 24))
            let nlen = Int(u16(cd, pos + 28)), elen = Int(u16(cd, pos + 30)), clen = Int(u16(cd, pos + 32))
            var lhofs = Int(u32(cd, pos + 42))
            let name = String(decoding: cd[pos + 46..<pos + 46 + nlen], as: UTF8.self)
            // ZIP64 extra field (0x0001): usize, csize, lhofs — only the
            // slots whose 32-bit field is 0xFFFFFFFF, in that order.
            var ep = pos + 46 + nlen
            let extraEnd = ep + elen
            while ep + 4 <= extraEnd {
                let tag = u16(cd, ep), esz = Int(u16(cd, ep + 2))
                if tag == 0x0001 {
                    var bp = ep + 4
                    if usize == 0xFFFFFFFF { usize = Int(u64(cd, bp)); bp += 8 }
                    if csize == 0xFFFFFFFF { csize = Int(u64(cd, bp)); bp += 8 }
                    if lhofs == 0xFFFFFFFF { lhofs = Int(u64(cd, bp)); bp += 8 }
                }
                ep += 4 + esz
            }
            entries[name] = ZipEntry(method: method, csize: csize, usize: usize, lhofs: lhofs)
            pos += 46 + nlen + elen + clen
        }
        return (entries, nTotal)
    }

    // MARK: - Raw deflate via the Compression framework
    //
    // COMPRESSION_ZLIB speaks RFC 1950 (zlib); a ZIP entry is RFC 1951
    // (raw deflate). The deflate payload is identical — prepend the
    // 2-byte zlib header and stop as soon as the expected byte count
    // has been produced (before the trailing adler check matters).

    private static func inflateRawDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(expectedSize)
        var stream = compression_stream()
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw FetcherError.badData("could not start the deflate decoder")
        }
        defer { compression_stream_destroy(&stream) }
        var src = [UInt8](data)
        src.insert(contentsOf: [0x78, 0x01], at: 0)
        let cap = 1 << 20
        var dst = [UInt8](repeating: 0, count: cap)
        var failed = false
        src.withUnsafeBufferPointer { srcBuf in
            stream.src_ptr = srcBuf.baseAddress!
            stream.src_size = srcBuf.count
            while out.count < expectedSize {
                var produced = 0
                dst.withUnsafeMutableBufferPointer { dstBuf in
                    stream.dst_ptr = dstBuf.baseAddress!
                    stream.dst_size = dstBuf.count
                    let status = compression_stream_process(&stream, 0)
                    produced = dstBuf.count - stream.dst_size
                    if status == COMPRESSION_STATUS_ERROR { failed = true }
                }
                if produced > 0 { out.append(contentsOf: dst[0..<produced]) }
                if failed || produced == 0 { break }
            }
        }
        guard out.count == expectedSize else {
            throw FetcherError.badData("deflate produced \(out.count) bytes, want \(expectedSize)")
        }
        return out
    }

    // MARK: - IM4P unwrap (DER walk, mirrors the proven python)

    private static func derLength(_ d: Data, _ i: inout Int) throws -> Int {
        guard i < d.count else { throw FetcherError.badData("IM4P truncated") }
        let b = d[i]; i += 1
        if b < 0x80 { return Int(b) }
        let n = Int(b & 0x7F)
        guard n >= 1, n <= 4, i + n <= d.count else { throw FetcherError.badData("IM4P has a bad DER length") }
        var v = 0
        for _ in 0..<n { v = (v << 8) | Int(d[i]); i += 1 }
        return v
    }

    private static func im4pPayload(_ d: Data) throws -> Data {
        var i = 0
        guard d.count > 6, d[i] == 0x30 else { throw FetcherError.badData("kernelcache entry is not an IM4P (no SEQUENCE)") }
        i += 1
        _ = try derLength(d, &i)
        // IA5String "IM4P", IA5String fourcc, IA5String description,
        // then the payload OCTET STRING.
        for elem in 0..<4 {
            guard i < d.count else { throw FetcherError.badData("IM4P truncated at element \(elem)") }
            let tag = d[i]; i += 1
            let len = try derLength(d, &i)
            guard i + len <= d.count else { throw FetcherError.badData("IM4P element \(elem) overruns the file") }
            if elem == 0 {
                guard tag == 0x16, String(decoding: d[i..<i + len], as: UTF8.self) == "IM4P" else {
                    throw FetcherError.badData("kernelcache entry is not an IM4P")
                }
            }
            if elem == 3 {
                guard tag == 0x04 else { throw FetcherError.badData("IM4P payload is not an OCTET STRING") }
                return Data(d[i..<i + len])
            }
            i += len
        }
        throw FetcherError.badData("IM4P has no payload element")
    }

    // MARK: - LZFSE via the Compression framework

    private static func lzfseDecompress(_ data: Data, expectedSize: Int) throws -> Data {
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
        defer { dst.deallocate() }
        let written = data.withUnsafeBytes { src -> Int in
            compression_decode_buffer(dst, expectedSize,
                                      src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                                      nil, COMPRESSION_LZFSE)
        }
        guard written == expectedSize else {
            throw FetcherError.verify("LZFSE produced \(written) bytes, want \(expectedSize)")
        }
        return Data(bytes: dst, count: expectedSize)
    }
}

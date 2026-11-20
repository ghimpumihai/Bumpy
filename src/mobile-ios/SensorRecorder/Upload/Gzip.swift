import Compression
import Foundation

/// RFC 1952 gzip without third-party code: Apple's `COMPRESSION_ZLIB` produces a raw DEFLATE
/// stream (RFC 1951); we add the 10-byte gzip header and the CRC32 + ISIZE trailer.
enum Gzip {
    enum GzipError: Error { case compressionFailed, notGzip, corrupt, crcMismatch }

    static func compress(_ input: Data) throws -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff]) // magic, deflate, no flags, mtime 0, xfl 0, OS unknown
        out.append(try deflateRaw(input))
        appendLE32(&out, CRC32.checksum(input))
        appendLE32(&out, UInt32(truncatingIfNeeded: input.count))
        return out
    }

    /// Decompresses a single-member gzip produced by `compress` (used by tests and diagnostics).
    static func decompress(_ gz: Data) throws -> Data {
        let bytes = [UInt8](gz)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { throw GzipError.notGzip }
        let flags = bytes[3]
        var pos = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard pos + 2 <= bytes.count else { throw GzipError.corrupt }
            let xlen = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
            pos += 2 + xlen
        }
        if flags & 0x08 != 0 { while pos < bytes.count && bytes[pos] != 0 { pos += 1 }; pos += 1 } // FNAME
        if flags & 0x10 != 0 { while pos < bytes.count && bytes[pos] != 0 { pos += 1 }; pos += 1 } // FCOMMENT
        if flags & 0x02 != 0 { pos += 2 } // FHCRC
        guard pos <= bytes.count - 8 else { throw GzipError.corrupt }
        let n = bytes.count
        let crc = UInt32(bytes[n - 8]) | UInt32(bytes[n - 7]) << 8 | UInt32(bytes[n - 6]) << 16 | UInt32(bytes[n - 5]) << 24
        let size = UInt32(bytes[n - 4]) | UInt32(bytes[n - 3]) << 8 | UInt32(bytes[n - 2]) << 16 | UInt32(bytes[n - 1]) << 24
        let raw = Data(bytes[pos..<(n - 8)])
        let out = try inflateRaw(raw, expectedSize: Int(size))
        guard UInt32(truncatingIfNeeded: out.count) == size else { throw GzipError.corrupt }
        guard CRC32.checksum(out) == crc else { throw GzipError.crcMismatch }
        return out
    }

    private static func appendLE32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff))
        d.append(UInt8((v >> 16) & 0xff)); d.append(UInt8((v >> 24) & 0xff))
    }

    private static func deflateRaw(_ input: Data) throws -> Data {
        if input.isEmpty {
            return Data([0x03, 0x00]) // empty final fixed-Huffman block
        }
        var capacity = input.count + input.count / 8 + 1024
        for _ in 0..<4 {
            var dst = Data(count: capacity)
            let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
                input.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                    // Non-empty buffers (checked above) always have a base address.
                    guard let dp = d.bindMemory(to: UInt8.self).baseAddress,
                          let sp = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_encode_buffer(dp, capacity, sp, input.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 {
                dst.count = written
                return dst
            }
            capacity *= 2
        }
        throw GzipError.compressionFailed
    }

    private static func inflateRaw(_ input: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var dst = Data(count: expectedSize)
        guard !input.isEmpty else { throw GzipError.corrupt }
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                guard let dp = d.bindMemory(to: UInt8.self).baseAddress,
                      let sp = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dp, expectedSize, sp, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw GzipError.corrupt }
        return dst
    }
}

/// CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) as used by gzip.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf {
                crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

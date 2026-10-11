import Foundation

/// Big-endian byte builder for the BD-ROM structures (index.bdmv,
/// MovieObject.bdmv, CLPI, MPLS) and the transport stream. Every BD-ROM
/// structure stores multi-byte values most significant byte first and
/// prefixes blocks with a length that is only known once the block is
/// written, hence `reserve` and `patch`.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    var count: Int { bytes.count }

    mutating func u8(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v)) }

    mutating func u16(_ v: Int) {
        u8(v >> 8); u8(v)
    }

    mutating func u24(_ v: Int) {
        u8(v >> 16); u8(v >> 8); u8(v)
    }

    mutating func u32(_ v: Int) {
        u8(v >> 24); u8(v >> 16); u8(v >> 8); u8(v)
    }

    mutating func append(_ b: [UInt8]) { bytes += b }

    mutating func zeros(_ n: Int) { bytes += [UInt8](repeating: 0, count: n) }

    /// Fixed-width ASCII field ("MPLS", "0200", a 5-digit clip name).
    mutating func ascii(_ s: String, length: Int) {
        var b = Array(s.utf8.prefix(length))
        b += [UInt8](repeating: 0x30, count: length - b.count)
        bytes += b
    }

    /// Placeholder for a length or address field of `width` bytes; returns
    /// its offset for `patch`.
    mutating func reserve(_ width: Int) -> Int {
        let at = bytes.count
        zeros(width)
        return at
    }

    mutating func patch(_ offset: Int, width: Int, value: Int) {
        for i in 0..<width {
            bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (width - 1 - i)))
        }
    }

    /// Writes the number of bytes after a `reserve`d length field.
    mutating func patchLength(at offset: Int, width: Int) {
        patch(offset, width: width, value: bytes.count - offset - width)
    }

    mutating func align(to n: Int) {
        while bytes.count % n != 0 { u8(0) }
    }

    var data: Data { Data(bytes) }
}

/// CRC-32/MPEG-2, used by PAT and PMT sections.
enum MPEGCRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i) << 24
        for _ in 0..<8 {
            c = (c & 0x8000_0000) != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1
        }
        return c
    }

    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(b)) & 0xFF)]
        }
        return crc
    }
}

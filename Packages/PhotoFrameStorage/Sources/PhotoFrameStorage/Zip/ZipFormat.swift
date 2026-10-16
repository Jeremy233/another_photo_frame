import Compression
import Foundation

/// ZIP 常量与底层编解码工具。只实现 `.photoframe` 需要的子集：
/// 无加密、无 ZIP64、单卷、存储（method 0）或 Deflate（method 8）。
enum ZipFormat {
    static let localHeaderSignature: UInt32 = 0x0403_4B50
    static let centralHeaderSignature: UInt32 = 0x0201_4B50
    static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50

    static let localHeaderSize = 30
    static let centralHeaderSize = 46
    static let endOfCentralDirectorySize = 22

    static let methodStored: UInt16 = 0
    static let methodDeflate: UInt16 = 8

    static let flagEncrypted: UInt16 = 1 << 0
    static let flagUTF8: UInt16 = 1 << 11

    /// versionMadeBy 高字节 3 = Unix，此时 externalAttributes 高 16 位是 st_mode。
    static let hostUnix: UInt8 = 3
    static let modeTypeMask: UInt32 = 0o170000
    static let modeSymlink: UInt32 = 0o120000
    static let modeRegular: UInt32 = 0o100000
}

// MARK: - CRC-32（IEEE 802.3，ZIP 使用的多项式）

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Raw Deflate（Compression 框架的 COMPRESSION_ZLIB 即 RFC 1951 raw deflate）

enum Deflate {
    /// 压缩；压缩后不比原数据小时返回 nil（调用方改用 stored）。
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return nil }
        out.count = written
        return out
    }

    /// 解压，输出最多 `expectedSize` 字节。
    ///
    /// 输出缓冲区只分配 `expectedSize + 1` 字节：数据实际解出更多时（声明的大小是假的，典型的 ZIP 炸弹）
    /// 会填满多出的 1 字节，从而被识别出来，内存占用始终受声明大小（已经过上限检查）约束。
    static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        let capacity = expectedSize + 1
        var out = Data(count: capacity)
        let written: Int = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src -> Int in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    srcBase, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { return nil }
        out.count = written
        return out
    }
}

// MARK: - 小端读写

extension Data {
    func readUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func readUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func slice(at offset: Int, length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else { return nil }
        return subdata(in: (startIndex + offset)..<(startIndex + offset + length))
    }

    mutating func appendUInt16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func appendUInt32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }
}

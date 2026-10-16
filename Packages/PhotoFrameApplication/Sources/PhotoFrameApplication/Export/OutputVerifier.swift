import Foundation
import PhotoFrameCore

/// 发布前检查一个输出文件的内容。默认实现只看文件头；渲染模块可以换成解码校验。
public protocol OutputVerifier: Sendable {
    func verify(_ fileURL: URL, format: OutputSettings.Format) throws(ApplicationError)
}

/// 检查文件头是否与输出格式一致：JPEG 以 `FF D8 FF` 开头，PNG 以 8 字节签名开头。
public struct SignatureOutputVerifier: OutputVerifier {
    public init() {}

    static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func signature(for format: OutputSettings.Format) -> [UInt8] {
        switch format {
        case .jpeg: jpegSignature
        case .png: pngSignature
        }
    }

    public func verify(_ fileURL: URL, format: OutputSettings.Format) throws(ApplicationError) {
        let expected = Self.signature(for: format)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw .outputMissing(fileURL.path)
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: expected.count)) ?? nil
        guard let head, [UInt8](head) == expected else {
            throw .outputFormatMismatch(fileURL.path, expected: format.rawValue.uppercased())
        }
    }
}

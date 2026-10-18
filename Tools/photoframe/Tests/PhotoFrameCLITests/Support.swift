import CoreGraphics
import Foundation
import ImageIO
import PhotoFrameApplication
@testable import PhotoFrameCLI
import PhotoFrameCore
import PhotoFrameStorage
import Synchronization
import Testing
import UniformTypeIdentifiers

// 测试只用代码合成的图片，不使用任何真实照片；所有文件都写在系统临时目录里。

/// 每个测试一个临时目录，测试结束删除。
final class Sandbox: Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "PhotoFrameCLITests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var exports: URL { root.appending(path: "Exports", directoryHint: .isDirectory) }

    /// 合成「照片」：横向渐变。8-bit 时嵌入 Display P3，16-bit TIFF 嵌入 Adobe RGB，`profile: false` 时不嵌入 ICC。
    @discardableResult
    func photo(_ name: String, width: Int, height: Int, type: UTType = .jpeg, bits: Int = 8, profile: Bool = true) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let space = CGColorSpace(name: bits == 16 ? CGColorSpace.adobeRGB1998 : CGColorSpace.displayP3)!
        let info = bits == 16
            ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info)!
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(colorSpace: space, components: [0.85, 0.35, 0.2, 1])!,
            CGColor(colorSpace: space, components: [0.15, 0.45, 0.85, 1])!,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TestFailure("写出 \(name) 失败") }
        if !profile {
            guard type == .png else { throw TestFailure("只支持去掉 PNG 的颜色描述") }
            try Self.stripPNGColorChunks(url)
        }
        return url
    }

    /// 32 位浮点 TIFF（extended 线性 sRGB），右半边亮到 4 倍 SDR 白：按 D-62 第 3 条认作 HDR。
    @discardableResult
    func hdrPhoto(_ name: String, width: Int, height: Int) throws -> URL {
        let url = root.appending(path: name)
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v: Float = x < width / 2 ? 0.5 : 4
                let i = (y * width + x) * 4
                (pixels[i], pixels[i + 1], pixels[i + 2]) = (v, v * 0.8, v * 0.6)
            }
        }
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGImageByteOrderInfo.order32Little.rawValue
        let image = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
                            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                            provider: CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw TestFailure("写出 \(name) 失败") }
        return url
    }

    /// 去掉 PNG 里所有颜色描述块（iCCP、sRGB、cICP、gAMA、cHRM），得到「无 ICC」的文件。
    static func stripPNGColorChunks(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        var out = Data(data.prefix(8))
        var i = 8
        while i + 12 <= data.count {
            let length = data[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: data[i + 4..<i + 8], as: UTF8.self)
            let end = i + 12 + length
            if !["iCCP", "sRGB", "cICP", "gAMA", "cHRM"].contains(type) { out += data[i..<end] }
            i = end
        }
        try out.write(to: url)
    }

    /// 输出根目录下的全部相对路径（含隐藏的临时目录）。
    func tree(_ dir: URL? = nil) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: (dir ?? exports).path) else { return [] }
        return (e.allObjects as? [String] ?? []).sorted()
    }
}

struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// 读出图片的像素尺寸和嵌入的 ICC 名称。
func imageInfo(_ url: URL) -> (width: Int, height: Int, profile: String?) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    else { return (0, 0, nil) }
    return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0,
            props[kCGImagePropertyProfileName] as? String)
}

/// 内存里的 stdout / stderr。
final class Capture: Sendable {
    private let text = Mutex("")
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)? = nil) {
        self.onLine = onLine
    }

    var sink: TextSink {
        TextSink { [self] chunk in
            text.withLock { $0 += chunk }
            if let onLine { for line in chunk.split(separator: "\n") { onLine(String(line)) } }
        }
    }

    var value: String { text.withLock { $0 } }
    var lines: [String] { value.split(separator: "\n").map(String.init) }

    /// stdout 上的 JSON 文档。
    func json() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            throw TestFailure("stdout 不是 JSON 对象：\(value)")
        }
        return object
    }
}

struct CLIResult {
    var status: Int32
    var stdout: Capture
    var stderr: Capture
}

/// 在进程内运行一条命令。
func runCLI(
    _ arguments: [String], in directory: URL, interrupts: InterruptMonitor = InterruptMonitor(),
    stderr: Capture = Capture(), service: CLIEnvironment.ServiceFactory? = nil
) async -> CLIResult {
    let out = Capture()
    // 本地库放在测试目录里，绝不碰真实的 App Group 库。
    var env = CLIEnvironment(stdout: out.sink, stderr: stderr.sink, currentDirectory: directory, interrupts: interrupts,
                             libraryRoot: directory.appending(path: "Library", directoryHint: .isDirectory))
    if let service { env.makeService = service }
    let status = await PhotoFrameCLI.run(arguments, environment: env)
    return CLIResult(status: status, stdout: out, stderr: stderr)
}

// MARK: - 假渲染器（只用于取消、失败等难以用真实渲染稳定触发的情况）

/// 报告进入 rendering 后一直等，直到被取消。
struct HoldingRenderer: JobRenderer {
    func render(_ job: JobRenderRequest, outputDirectory: URL, progress: RenderProgressReporter) async throws -> JobRenderResult {
        await progress.report(.plannedOutputs(1))
        await progress.report(.stage(.rendering))
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

/// 总是失败，带一个稳定错误码。
struct FailingRenderer: JobRenderer {
    func render(_ job: JobRenderRequest, outputDirectory: URL, progress: RenderProgressReporter) async throws -> JobRenderResult {
        throw ApplicationError(code: "render.decode_failed", message: "测试用的解码失败")
    }
}

/// 转发到真正的服务，只在 `submit` 之前调用 `beforeSubmit`：用来把提交卡住，或模拟提交期间按下 Ctrl-C。
final class HookedService: PhotoFrameService {
    let base: any PhotoFrameService
    let beforeSubmit: @Sendable (ExportRequest) async -> Void

    init(_ base: any PhotoFrameService, beforeSubmit: @escaping @Sendable (ExportRequest) async -> Void) {
        self.base = base
        self.beforeSubmit = beforeSubmit
    }

    func submit(_ request: ExportRequest) async throws(ApplicationError) -> [JobID] {
        await beforeSubmit(request)
        return try await base.submit(request)
    }

    func listPresets() async throws(ApplicationError) -> CatalogPresetList { try await base.listPresets() }
    func resolvePreset(_ reference: PresetReference) async throws(ApplicationError) -> CatalogPreset { try await base.resolvePreset(reference) }
    func importPreset(from fileURL: URL, replace: Bool) async throws(ApplicationError) -> CatalogPresetImport {
        try await base.importPreset(from: fileURL, replace: replace)
    }
    func exportPreset(_ reference: PresetReference, to fileURL: URL, overwrite: Bool) async throws(ApplicationError) {
        try await base.exportPreset(reference, to: fileURL, overwrite: overwrite)
    }
    func duplicatePreset(_ reference: PresetReference, name: String?) async throws(ApplicationError) -> CatalogPresetSummary {
        try await base.duplicatePreset(reference, name: name)
    }
    func renamePreset(_ reference: PresetReference, to name: String) async throws(ApplicationError) -> CatalogPresetSummary {
        try await base.renamePreset(reference, to: name)
    }
    func deletePreset(_ reference: PresetReference) async throws(ApplicationError) { try await base.deletePreset(reference) }
    func movePreset(_ reference: PresetReference, to group: PresetOrigin) async throws(ApplicationError) -> CatalogPresetSummary {
        try await base.movePreset(reference, to: group)
    }
    func updatePreset(_ reference: PresetReference, edits: [PresetEdit]) async throws(ApplicationError) -> CatalogPresetUpdate {
        try await base.updatePreset(reference, edits: edits)
    }
    func listAssets(category: AssetCategory?) async -> CatalogAssetList { await base.listAssets(category: category) }
    func resolveAsset(_ reference: String) async throws(ApplicationError) -> AssetInfo { try await base.resolveAsset(reference) }
    func importAsset(from fileURL: URL, category: AssetCategory, name: String?) async throws(ApplicationError) -> CatalogAssetImport {
        try await base.importAsset(from: fileURL, category: category, name: name)
    }
    func renameAsset(_ id: UUID, to name: String) async throws(ApplicationError) -> AssetInfo { try await base.renameAsset(id, to: name) }
    func setAssetCategory(_ id: UUID, to category: AssetCategory) async throws(ApplicationError) -> AssetInfo {
        try await base.setAssetCategory(id, to: category)
    }
    func deleteAsset(_ id: UUID) async throws(ApplicationError) -> [PersistedBinding] { try await base.deleteAsset(id) }
    func bindAsset(_ assetId: UUID?, slotId: String, preset: PresetReference?) async throws(ApplicationError) {
        try await base.bindAsset(assetId, slotId: slotId, preset: preset)
    }
    func listBindings() async -> CatalogBindingList { await base.listBindings() }
    func inspectSource(_ source: SourceReference) async throws(ApplicationError) -> SourceInspection { try await base.inspectSource(source) }
    func validate(_ request: ExportRequest) async throws(ApplicationError) -> ValidationResult { try await base.validate(request) }
    func renderPreview(_ request: ExportPreviewRequest) async throws(ApplicationError) -> ExportPreview { try await base.renderPreview(request) }
    func addSource(_ fileURL: URL) async throws(ApplicationError) -> PhotoSource { try await base.addSource(fileURL) }
    func sources() async -> [PhotoSource] { await base.sources() }
    func start() async { await base.start() }
    func pause() async { await base.pause() }
    func cancel(_ job: JobID) async throws(ApplicationError) { try await base.cancel(job) }
    func retry(_ job: JobID) async throws(ApplicationError) -> AttemptID { try await base.retry(job) }
    func status(_ job: JobID) async throws(ApplicationError) -> JobSnapshot { try await base.status(job) }
    func jobs() async -> [JobSnapshot] { await base.jobs() }
    func manifest(_ job: JobID) async throws(ApplicationError) -> OutputManifest? { try await base.manifest(job) }
    func setMaxConcurrentJobs(_ count: Int) async { await base.setMaxConcurrentJobs(count) }
    func setMemoryBudget(_ bytes: Int64?) async { await base.setMemoryBudget(bytes) }
    func removeStaleStaging(in destinationRoot: URL) async -> [URL] { await base.removeStaleStaging(in: destinationRoot) }
    func events() async -> AsyncStream<JobEvent> { await base.events() }
    func waitUntilFinished(_ jobs: [JobID]) async -> [JobSnapshot] { await base.waitUntilFinished(jobs) }
}

/// 闸门：`pass()` 一直等到 `open()`。`arrivals` 是到过闸门的次数，`returns` 由测试自己记（例如已经返回的调用数）。
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    private(set) var returns = 0

    func pass() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    func noteReturn() { returns += 1 }
}

/// 加锁的值（在 @Sendable 闭包里记录观察到的东西）。
final class Locked<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// 轮询到条件成立，最多 `seconds` 秒。
func eventually(within seconds: Int = 20, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw TestFailure("\(seconds) 秒内条件没有成立") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// 用指定渲染器（校验、预览仍用真实渲染模块）组装服务。
func serviceFactory(renderer: any JobRenderer) -> CLIEnvironment.ServiceFactory {
    { options throws(ApplicationError) in
        let catalog = try! PlatformCatalogStore.builtIn()
        let library = LocalLibrary(root: options.libraryRoot!, platforms: catalog)
        return LocalPhotoFrameService(
            renderer: renderer, analyzer: RenderingBackend(assets: library), library: library,
            configuration: QueueConfiguration(maxConcurrentJobs: options.maxConcurrentJobs ?? 2, platformCatalog: catalog))
    }
}

/// `swift test` 构建出的 `photoframe` 可执行文件（与测试包在同一个产物目录）。
/// 也可以用环境变量 `PHOTOFRAME_EXECUTABLE` 指定。
let photoframeExecutable: URL? = {
    if let path = ProcessInfo.processInfo.environment["PHOTOFRAME_EXECUTABLE"] { return URL(filePath: path) }
    let testBundle = Bundle(for: Sandbox.self).bundleURL
    let url = testBundle.deletingLastPathComponent().appending(path: "photoframe")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}()

/// 以子进程运行 `photoframe`。
func runProcess(_ arguments: [String], in directory: URL, beforeWait: ((Process, Pipe) -> Void)? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
    guard let exe = photoframeExecutable else { throw TestFailure("找不到 photoframe 可执行文件") }
    let process = Process()
    process.executableURL = exe
    process.arguments = arguments
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment
    environment["PHOTOFRAME_LIBRARY"] = directory.appending(path: "Library").path
    process.environment = environment
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    beforeWait?(process, err)
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
}

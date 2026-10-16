import CoreGraphics
import Foundation
import ImageIO
import PhotoFrameCore
import PhotoFrameRendering
import PhotoFrameStorage
import Synchronization
import UniformTypeIdentifiers

/// 用 PhotoFrameRendering 实现应用层的两个协议：任务队列的 ``JobRenderer`` 和服务的 ``ImageAnalyzer``。
/// ``LocalPhotoFrameService/makeDefault(_:)`` 用它组装 GUI、CLI、MCP 共用的服务。
///
/// 适配要点：
/// - **类型**：应用层的 `JobRenderRequest` / `JobOutputRole`… 与渲染层的 `RenderJob` / `OutputRole`… 一一对应，
///   这里做转换。渲染层的 `.single` 与 `.cover` 都是轮播位置 0（应用层 `.cover`），切片 k 是位置 k + 1（D-27）。
/// - **进度**：渲染层用同步闭包报告 `RenderProgress` 快照，应用层要 `await` 逐条报告事件。快照先在同步闭包里
///   翻译成事件（只前进的阶段、计划输出数、每个完成的输出），按顺序放进一条 `AsyncStream`，由一个消费者依次
///   `await` 报告；渲染返回前等消费者把事件全部报告完，所以队列看到的顺序与渲染器产生的顺序一致。
/// - **文件名**：渲染层写 `00.<ext>`、`01.<ext>`…，发布时由 `AtomicExporter` 按角色改名为 `00_Cover.jpg`、
///   `01_Slide.jpg`…（D-46～D-48）。
/// - **错误**：`RenderError` 转成同 code 的 `ApplicationError`；取消原样抛出。
public struct RenderingBackend: JobRenderer, ImageAnalyzer {
    public let renderer: PhotoFrameRenderer
    public let assets: any AssetProvider

    public init(renderer: PhotoFrameRenderer = PhotoFrameRenderer(), assets: any AssetProvider = NoAssetLibrary()) {
        self.renderer = renderer
        self.assets = assets
    }

    // MARK: - JobRenderer

    public func render(_ request: JobRenderRequest, outputDirectory: URL, progress: RenderProgressReporter) async throws -> JobRenderResult {
        let job = renderJob(request, outputDirectory: outputDirectory)
        let translator = ProgressTranslator(preset: request.preset)
        let (events, continuation) = AsyncStream.makeStream(of: JobRenderProgress.self)
        let forwarder = Task {
            for await event in events { await progress.report(event) }
        }
        let result: RenderResult
        do {
            result = try await renderer.render(job: job) { snapshot in
                for event in translator.translate(snapshot) { continuation.yield(event) }
            }
        } catch {
            continuation.finish()
            await forwarder.value
            throw Self.mapped(error)
        }
        continuation.finish()
        await forwarder.value

        return JobRenderResult(
            outputs: result.outputs.map {
                JobRenderedOutput(role: JobOutputRole($0.role), fileURL: $0.fileURL, pixelSize: $0.pixelSize, colorProfile: $0.colorProfile)
            },
            warnings: result.warnings.map(ApplicationWarning.init))
    }

    func renderJob(_ request: JobRenderRequest, outputDirectory: URL) -> RenderJob {
        let (assetFiles, skipped) = request.slots.map {
            RenderJob.assets(from: $0, fileURL: assets.fileURL(for:))
        } ?? ([:], [])
        return RenderJob(
            sourceURL: request.source.fileURL, preset: request.preset, assets: assetFiles, skippedLayerIds: skipped,
            outputDirectory: outputDirectory, sourceColorOverride: request.sourceColorOverride,
            maxCarouselItems: request.platform?.maxCarouselItems)
    }

    // MARK: - ImageAnalyzer

    public func inspect(_ fileURL: URL) async throws -> SourceInspection {
        let info: InspectedSource
        do {
            info = try renderer.inspect(fileURL)
        } catch {
            throw Self.mapped(error)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
        return SourceInspection(
            fileURL: fileURL, fileSizeBytes: size, format: info.format, pixelSize: info.pixelSize,
            orientation: info.orientation.rawValue, displaySize: info.displaySize, bitDepth: info.bitDepth,
            isFloat: info.isFloat, hasAlpha: info.hasAlpha,
            colorProfile: .init(embedded: info.hasEmbeddedProfile, description: info.sourceProfile, origin: info.sourceProfileOrigin),
            hdr: .init(kind: info.hdrKind.rawValue, headroom: info.hdrHeadroom),
            metadata: info.metadata, hasGPS: info.hasGPS, hasAuthorOrCopyright: info.hasAuthorOrCopyright,
            warnings: info.warnings.map(ApplicationWarning.init))
    }

    public func plan(_ request: JobRenderRequest) async throws -> ExportPlan {
        do {
            let plan = try renderer.plan(sourceURL: request.source.fileURL, preset: request.preset,
                                         maxCarouselItems: request.platform?.maxCarouselItems)
            return ExportPlan(
                outputs: plan.pages.map { PlannedOutput(role: JobOutputRole($0.role), pixelSize: $0.pixelSize) },
                warnings: plan.warnings.map(ApplicationWarning.init))
        } catch {
            throw Self.mapped(error)
        }
    }

    public func preview(_ request: JobRenderRequest, options: PreviewOptions) async throws -> ExportPreview {
        let job = renderJob(request, outputDirectory: FileManager.default.temporaryDirectory)
        let result: PreviewResult
        do {
            result = try await renderer.renderPreview(PreviewRequest(
                job: job, size: .maxLongEdge(options.maxLongEdge), pages: options.pages, color: .sRGB))
        } catch {
            throw Self.mapped(error)
        }
        let pages = try result.pages.map { page in
            PreviewImage(role: JobOutputRole(page.role), pixelSize: page.pixelSize, exportPixelSize: page.exportPixelSize,
                         pngData: try Self.pngData(page.image))
        }
        return ExportPreview(pages: pages, roles: result.roles.map(JobOutputRole.init),
                             warnings: result.warnings.map(ApplicationWarning.init))
    }

    /// 预览位图（8-bit sRGB）编码成 PNG，带 sRGB 颜色描述。
    static func pngData(_ image: CGImage) throws(ApplicationError) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ApplicationError(code: "render.preview_failed", message: "无法创建 PNG 编码器")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ApplicationError(code: "render.preview_failed", message: "PNG 编码失败")
        }
        return data as Data
    }

    static func mapped(_ error: any Error) -> any Error {
        switch error {
        case let e as RenderError: ApplicationError(code: e.code, message: e.message, hint: e.hint)
        default: error
        }
    }
}

extension JobOutputRole {
    /// 渲染层角色 → 轮播位置（D-27）。
    public init(_ role: OutputRole) {
        switch role {
        case .single, .cover: self = .cover
        case .slide(let k): self = .slide(position: k + 1)
        }
    }
}

extension JobRenderStage {
    init(_ stage: RenderStage) {
        switch stage {
        case .decoding: self = .decoding
        case .rendering: self = .rendering
        case .encoding: self = .encoding
        }
    }
}

extension ApplicationWarning {
    init(_ warning: RenderWarning) {
        var message = warning.message
        if let page = warning.page { message += "（第 \(page) 页）" }
        if let layer = warning.layerId { message += "（图层 \(layer)）" }
        self.init(code: warning.code, message: message)
    }
}

/// 把渲染层的进度快照翻译成应用层事件。
///
/// - 阶段只前进：已经报告过的阶段或更早的阶段不再报告（队列已处于 `decoding`，所以从 `rendering` 起报告）。
/// - 计划输出数第一次出现或变化时报告一次。
/// - `completedOutputs` 每增加 1 报告一个 `.outputFinished`，角色按轮播顺序推算：渲染器按封面在前、切片按序号写出，
///   预设没有封面时第一页就是第 1 张切片。
final class ProgressTranslator: Sendable {
    private struct State {
        var stage = 0
        var planned: Int?
        var completed = 0
    }

    private let state = Mutex(State())
    private let hasCover: Bool

    init(preset: ExportPreset) {
        hasCover = !preset.panorama.enabled || preset.panorama.cover
    }

    static let stageOrder: [RenderStage] = [.decoding, .rendering, .encoding]

    /// 第 `index` 个写出的文件（0 起）的轮播角色。
    func role(at index: Int) -> JobOutputRole {
        if hasCover { return index == 0 ? .cover : .slide(position: index) }
        return .slide(position: index + 1)
    }

    func translate(_ snapshot: RenderProgress) -> [JobRenderProgress] {
        state.withLock { s in
            var events: [JobRenderProgress] = []
            if let total = snapshot.totalOutputs, total != s.planned {
                s.planned = total
                events.append(.plannedOutputs(total))
            }
            while s.completed < snapshot.completedOutputs {
                events.append(.outputFinished(role(at: s.completed)))
                s.completed += 1
            }
            if let index = Self.stageOrder.firstIndex(of: snapshot.stage), index > s.stage {
                s.stage = index
                events.append(.stage(JobRenderStage(snapshot.stage)))
            }
            return events
        }
    }
}

import Foundation
import PhotoFrameCore
import PhotoFrameRendering
import PhotoFrameStorage
import Testing
@testable import PhotoFrameApplication

/// D-135：手填的胶卷、相机与参数从请求一路传到渲染。
@Suite("手填元数据（D-135）")
struct MetadataOverrideTests {
    static let preset = ExportPreset(
        name: "M", canvas: CanvasSettings(width: 1080, height: 1440, background: .defaultBackground, minMarginPx: 60, mode: .fit),
        layers: [OverlayLayer(layerId: "logo", type: .brandLogo), OverlayLayer(layerId: "film", type: .filmIcon)])

    @Test("任务和导出请求带上手填的值；旧的任务记录、请求没有这个字段时为空")
    func codable() throws {
        let source = PhotoSource(fileURL: URL(filePath: "/x/scan.tif"))
        let spec = JobSpec(source: source, preset: Self.preset, destination: ExportDestination(rootDirectory: URL(filePath: "/out")),
                           metadataOverrides: ["film": "Kodak Gold 200", "make": "Mamiya", "model": "7"])
        let again = try JSONDecoder().decode(JobSpec.self, from: JSONEncoder().encode(spec))
        #expect(again == spec)

        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as! [String: Any]
        old.removeValue(forKey: "metadataOverrides")
        let decoded = try JSONDecoder().decode(JobSpec.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.metadataOverrides.isEmpty && decoded.preset == spec.preset)

        let request = ExportRequest(sourceIds: [], presets: [Self.preset], destination: spec.destination,
                                    metadataOverrides: ["iso": "400"])
        #expect(try JSONDecoder().decode(ExportRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test("渲染任务带上手填的值；素材槽匹配用手填的相机")
    func reachesRenderer() {
        let request = JobRenderRequest(jobId: JobID(), attemptId: AttemptID(), source: PhotoSource(fileURL: URL(filePath: "/x/scan.tif")),
                                       preset: Self.preset, metadataOverrides: ["make": "Leica"])
        let job = RenderingBackend().renderJob(request, outputDirectory: URL(filePath: "/tmp"))
        #expect(job.metadataOverrides == ["make": "Leica"])
        let camera = ExportChecks.camera(of: URL(filePath: "/x/missing.tif"), overrides: ["make": " Leica ", "model": ""])
        #expect(camera.make == "Leica" && camera.model == nil)
        // 品牌、型号都手填了：不读文件，去掉首尾空白。
        #expect(ExportChecks.camera(of: URL(filePath: "/x/missing.tif"), overrides: ["make": " Leica ", "model": " M6\n"])
            == CameraIdentity(make: "Leica", model: "M6"))
    }

    @Test("单任务绑定内置素材（D-139）：解析时不算失效绑定，渲染器拿到内置素材的内容地址")
    func builtInAssetBinding() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BuiltInBinding-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalLibrary(root: root, platforms: try PlatformCatalogStore.builtIn())
        var preset = Self.preset
        preset.layers[0].logo = BrandLogoStyle(brand: BrandLogoStyle.fromSlot)
        preset.layers[0].slotId = "logo"
        preset.assetSlots = [AssetSlot(slotId: "logo", label: "品牌 logo")]
        let leica = try #require(BuiltInAsset.asset(path: "cameras/leica/leica.svg"))

        let (slots, warnings) = try ExportChecks.resolveSlots(library.slotResolver(), preset: preset, bindings: ["logo": leica.id],
                                                              source: URL(filePath: "/x/scan.tif"))
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(slots?.resolved["logo"]?.asset.assetId == leica.id)
        let request = JobRenderRequest(jobId: JobID(), attemptId: AttemptID(), source: PhotoSource(fileURL: URL(filePath: "/x/scan.tif")),
                                       preset: preset, slots: slots)
        let job = RenderingBackend(assets: library).renderJob(request, outputDirectory: URL(filePath: "/tmp"))
        #expect(job.assets["logo"] == RenderAsset(fileURL: leica.contentURL, format: .svg))
    }
}


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
    }
}

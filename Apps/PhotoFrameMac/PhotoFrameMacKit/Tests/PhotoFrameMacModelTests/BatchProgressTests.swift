import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameMacModel
import Testing

@Suite struct BatchProgressTests {
    private func record(_ status: JobStatus, completed: Int = 0, planned: Int? = nil) -> JobRecord {
        var r = JobRecord(spec: JobSpec(
            source: PhotoSource(fileURL: URL(filePath: "/tmp/a.jpg")),
            preset: ExportPreset(name: "P", canvas: CanvasSettings(width: 1080, height: 1350)), destination: ExportDestination(rootDirectory: URL(filePath: "/tmp"))))
        r.currentAttempt.status = status
        r.currentAttempt.progress = JobProgress(stage: status, completedOutputs: completed, plannedOutputs: planned)
        return r
    }

    @Test func realProgressOnly() {
        let p = BatchProgress([
            record(.completed, completed: 1, planned: 1),
            record(.failed),
            record(.encoding, completed: 2, planned: 8),
            record(.queued),
        ])
        #expect(p.totalJobs == 4 && p.finishedJobs == 2 && p.failedJobs == 1)
        #expect(p.completedOutputs == 3 && p.plannedOutputs == 9)
        #expect(p.fraction == (2 + 0.25) / 4)
        #expect(p.isRunning)
        #expect(BatchProgress([]).fraction == 0)
    }
}

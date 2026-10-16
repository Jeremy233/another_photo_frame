import PhotoFrameApplication

/// 把任务事件写成 stderr 上的进度行。只报告真实阶段与已完成的输出数，不估算百分比（§9.1）。
///
/// ```text
/// [1/2] Badlands.tif × Instagram Panorama: decoding
/// [1/2] Badlands.tif × Instagram Panorama: rendering (0/5)
/// [1/2] Badlands.tif × Instagram Panorama: encoding 1/5
/// [1/2] Badlands.tif × Instagram Panorama: completed → /…/Instagram/Badlands_Panorama
/// ```
struct ProgressPrinter {
    var sink: TextSink
    /// 本次提交的任务数；全部结束后停止读取事件。
    var expected: Int

    func consume(_ events: AsyncStream<JobEvent>) async {
        var labels: [JobID: String] = [:]
        var lastCompleted: [JobID: Int] = [:]
        var finished = 0
        for await event in events {
            switch event {
            case .jobAdded(let record):
                labels[record.jobId] = "[\(labels.count + 1)/\(expected)] \(record.spec.source.displayName) × \(record.spec.preset.name)"
            case .statusChanged(let id, _, let status) where !status.isTerminal && status != .queued:
                guard let label = labels[id] else { continue }
                sink.line("\(label): \(status.rawValue)")
            case .progress(let id, _, let progress):
                guard let label = labels[id], let planned = progress.plannedOutputs,
                      progress.completedOutputs != lastCompleted[id] ?? 0 else { continue }
                lastCompleted[id] = progress.completedOutputs
                sink.line("\(label): \(progress.stage.rawValue) \(progress.completedOutputs)/\(planned)")
            case .attemptFinished(let record):
                guard let label = labels[record.jobId] else { continue }
                switch record.status {
                case .completed:
                    sink.line("\(label): completed → \(record.manifest?.directory.path ?? "")")
                case .failed:
                    sink.line("\(label): failed [\(record.error?.code ?? "unknown")]")
                default:
                    sink.line("\(label): \(record.status.rawValue)")
                }
                finished += 1
                if finished >= expected { return }
            default:
                continue
            }
        }
    }
}

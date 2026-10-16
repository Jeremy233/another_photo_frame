import ArgumentParser
import Foundation
import PhotoFrameApplication
import PhotoFrameCore

/// `photoframe export <图片...> --preset … --output <目录>`（§11.3）。
///
/// 流程：解析预设 → 登记源图 → 校验（不通过就什么都不写）→ 提交任务 → 阻塞到全部结束（§10.3）。
/// Ctrl-C 取消所有未完成的任务，队列删除它们的临时目录。
struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "按预设导出图片（每张图 × 每个预设一个任务）。",
        discussion: """
            输出到 <输出目录>/<平台>/<源文件名>_<Standard|Panorama>/00_Cover.jpg、01_Slide.jpg…。
            作品目录已存在时默认加 _v2、_v3…；--overwrite 只替换本软件之前导出的目录（D-49）。
            stdout 每行一个写出的文件路径（--json 时为结构化结果）；进度写到 stderr。
            """)

    @Argument(help: ArgumentHelp("源图（JPEG / PNG / TIFF）。", valueName: "图片"))
    var images: [String]

    @Option(name: .long, help: ArgumentHelp(
        "预设：presetId、名称（如 instagram-panorama）或 .photoframe 文件。可重复。", valueName: "id|名称|文件"))
    var preset: [String] = []

    @Option(name: [.short, .long], help: ArgumentHelp("输出根目录，不存在时创建。", valueName: "目录"))
    var output: String

    @Option(name: .customLong("assume-profile"), help: AssumedProfile.help)
    var assumeProfile: AssumedProfile?

    @Flag(help: "作品目录已存在时替换本软件之前导出的目录，而不是加版本后缀（D-49）。")
    var overwrite = false

    @Flag(name: .customLong("dry-run"), help: "只校验并列出将要写出的文件，不渲染、不写任何文件。")
    var dryRun = false

    @Flag(help: "stdout 输出 JSON。")
    var json = false

    @Flag(name: [.short, .long], help: "不在 stderr 显示进度。")
    var quiet = false

    @Option(name: .long, help: ArgumentHelp("同时执行的任务数（默认按 CPU 核数，D-53）。", valueName: "n"))
    var jobs: Int?

    func validate() throws {
        guard !images.isEmpty else { throw ValidationError("至少需要一张图片。") }
        guard !preset.isEmpty else { throw ValidationError("至少需要一个 --preset。") }
        if let jobs, jobs < 1 { throw ValidationError("--jobs 应为正整数。") }
    }

    func run() async throws {
        let ctx = CommandContext(command: "export", json: json)
        let env = ctx.env
        let service = try ctx.makeService(.init(maxConcurrentJobs: jobs))

        // 1. 预设（按给出顺序，重复的只算一次）
        var presets: [ExportPreset] = []
        for reference in preset {
            let entry: CatalogPreset
            do {
                entry = try await service.resolvePreset(PresetReference(argument: reference, relativeTo: env.currentDirectory))
            } catch {
                throw ctx.fail(error)
            }
            ctx.warn(entry.warnings, prefix: "\(entry.preset.name): ")
            if !presets.contains(where: { $0.presetId == entry.preset.presetId }) { presets.append(entry.preset) }
        }

        // 2. 源图
        var sourceIds: [SourceID] = []
        for image in images {
            do {
                let source = try await service.addSource(env.resolvePath(image))
                if !sourceIds.contains(source.sourceId) { sourceIds.append(source.sourceId) }
            } catch {
                throw ctx.fail(error)
            }
        }

        let request = ExportRequest(
            sourceIds: sourceIds, presets: presets,
            destination: ExportDestination(rootDirectory: env.resolvePath(output), conflictPolicy: overwrite ? .overwrite : .versionSuffix),
            sourceColorOverride: assumeProfile?.override)

        // 3. 校验
        let validation: ValidationResult
        do {
            validation = try await service.validate(request)
        } catch {
            throw ctx.fail(error)
        }
        if dryRun {
            try reportDryRun(validation, ctx: ctx)
            return
        }
        // 校验阶段的警告不在这里输出：任务执行时会再次得到，随任务结果一起报告。
        guard validation.isValid else { throw reportInvalid(validation, ctx: ctx) }
        try await export(request, service: service, ctx: ctx)
    }

    /// 校验没通过：每个问题写到 stderr，`--json` 时输出 dry-run 格式的结果；退出码取第一个错误的类别。
    private func reportInvalid(_ validation: ValidationResult, ctx: CommandContext) -> CLIExit {
        let errors = validation.errors
        let status = errors.first.map(PhotoFrameExitCode.init(for:)) ?? .invalidInput
        for item in validation.items {
            for error in item.errors {
                ctx.log("error: \(item.sourceURL.lastPathComponent) × \(item.presetName): [\(error.code)] \(error.message)")
                if let hint = error.hint { ctx.log("hint: \(hint)") }
            }
        }
        if ctx.json {
            ctx.emit(DryRunResultJSON(dryRun: false, valid: false, jobs: validation.items.map(DryRunJobJSON.init)),
                     status: status, error: errors.first)
        }
        return CLIExit(status: status)
    }

    private func reportDryRun(_ validation: ValidationResult, ctx: CommandContext) throws {
        let status = validation.errors.first.map(PhotoFrameExitCode.init(for:)) ?? .success
        if ctx.json {
            ctx.emit(DryRunResultJSON(valid: validation.isValid, jobs: validation.items.map(DryRunJobJSON.init)),
                     status: status, error: validation.errors.first)
        } else {
            for item in validation.items {
                ctx.warn(item.warnings, prefix: "\(item.sourceURL.lastPathComponent) × \(item.presetName): ")
                for error in item.errors {
                    ctx.log("error: \(item.sourceURL.lastPathComponent) × \(item.presetName): [\(error.code)] \(error.message)")
                    if let hint = error.hint { ctx.log("hint: \(hint)") }
                }
                for file in item.outputs {
                    ctx.env.stdout.line(item.directory.appending(path: file.fileName).path)
                }
            }
        }
        if status != .success { throw CLIExit(status: status) }
    }

    // MARK: - 导出

    private func export(_ request: ExportRequest, service: any PhotoFrameService, ctx: CommandContext) async throws {
        let env = ctx.env
        if env.interrupts.isTriggered { throw CLIExit(status: .interrupted) }

        let expected = request.sourceIds.count * request.presets.count
        let events = await service.events()
        let printer: Task<Void, Never>? = quiet ? nil : Task { await ProgressPrinter(sink: env.stderr, expected: expected).consume(events) }

        let ids: [JobID]
        do {
            ids = try await service.submit(request)
        } catch {
            printer?.cancel()
            throw ctx.fail(error)
        }
        env.interrupts.onInterrupt {
            Task {
                for id in ids { try? await service.cancel(id) }
            }
        }
        let records = await service.waitUntilFinished(ids)
        await printer?.value

        let interrupted = env.interrupts.isTriggered && records.contains { $0.status == .canceled }
        let failed = records.filter { $0.status == .failed }
        let status: PhotoFrameExitCode = interrupted ? .interrupted : failed.isEmpty ? .success : .jobFailed

        for record in records {
            ctx.warn(record.currentAttempt.warnings, prefix: "\(record.spec.source.displayName) × \(record.spec.preset.name): ")
            if let error = record.error, record.status == .failed {
                ctx.log("error: \(record.spec.source.displayName) × \(record.spec.preset.name): [\(error.code)] \(error.message)")
                if let hint = error.hint { ctx.log("hint: \(hint)") }
            }
        }
        if interrupted { ctx.log("已中断：未完成的任务已取消，临时文件已清理。") }

        if ctx.json {
            ctx.emit(ExportResultJSON(jobs: records.map(ExportJobJSON.init)), status: status, error: failed.first?.error)
        } else {
            for record in records where record.status == .completed {
                for item in record.manifest?.items ?? [] { env.stdout.line(item.fileURL.path) }
            }
        }
        if status != .success { throw CLIExit(status: status) }
    }
}

import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
var args = Array(CommandLine.arguments.dropFirst())
let fixtures = FixtureSet(dir: root.appendingPathComponent("fixtures"))
let env = Env(fixtures: fixtures, out: root.appendingPathComponent("out"))

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch args.first {
case "fixtures":
    try fixtures.generate()
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    for f in try FileManager.default.contentsOfDirectory(at: fixtures.dir, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        if let i = fileInfo(f) { print(String(data: try enc.encode(i), encoding: .utf8)!) }
    }
case "run":
    let only = option("--only")
    let R = Results()
    R.line("# ColorPoC 运行结果")
    R.line()
    R.line("生成时间：\(ISO8601DateFormatter().string(from: Date()))；系统：\(ProcessInfo.processInfo.operatingSystemVersionString)")
    R.line()
    let steps: [(String, (Env, Results) throws -> Void)] = [
        ("chart", runChart), ("wide", runWide), ("gradient", runGradient),
        ("alpha", runAlpha), ("orientation", runOrientation), ("hdr", runHDR),
        ("probes", runProbes),   // 放最后：P9 要读前面各步的输出文件
    ]
    for (name, f) in steps where only == nil || only!.split(separator: ",").contains(Substring(name)) {
        let t = Date()
        try f(env, R)
        FileHandle.standardError.write("[\(name)] \(String(format: "%.1f", Date().timeIntervalSince(t)))s\n".data(using: .utf8)!)
    }
    if let real = option("--real") { try runReal(env, R, dir: URL(fileURLWithPath: real)) }
    try FileManager.default.createDirectory(at: env.out, withIntermediateDirectories: true)
    let suffix = only.map { "-" + $0.replacingOccurrences(of: ",", with: "+") } ?? ""
    try R.md.joined(separator: "\n").write(to: env.out.appendingPathComponent("results\(suffix).md"), atomically: true, encoding: .utf8)
    let data = try JSONSerialization.data(withJSONObject: R.json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: env.out.appendingPathComponent("results\(suffix).json"))
default:
    print("""
    usage:
      colorpoc fixtures                 生成 fixtures/ 下的测试图
      colorpoc run [--only a,b] [--real <dir>]
                                        跑全部实验（probes,chart,wide,gradient,alpha,orientation,hdr），
                                        结果写到 out/results*.md|json；--real 额外跑本地真实照片目录（不入库）
    """)
}

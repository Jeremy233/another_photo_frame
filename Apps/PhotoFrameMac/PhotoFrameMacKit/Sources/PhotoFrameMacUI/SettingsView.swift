import PhotoFrameApplication
import PhotoFrameMacModel
import SwiftUI

/// ⌘, 设置窗口（D-114）。版式参照 Compressor 的设置：顶部「通用 | 高级」两个工具栏标签，
/// 下面是右对齐标签的表单。界面跟随应用固定深色（D-105），控件全部是系统样式，强调色跟随系统（D-112）。
struct SettingsView: View {
    @Bindable var workbench: Workbench

    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") {
                GeneralSettings(settings: $workbench.settings)
            }
            Tab("高级", systemImage: "gearshape.2") {
                AdvancedSettings(settings: $workbench.settings)
            }
        }
        .frame(width: 500)
        .fixedSize()
        .background(Palette.panel)
    }
}

private struct GeneralSettings: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Toggle(isOn: $settings.switchesToActiveAfterStart) {
                Text("切到「活跃」")
            }
            .help("已提交的任务总会离开「当前」；关掉后界面留在「当前」")
            .formLabel("开始批处理后：")
        }
        .formStyle(.columns)
        .padding(20)
    }
}

private struct AdvancedSettings: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("同时执行的任务：", selection: $settings.maxConcurrentJobs) {
                    Text("自动（\(QueueConfiguration.defaultMaxConcurrentJobs)）").tag(Int?.none)
                    Divider()
                    ForEach(AppSettings.concurrencyChoices, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
                .fixedSize()
                Picker("内存预算：", selection: $settings.memoryBudgetGiB) {
                    Text("自动（\(Self.gib(QueueConfiguration.defaultMemoryBudgetBytes))）").tag(Int?.none)
                    Divider()
                    ForEach(AppSettings.memoryChoicesGiB, id: \.self) { Text("\($0) GB").tag(Int?.some($0)) }
                }
                .fixedSize()
                Text("运行中修改立即生效：调低时正在执行的任务继续做完，之后按新的设置派发。自动 = 性能核数的一半（1–4）、物理内存的一半。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 300, alignment: .leading)
            }
            Section {
                Button("恢复默认设置") {
                    settings.maxConcurrentJobs = nil
                    settings.memoryBudgetGiB = nil
                }
                .disabled(settings.maxConcurrentJobs == nil && settings.memoryBudgetGiB == nil)
            }
        }
        .formStyle(.columns)
        .padding(20)
    }

    private static func gib(_ bytes: Int64) -> String {
        String(format: "%.0f GB", Double(bytes) / Double(1 << 30))
    }
}

private extension View {
    /// `.columns` 表单里给没有自带标签的控件加右侧对齐的标签。
    func formLabel(_ title: String) -> some View {
        LabeledContent { self } label: { Text(title) }
    }
}

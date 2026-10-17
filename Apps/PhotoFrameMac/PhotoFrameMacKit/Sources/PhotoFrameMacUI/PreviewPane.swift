import AppKit
import ImageIO
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameMacModel
import SwiftUI

/// 中间栏上方的预览（UI 设计文档第 9 节）：封面 / 切片 / 全景长卷，缩放，原图 / 成品，SDR / HDR。
/// 成品图像全部来自后端的 `renderPreview`；这里只负责显示。
///
/// 版式参照 Compressor 的预览区：上面一行标题（源图 - 预设）+ 右侧缩放与「显示」菜单，
/// 下面一行在 Compressor 是时间轴和播放控制，这里换成翻页（封面、切片、全景长卷）。
struct PreviewPane: View {
    let workbench: Workbench
    @Bindable var preview: PreviewModel
    @State private var enlarged = false

    var body: some View {
        VStack(spacing: 0) {
            PreviewTitleBar(preview: preview)
            Hairline()
            ZStack {
                Palette.preview
                canvas
                if preview.isRendering {
                    ProgressView().controlSize(.small).padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .onTapGesture(count: 2) { if preview.subject != nil { enlarged = true } }
            Hairline()
            PreviewPageBar(preview: preview, note: statusNote)
        }
        .background(Palette.panel)
        .sheet(isPresented: $enlarged) {
            canvas
                .frame(minWidth: 900, minHeight: 700)
                .overlay(alignment: .topTrailing) {
                    Button("关闭") { enlarged = false }.keyboardShortcut(.cancelAction).padding()
                }
        }
    }

    @ViewBuilder private var canvas: some View {
        if let subject = preview.subject {
            if preview.showsOriginal || subject.preset == nil {
                OriginalImage(url: subject.sourceURL, preview: preview)
            } else if preview.page == .strip {
                PanoramaStrip(pages: preview.strip, showsSeams: preview.showsSeams, preview: preview)
            } else if let page = preview.pageImage {
                PageImage(page: page, preview: preview)
            } else if let error = preview.error {
                ContentUnavailableView("无法预览", systemImage: "exclamationmark.triangle", description: Text(error.message))
            }
        } else {
            ContentUnavailableView("没有预览", systemImage: "photo", description: Text("选中一个任务或源图"))
        }
    }

    private var statusNote: String? {
        let notes = preview.warnings.map(\.message)
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }
}

/// 预览上方一行：标题居中，右侧是原图对比、缩放、「显示」菜单。
private struct PreviewTitleBar: View {
    @Bindable var preview: PreviewModel

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .help(title)
            HStack(spacing: 10) {
                // 带文字的分段控件：一眼看出是在两种画面间切换、现在显示的是哪一种（分屏图标会让人以为是左右对比）。
                Picker("对比", selection: $preview.showsOriginal) {
                    Text("成品").tag(false)
                    Text("原图").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(preview.subject?.preset == nil)
                .help("在导出效果和原图之间切换")
                ZoomMenu(preview: preview)
                Menu("显示") {
                    Picker("对比", selection: $preview.showsOriginal) {
                        Text("成品").tag(false)
                        Text("原图").tag(true)
                    }
                    Picker("动态范围", selection: $preview.range) {
                        Text("SDR").tag(PreviewRange.sdr)
                        Text("HDR").tag(PreviewRange.hdr)
                    }
                    Toggle("显示接缝位置", isOn: $preview.showsSeams)
                }
                .fixedSize()
            }
        }
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private var title: String {
        guard let subject = preview.subject else { return "" }
        let name = subject.sourceURL.lastPathComponent
        return subject.preset.map { "\(name) - \($0.name)" } ?? name
    }
}

/// 预览下方一行：翻页（封面、切片 1…N、全景长卷），左侧是预览提示，右侧是 SDR / HDR。
private struct PreviewPageBar: View {
    @Bindable var preview: PreviewModel
    let note: String?

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Button { step(-1) } label: { Image(systemName: "chevron.backward") }
                    .disabled(index <= 0)
                Picker("页面", selection: $preview.page) {
                    ForEach(preview.roles, id: \.self) { role in
                        Text(role.shortTitle).tag(PreviewPage.page(role.carouselPosition))
                    }
                    if preview.hasStrip { Text("全景长卷").tag(PreviewPage.strip) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button { step(1) } label: { Image(systemName: "chevron.forward") }
                    .disabled(index < 0 || index >= preview.roles.count - 1)
            }
            .disabled(preview.roles.count < 2)
            HStack {
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(note)
                        .frame(maxWidth: 260, alignment: .leading)
                }
                Spacer()
                Picker("动态范围", selection: $preview.range) {
                    Text("SDR").tag(PreviewRange.sdr)
                    Text("HDR").tag(PreviewRange.hdr)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    /// 当前页在轮播中的位置；全景长卷时为 -1。
    private var index: Int {
        if case .page(let n) = preview.page { n } else { -1 }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        if next >= 0, next < preview.roles.count { preview.page = .page(next) }
    }
}

/// 缩放菜单：标题显示当前比例。快捷键在菜单栏「显示」菜单里（⌘+ / ⌘- / ⌘0 / ⌘9）。
private struct ZoomMenu: View {
    let preview: PreviewModel

    var body: some View {
        // 没有画面时比例没有意义，只显示「适合窗口」。
        Menu(preview.subject == nil && preview.zoom == .fit ? "适合窗口" : preview.zoomTitle) {
            Button("适合窗口") { preview.zoom = .fit }
            Button("实际大小（100%）") { preview.zoom = .actualSize }
            Divider()
            Button("放大") { preview.zoomIn() }
            Button("缩小") { preview.zoomOut() }
            Divider()
            ForEach(PreviewZoom.steps, id: \.self) { scale in
                Button("\(Int((scale * 100).rounded()))%") { preview.zoom = .scale(scale) }
            }
        }
        .fixedSize()
        .help("缩放：适合窗口、100%、放大缩小，也可以在触控板上捏合")
    }
}

/// 可缩放的画面：「适合窗口」时整个内容放进预览区，其余比例按屏幕像素显示，超出时可以滚动查看；支持触控板捏合。
/// `contentPixels` 是内容在 100% 时的像素尺寸；`content` 拿到显示尺寸（pt）后画出内容。
private struct ZoomCanvas<Content: View>: View {
    let preview: PreviewModel
    let contentPixels: CGSize
    @ViewBuilder var content: (CGSize) -> Content
    @Environment(\.displayScale) private var displayScale
    @State private var pinchBase: Double?

    var body: some View {
        GeometryReader { geo in
            let fit = PreviewZoom.fitScale(contentPixels: contentPixels, in: geo.size, displayScale: displayScale)
            let scale = preview.zoom == .fit ? fit : preview.effectiveScale
            let size = CGSize(width: contentPixels.width * scale / displayScale, height: contentPixels.height * scale / displayScale)
            ScrollView([.horizontal, .vertical]) {
                content(size)
                    .frame(width: size.width, height: size.height)
                    .padding(16)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .scrollIndicators(preview.zoom == .fit ? .hidden : .automatic)
            .onChange(of: fit, initial: true) { preview.fitScale = fit }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBase ?? scale
                        pinchBase = base
                        preview.magnify(from: base, by: value.magnification)
                    }
                    .onEnded { _ in pinchBase = nil })
        }
    }
}

/// 一页成品。放大到 100% 以上时用最近邻插值，看得清每个像素。
private struct PageImage: View {
    let page: PreviewImage
    let preview: PreviewModel

    var body: some View {
        let image = page.displayImage().map { NSImage(cgImage: $0, size: .zero) }
        ZoomCanvas(preview: preview, contentPixels: CGSize(width: page.pixelSize.width, height: page.pixelSize.height)) { _ in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(preview.effectiveScale >= 1 ? .none : .high)
                    .allowedDynamicRange(page.dynamicRange == .hdr ? .high : .standard)
            }
        }
    }
}

/// 原图（对比用）。按需缩小解码；HDR 模式下允许 EDR 显示。
private struct OriginalImage: View {
    let url: URL
    let preview: PreviewModel
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                ZoomCanvas(preview: preview, contentPixels: CGSize(width: image.width, height: image.height)) { _ in
                    Image(nsImage: NSImage(cgImage: image, size: .zero))
                        .resizable()
                        .interpolation(preview.effectiveScale >= 1 ? .none : .high)
                        .allowedDynamicRange(preview.range == .hdr ? .high : .standard)
                }
            } else {
                ProgressView()
            }
        }
        .task(id: url) { image = await Self.load(url) }
    }

    private static func load(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3000,
                // gain map 源图也按 HDR 解码；SDR 模式下 `allowedDynamicRange(.standard)` 照常压回 SDR。
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}

/// 全景长卷：封面在前，切片并排，标出接缝（UI 设计文档第 8.2、9 节）。整条长卷一起缩放。
private struct PanoramaStrip: View {
    let pages: [PreviewImage]
    let showsSeams: Bool
    let preview: PreviewModel

    /// 封面与切片之间的间隔（像素，按 100% 计）。
    private static let gapPixels = 48.0

    var body: some View {
        let cover = pages.first { $0.role == .cover }
        let slides = pages.filter { $0.role != .cover }
        let height = Double(pages.map(\.pixelSize.height).max() ?? 1)
        let widths = pages.map { Double($0.pixelSize.width) * height / Double(max($0.pixelSize.height, 1)) }
        let total = widths.reduce(0, +) + (cover != nil && !slides.isEmpty ? Self.gapPixels : 0)
        ZoomCanvas(preview: preview, contentPixels: CGSize(width: total, height: height)) { size in
            let k = size.height / max(height, 1)
            HStack(spacing: Self.gapPixels * k) {
                if let cover { page(cover, height: size.height) }
                HStack(spacing: 0) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        page(slide, height: size.height)
                            .overlay(alignment: .leading) {
                                if showsSeams, index > 0 { Rectangle().fill(.red).frame(width: 1) }
                            }
                    }
                }
            }
        }
    }

    private func page(_ image: PreviewImage, height: Double) -> some View {
        let aspect = Double(image.pixelSize.width) / Double(max(image.pixelSize.height, 1))
        return Group {
            if let cg = image.displayImage() {
                Image(nsImage: NSImage(cgImage: cg, size: .zero)).resizable()
                    .allowedDynamicRange(image.dynamicRange == .hdr ? .high : .standard)
            } else {
                Color.gray
            }
        }
        .frame(width: max(height, 1) * aspect, height: max(height, 1))
    }
}

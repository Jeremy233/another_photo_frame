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
                OriginalImage(url: subject.sourceURL, zoom: preview.zoom, range: preview.range)
            } else if preview.page == .strip {
                PanoramaStrip(pages: preview.strip, showsSeams: preview.showsSeams)
            } else if let page = preview.pageImage {
                ZoomableImage(image: page.displayImage().map { NSImage(cgImage: $0, size: .zero) }, pixelSize: page.pixelSize,
                              zoom: preview.zoom, hdr: page.dynamicRange == .hdr)
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
                Toggle(isOn: $preview.showsOriginal) {
                    Image(systemName: "rectangle.split.2x1")
                }
                .toggleStyle(.button)
                .help("原图 / 成品对比")
                ZoomMenu(zoom: $preview.zoom)
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

private struct ZoomMenu: View {
    @Binding var zoom: PreviewZoom

    var body: some View {
        Menu(title) {
            Button("适合窗口") { zoom = .fit }
            Button("100%") { zoom = .actualSize }
            Divider()
            ForEach([0.25, 0.5, 2.0], id: \.self) { scale in
                Button("\(Int(scale * 100))%") { zoom = .scale(scale) }
            }
        }
        .fixedSize()
    }

    private var title: String {
        switch zoom {
        case .fit: "适合窗口"
        case .actualSize: "100%"
        case .scale(let s): "\(Int(s * 100))%"
        }
    }
}

/// 按缩放显示一张位图。100% 时一个图像像素对应一个屏幕像素。
private struct ZoomableImage: View {
    let image: NSImage?
    let pixelSize: PixelSize
    let zoom: PreviewZoom
    /// gain map 解码出的 HDR 页：允许 EDR 显示（D-106）。
    let hdr: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let image {
            switch zoom {
            case .fit:
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .allowedDynamicRange(hdr ? .high : .standard).padding()
            case .actualSize:
                scrolled(image, scale: 1)
            case .scale(let s):
                scrolled(image, scale: s)
            }
        }
    }

    private func scrolled(_ image: NSImage, scale: Double) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Image(nsImage: image)
                .resizable()
                .interpolation(scale >= 1 ? .none : .high)
                .allowedDynamicRange(hdr ? .high : .standard)
                .frame(width: Double(pixelSize.width) * scale / displayScale, height: Double(pixelSize.height) * scale / displayScale)
                .padding()
        }
    }
}

/// 原图（对比用）。按需缩小解码；HDR 模式下允许 EDR 显示。
private struct OriginalImage: View {
    let url: URL
    let zoom: PreviewZoom
    let range: PreviewRange
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .allowedDynamicRange(range == .hdr ? .high : .standard)
                    .padding()
            } else {
                ProgressView()
            }
        }
        .task(id: url) { image = await Self.load(url) }
    }

    private static func load(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3000,
                // gain map 源图也按 HDR 解码；SDR 模式下 `allowedDynamicRange(.standard)` 照常压回 SDR。
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
    }
}

/// 全景长卷：封面在前，切片并排，标出接缝（UI 设计文档第 8.2、9 节）。
private struct PanoramaStrip: View {
    let pages: [PreviewImage]
    let showsSeams: Bool

    var body: some View {
        let cover = pages.first { $0.role == .cover }
        let slides = pages.filter { $0.role != .cover }
        GeometryReader { geo in
            ScrollView(.horizontal) {
                HStack(spacing: 24) {
                    if let cover { page(cover, height: geo.size.height - 32) }
                    HStack(spacing: 0) {
                        ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                            page(slide, height: geo.size.height - 32)
                                .overlay(alignment: .leading) {
                                    if showsSeams, index > 0 { Rectangle().fill(.red).frame(width: 1) }
                                }
                        }
                    }
                }
                .padding(16)
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

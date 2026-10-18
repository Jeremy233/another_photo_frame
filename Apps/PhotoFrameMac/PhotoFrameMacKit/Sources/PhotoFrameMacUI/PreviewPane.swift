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
                if preview.isRendering { LoadingIndicator() }
            }
            .onTapGesture(count: 2) { if preview.subject != nil { enlarged = true } }
            Hairline()
            PreviewPageBar(preview: preview)
        }
        .background(Palette.panel)
        .sheet(isPresented: $enlarged) {
            canvas
                // 放大窗口是第二块画布：不改主画布的「适合窗口」比例（关掉后菜单、⌘+ / ⌘-、插值都还按主画布算）。
                .environment(\.isEnlargedPreview, true)
                .frame(minWidth: 900, minHeight: 700)
                .background(Palette.preview)
                .overlay(alignment: .topTrailing) {
                    Button("关闭") { enlarged = false }.keyboardShortcut(.cancelAction).padding()
                }
        }
    }

    @ViewBuilder private var canvas: some View {
        if let subject = preview.subject {
            if preview.showsOriginal || subject.preset == nil {
                // 只有 HDR 源图才按 HDR 解码；还不知道时按预览的动态范围。
                let range = workbench.sourceItem(subject.sourceId)?.dynamicRange
                OriginalImage(url: subject.sourceURL, preview: preview, sourceIsHDR: range.map { $0 == .hdr })
            } else if preview.page == .strip {
                PanoramaStrip(pages: preview.strip, images: preview.stripImages, thumbnail: preview.stripThumbnail,
                              showsSeams: preview.showsSeams, preview: preview)
            } else if let page = preview.pageImage {
                PageImage(page: page, image: preview.pageDisplayImage, preview: preview)
            } else if let error = preview.error {
                EmptyState(title: "无法预览", symbol: "xmark.octagon.fill", description: error.displayText)
            }
        } else {
            EmptyState(title: "没有预览", symbol: "photo", description: "选中一个任务或源图")
        }
    }
}

/// 预览里的浮层（加载指示、导航小窗）离画面边缘的距离。
enum PreviewMetrics {
    static let overlayInset: CGFloat = 8
}

extension EnvironmentValues {
    /// 在双击打开的放大窗口里（第二块画布）。
    @Entry var isEnlargedPreview = false
}

/// 预览里的加载指示：渲染成品、解码原图都是右上角的小号进度。
private struct LoadingIndicator: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .padding(PreviewMetrics.overlayInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// 预览上方一行：左边源图文件名，正中（按整栏宽度居中）预设名，右侧是原图对比、缩放、「显示」菜单。
private struct PreviewTitleBar: View {
    @Bindable var preview: PreviewModel

    var body: some View {
        TitleBarLayout(spacing: 10) {
            title(preview.subject?.sourceURL.lastPathComponent ?? "")
            title(preview.subject?.preset?.name ?? "")
            // 控件之间看得见的空隙都是 BarMetrics.gap；无边框菜单自带内缩，间距要减掉。
            HStack(spacing: 0) {
                // 带文字的分段控件：一眼看出是在两种画面间切换、现在显示的是哪一种（分屏图标会让人以为是左右对比）。
                Picker("对比", selection: $preview.showsOriginal) {
                    Text("成品").tag(false)
                    Text("原图").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(preview.subject?.preset == nil)
                .help("在成品和原图之间切换")
                ZoomMenu(preview: preview)
                    .padding(.leading, BarMetrics.gap - BarMetrics.borderlessMenuLeading)
                // 与标题栏、右栏的同一个控件用相同的可用规则。
                Menu("显示") {
                    Picker("对比", selection: $preview.showsOriginal) {
                        Text("成品").tag(false)
                        Text("原图").tag(true)
                    }
                    .disabled(preview.subject?.preset == nil)
                    Picker("动态范围", selection: $preview.range) {
                        Text("SDR").tag(PreviewRange.sdr)
                        Text("HDR").tag(PreviewRange.hdr)
                    }
                    Toggle("显示接缝位置", isOn: $preview.showsSeams)
                        .disabled(preview.subject?.preset?.panorama.enabled != true)
                }
                .fixedSize()
                .padding(.leading, BarMetrics.gap - BarMetrics.borderlessMenuTrailing - BarMetrics.borderlessMenuLeading)
            }
        }
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .padding(.horizontal, BarMetrics.padding)
        .frame(height: BarMetrics.height)
    }

    /// 放不下时中间省略，悬停看全文。
    private func title(_ text: String) -> some View {
        Text(text).font(.callout).lineLimit(1).truncationMode(.middle).help(text)
    }
}

/// 标题栏的排法：[左对齐的文字, 居中的文字, 右侧控件]。居中的文字以整行中点为中心，
/// 宽度不超过它到右侧控件的距离的两倍，并给左边的文字至少留 `minLeading`；左边的文字用到居中文字之前，互不重叠。
private struct TitleBarLayout: Layout {
    var spacing: CGFloat
    var minLeading: CGFloat = 60
    /// 居中时预设名至少要有的宽度，再窄就改为跟在文件名后面。
    var minCentered: CGFloat = 80

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 400, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let (leading, center, trailing) = (subviews[0], subviews[1], subviews[2])
        let trailingSize = trailing.sizeThatFits(.unspecified)
        trailing.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(trailingSize))
        let limit = bounds.maxX - trailingSize.width - spacing
        let natural = center.sizeThatFits(.unspecified).width
        let room = min(limit - bounds.midX, bounds.midX - bounds.minX - minLeading - spacing)
        var centerWidth = natural == 0 ? 0 : min(natural, max(room, 0) * 2)
        var centerMidX = bounds.midX
        if centerWidth < min(natural, minCentered) {
            // 栏太窄、右侧控件已越过中点：没法居中，两段文字分用控件左边的空间，预设名在剩下部分里居中。
            let available = max(limit - bounds.minX - spacing, 0)
            let leadingNatural = leading.sizeThatFits(.unspecified).width
            centerWidth = min(natural, max(available / 2, available - leadingNatural))
            let leadingEnd = bounds.minX + available - centerWidth
            centerMidX = (leadingEnd + spacing + limit) / 2
        }
        let centerMinX = centerWidth == 0 ? limit + spacing : centerMidX - centerWidth / 2
        center.place(at: CGPoint(x: centerMidX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(width: centerWidth, height: bounds.height))
        let leadingWidth = max(centerMinX - spacing - bounds.minX, 0)
        leading.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: leadingWidth, height: bounds.height))
    }
}

/// 预览下方一行：翻页（封面、切片 1…N、全景长卷），右侧是 SDR / HDR。预览的提示只在 Inspector 的「警告」里显示。
private struct PreviewPageBar: View {
    @Bindable var preview: PreviewModel

    var body: some View {
        GeometryReader { geo in
            bar(width: geo.size.width)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, BarMetrics.padding)
        .frame(height: BarMetrics.height)
    }

    private func bar(width: CGFloat) -> some View {
        ZStack {
            HStack(spacing: BarMetrics.gap) {
                // 按页面列表里的位置翻页：不输出封面的全景没有第 0 页。
                Button { preview.step(-1) } label: { Image(systemName: "chevron.backward") }
                    .disabled(!preview.canStep(-1))
                    .help("上一页")
                    .accessibilityLabel("上一页")
                Picker("页面", selection: $preview.page) {
                    ForEach(preview.roles, id: \.self) { role in
                        Text(role.shortTitle).tag(PreviewPage.page(role.carouselPosition))
                    }
                    if preview.hasStrip { Text("全景长卷").tag(PreviewPage.strip) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                // 段数变了换一个新控件：复用的 NSSegmentedControl 不会按新的段重新算宽度。
                .id(PageSegments(count: preview.roles.count, strip: preview.hasStrip))
                Button { preview.step(1) } label: { Image(systemName: "chevron.forward") }
                    .disabled(!preview.canStep(1))
                    .help("下一页")
                    .accessibilityLabel("下一页")
            }
            .disabled(preview.roles.count < 2)
            HStack {
                Spacer()
                Picker("动态范围", selection: $preview.range) {
                    Text("SDR").tag(PreviewRange.sdr)
                    Text("HDR").tag(PreviewRange.hdr)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("按 SDR / HDR 预览成品")
            }
        }
        .frame(width: width, height: BarMetrics.height)
    }

    private struct PageSegments: Hashable {
        var count: Int
        var strip: Bool
    }
}

/// 缩放菜单：标题显示当前比例。快捷键在菜单栏「显示」菜单里（⌘+ / ⌘- / ⌘0 / ⌘9）。
private struct ZoomMenu: View {
    let preview: PreviewModel

    var body: some View {
        // 没有画面时比例没有意义，只显示「适合窗口」。
        // 与菜单栏「显示」里的缩放命令同名、同顺序。
        Menu(preview.subject == nil && preview.zoom == .fit ? "适合窗口" : preview.zoomTitle) {
            Button("放大预览") { preview.zoomIn() }
            Button("缩小预览") { preview.zoomOut() }
            Button("实际大小（100%）") { preview.zoom = .actualSize }
            Button("适合窗口") { preview.zoom = .fit }
            Divider()
            ForEach(PreviewZoom.steps, id: \.self) { scale in
                Button("\(Int((scale * 100).rounded()))%") { preview.zoom = .scale(scale) }
            }
        }
        .fixedSize()
        .help("缩放：适合窗口、100%、放大缩小，也可以在触控板上捏合")
    }
}

/// 可缩放的画面：「适合窗口」时整个内容放进预览区，其余比例按屏幕像素显示，超出时可以滚动或拖动查看；支持触控板捏合。
/// `contentPixels` 是内容在 100% 时的像素尺寸；`content` 拿到显示尺寸（pt）后画出内容。
/// 内容超出预览区时，滚动、拖动或捏合期间右上角淡入导航小窗（`thumbnail`），停下约 1 秒后淡出；点击或拖动小窗跳到对应位置。
private struct ZoomCanvas<Content: View>: View {
    let preview: PreviewModel
    let contentPixels: CGSize
    var thumbnail: CGImage?
    /// 这块画布「适合窗口」的比例或内容尺寸变了时告诉调用方（`preview.fitScale` 是几块画布共用的）。
    var onFit: ((CanvasFit) -> Void)?
    /// 拿到显示尺寸（pt）和这块画布实际的比例后画出内容。
    @ViewBuilder var content: (CGSize, Double) -> Content
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isEnlargedPreview) private var isEnlarged
    @State private var pinchBase: Double?
    /// 拖动开始时的滚动位置。手势结束或被取消时自动复位，不会留下旧的起点。
    @GestureState private var panStart: CGPoint?
    @State private var position = ScrollPosition()
    @State private var geometry: ScrollGeometry?
    @State private var showsMinimap = false
    @State private var hideTask: Task<Void, Never>?

    /// 内容四周的留白（pt）。
    static var padding: CGFloat { 16 }

    var body: some View {
        GeometryReader { geo in
            let fit = PreviewZoom.fitScale(contentPixels: contentPixels, in: geo.size, displayScale: displayScale)
            let scale = preview.zoom == .fit ? fit : preview.effectiveScale
            let size = CGSize(width: contentPixels.width * scale / displayScale, height: contentPixels.height * scale / displayScale)
            ScrollView([.horizontal, .vertical]) {
                content(size, scale)
                    .frame(width: size.width, height: size.height)
                    .gesture(panGesture)
                    .padding(Self.padding)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .scrollPosition($position)
            .scrollIndicators(preview.zoom == .fit ? .hidden : .automatic)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, new in geometry = new }
            .onScrollPhaseChange { _, phase in if phase != .idle { activity() } }
            // 只有主画布报告「适合窗口」的比例（放大窗口的比例只给它自己用）。
            .onChange(of: fit, initial: true) { if !isEnlarged { preview.fitScale = fit } }
            .onChange(of: CanvasFit(pixels: contentPixels, scale: fit), initial: true) { _, new in onFit?(new) }
            #if DEBUG
            .task {
                for _ in 0..<EDRLogger.minimapCycles {
                    try? await Task.sleep(for: .seconds(3))
                    EDRLogger.mark("minimap show")
                    activity()
                }
            }
            #endif
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBase ?? scale
                        pinchBase = base
                        preview.magnify(from: base, by: value.magnification)
                        activity()
                    }
                    .onEnded { _ in pinchBase = nil })
            .overlay(alignment: .topTrailing) {
                if showsMinimap, let geometry, Self.isScrollable(geometry) {
                    Minimap(thumbnail: thumbnail, contentSize: size, geometry: geometry, padding: Self.padding) { offset in
                        position.scrollTo(point: offset)
                        activity()
                    }
                    .padding(PreviewMetrics.overlayInset)
                }
            }
            .transaction { $0.animation = nil }
        }
    }

    /// 内容比显示区域大、可以滚动时才有导航小窗。
    static func isScrollable(_ g: ScrollGeometry) -> Bool {
        g.contentSize.width > g.containerSize.width + 1 || g.contentSize.height > g.containerSize.height + 1
    }

    /// 用鼠标拖动画面平移。位移按全局坐标算：内容随滚动移动，用它自己的坐标算会把滚动又算进下一次位移，画面来回跳。
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($panStart) { value, start, _ in
                guard let geometry, Self.isScrollable(geometry) else { return }
                let origin = start ?? geometry.contentOffset
                start = origin
                position.scrollTo(point: CGPoint(x: origin.x - value.translation.width, y: origin.y - value.translation.height))
            }
            .onChanged { _ in activity() }
    }

    /// 用户在滚动、拖动或缩放：显示小窗，停下 1 秒后隐藏。显示和隐藏都不做动画（不让半透明的层叠在 HDR 画面上过渡）。
    private func activity() {
        setMinimap(true)
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            #if DEBUG
            EDRLogger.mark("minimap hide")
            #endif
            setMinimap(false)
        }
    }

    private func setMinimap(_ shows: Bool) {
        guard showsMinimap != shows else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showsMinimap = shows }
    }
}

/// 导航小窗：整个内容的缩略图 + 当前可见区域的框（系统强调色）。点击或拖动跳到对应位置。
struct Minimap: View {
    let thumbnail: CGImage?
    /// 内容的显示尺寸（pt，不含留白）。
    let contentSize: CGSize
    let geometry: ScrollGeometry
    let padding: CGFloat
    /// 要滚动到的内容偏移。
    let scrollTo: (CGPoint) -> Void
    @Environment(\.displayScale) private var displayScale

    static let maxSize = CGSize(width: 180, height: 120)

    var body: some View {
        let k = min(Self.maxSize.width / max(contentSize.width, 1), Self.maxSize.height / max(contentSize.height, 1))
        let mini = CGSize(width: contentSize.width * k, height: contentSize.height * k)
        let visible = Self.visibleRect(offset: geometry.contentOffset, container: geometry.containerSize, contentSize: contentSize, padding: padding)
        ZStack(alignment: .topLeading) {
            Group {
                if let thumbnail {
                    Image(nsImage: NSImage(cgImage: thumbnail, size: .zero)).resizable().allowedDynamicRange(.standard)
                } else {
                    Palette.preview
                }
            }
            .frame(width: mini.width, height: mini.height)
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.12))
                .frame(width: max(visible.width * k, 6), height: max(visible.height * k, 6))
                .offset(x: visible.minX * k, y: visible.minY * k)
        }
        .frame(width: mini.width, height: mini.height, alignment: .topLeading)
        .clipped()
        .padding(4)
        .background(Palette.panel)
        // 与界面上所有线一样是 1 个物理像素（D-123）。
        .overlay { Rectangle().strokeBorder(Palette.line, lineWidth: 1 / max(displayScale, 1)) }
        // 合成为一个不透明的 SDR 层：叠在 HDR 画面上的只有这一块不透明区域。
        .compositingGroup()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // 点到哪里，可见区域的中心就移到哪里。
                    let point = CGPoint(x: (value.location.x - 4) / k, y: (value.location.y - 4) / k)
                    scrollTo(Self.offset(centering: point, scrollContent: geometry.contentSize, container: geometry.containerSize, padding: padding))
                })
        .help("导航：点击或拖动跳到对应位置")
    }

    /// 可见区域在内容坐标里的矩形（pt，原点是内容左上角，不含留白），裁到内容范围内。
    static func visibleRect(offset: CGPoint, container: CGSize, contentSize: CGSize, padding: CGFloat) -> CGRect {
        let rect = CGRect(x: offset.x - padding, y: offset.y - padding, width: container.width, height: container.height)
        return rect.intersection(CGRect(origin: .zero, size: contentSize))
    }

    /// 让内容里的 `point` 位于可见区域中心的滚动偏移，限制在可滚动范围内。
    static func offset(centering point: CGPoint, scrollContent: CGSize, container: CGSize, padding: CGFloat) -> CGPoint {
        let maxX = max(scrollContent.width - container.width, 0)
        let maxY = max(scrollContent.height - container.height, 0)
        return CGPoint(x: min(max(point.x + padding - container.width / 2, 0), maxX),
                       y: min(max(point.y + padding - container.height / 2, 0), maxY))
    }
}

/// 一块画布「适合窗口」时的比例，连同当时的内容尺寸（像素）。
private struct CanvasFit: Equatable {
    var pixels: CGSize
    var scale: Double
}

/// 一页成品。放大到 100% 以上时用最近邻插值，看得清每个像素。
private struct PageImage: View {
    let page: PreviewImage
    /// 预览模型在后台解码好的位图（这里不再解码）。
    let image: CGImage?
    let preview: PreviewModel

    var body: some View {
        let cg = self.image
        let image = cg.map { NSImage(cgImage: $0, size: .zero) }
        ZoomCanvas(preview: preview, contentPixels: CGSize(width: page.pixelSize.width, height: page.pixelSize.height), thumbnail: cg) { _, scale in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(scale >= 1 ? .none : .high)
                    .allowedDynamicRange(page.dynamicRange == .hdr ? .high : .standard)
            }
        }
    }
}

/// 原图（对比用），由 `OriginalImageStore` 分档解码并缓存：先显示快图，再换清晰版本；
/// 放大到清晰版本不够时才解码全分辨率（100% 是真实像素），缩回、换图或离开后释放。缩放比例按原图真实尺寸计算。
///
/// 画面只显示这张源图自己的图像：换图后还在解码的上一张（任务已取消）不会再写进来。
/// 切换 SDR / HDR 时先保持当前画面，新的解码好了再换；SDR 源图不按 HDR 解码。
private struct OriginalImage: View {
    let url: URL
    let preview: PreviewModel
    /// 源图是不是 HDR；还没检查完时为 nil（按预览的动态范围解码）。
    let sourceIsHDR: Bool?
    @State private var shown: Shown?
    /// 读不出来的原图（文件被移动、删除，卷被推出）。
    @State private var failed: URL?
    /// 这块画布自己报告的「适合窗口」比例。刚切到「原图」时 `preview.fitScale` 还是上一块画布（成品页）的，
    /// 拿它判断会误开全分辨率解码（几百 MB，开始了就停不下来）。
    @State private var canvasFit: CanvasFit?

    /// 正在显示的图像，连同它是哪张源图、哪一档、是否按 HDR 解码。
    private struct Shown {
        var image: CGImage
        var tier: OriginalImageStore.Tier
        var url: URL
        var hdr: Bool
    }

    private var store: OriginalImageStore { .shared }
    private var hdr: Bool { OriginalImageStore.decodesHDR(previewHDR: preview.range == .hdr, sourceIsHDR: sourceIsHDR) }

    var body: some View {
        Group {
            if failed == url {
                EmptyState(title: "无法读取原图", symbol: "xmark.octagon.fill",
                           description: "文件可能已被移动、删除，或所在的卷已推出")
            } else if let info = store.info(url), let shown, shown.url == url {
                let allPixels = OriginalImageStore.showsAllPixels(tier: shown.tier, pixelSize: info.pixelSize)
                ZoomCanvas(preview: preview, contentPixels: info.pixelSize,
                           thumbnail: store.cached(.init(url: url, tier: .quick, hdr: shown.hdr, modified: info.modified)) ?? shown.image,
                           onFit: { canvasFit = $0 }) { _, scale in
                    // 显示的是全部像素（全分辨率，或原图本来就不大）时，放大到 100% 以上用最近邻，与成品页一致。
                    Image(nsImage: NSImage(cgImage: shown.image, size: .zero))
                        .resizable()
                        .interpolation(allPixels && scale >= 1 ? .none : .high)
                        .allowedDynamicRange(shown.hdr ? .high : .standard)
                }
            } else {
                // 这张图还没有画面：与渲染成品时一样，只在右上角显示小号进度。
                LoadingIndicator()
            }
        }
        .task(id: LoadKey(url: url, hdr: hdr)) { await loadProgressively() }
        .task(id: LoadKey(url: url, hdr: hdr, full: needsFull)) { await updateFull() }
        // 全分辨率只在这张原图显示期间留着。
        .onChange(of: url) { old, _ in store.releaseFull(url: old) }
        .onDisappear { store.releaseFull(url: url) }
    }

    private struct LoadKey: Hashable {
        var url: URL
        var hdr: Bool
        var full = false
    }

    /// 放大到清晰版本的像素不够用时，需要全分辨率。只按这块画布自己的比例算，还没显示出这张图时不要。
    private var needsFull: Bool {
        guard let shown, shown.url == url, let info = store.info(url) else { return false }
        let scale: Double? = switch preview.zoom {
        case .fit: canvasFit.flatMap { $0.pixels == info.pixelSize ? $0.scale : nil }
        case .scale(let s): s
        }
        return OriginalImageStore.needsFull(pixelSize: info.pixelSize, scale: scale, showingFull: shown.tier == .full && shown.hdr == hdr)
    }

    /// 是否正在显示这张图、这种动态范围的解码。
    private func isShowing(_ url: URL, hdr: Bool) -> Bool { shown?.url == url && shown?.hdr == hdr }

    private func show(_ image: CGImage, _ tier: OriginalImageStore.Tier, url: URL, hdr: Bool) {
        shown = Shown(image: image, tier: tier, url: url, hdr: hdr)
    }

    private func loadProgressively() async {
        let url = self.url, hdr = self.hdr
        // 每次加载读一次文件的修改时间：文件改了就重新解码，不用旧的缓存。读不到文件头就是读不出来。
        guard let modified = store.reloadInfo(url).map(\.modified) else {
            if !Task.isCancelled { failed = url }
            return
        }
        if failed == url { failed = nil }
        // 看过的图直接用缓存里最清晰的一档。
        if let best = store.best(url: url, hdr: hdr, modified: modified) {
            show(best.image, best.tier, url: url, hdr: hdr)
            if best.tier != .quick { return }
            if let screen = await store.load(.init(url: url, tier: .screen, hdr: hdr, modified: modified)), !Task.isCancelled,
               !(isShowing(url, hdr: hdr) && shown?.tier == .full) {
                show(screen, .screen, url: url, hdr: hdr)
            }
            return
        }
        // 快图和清晰版同时开始解码。快图只在这张图还没有任何画面时显示（切 SDR / HDR 时不先换成模糊的快图）。
        async let screen = store.load(.init(url: url, tier: .screen, hdr: hdr, modified: modified))
        let quick = await store.load(.init(url: url, tier: .quick, hdr: hdr, modified: modified))
        if let quick, !Task.isCancelled, shown?.url != url { show(quick, .quick, url: url, hdr: hdr) }
        let sharp = await screen
        // 任务已取消（换了图、切了动态范围）：不再改画面。
        guard !Task.isCancelled else { return }
        if let sharp {
            if !(isShowing(url, hdr: hdr) && shown?.tier == .full) { show(sharp, .screen, url: url, hdr: hdr) }
        } else if quick == nil {
            failed = url
        }
    }

    private func updateFull() async {
        let url = self.url, hdr = self.hdr
        guard let modified = store.info(url).map(\.modified) else { return }
        if needsFull {
            if let full = await store.load(.init(url: url, tier: .full, hdr: hdr, modified: modified)), !Task.isCancelled {
                show(full, .full, url: url, hdr: hdr)
            }
        } else if isShowing(url, hdr: hdr), shown?.tier == .full {
            store.releaseFull(url: url)
            if let best = store.best(url: url, hdr: hdr, modified: modified) { show(best.image, best.tier, url: url, hdr: hdr) }
        }
    }
}

/// 全景长卷：封面在前，切片并排，标出接缝（UI 设计文档第 8.2、9 节）。整条长卷一起缩放。
private struct PanoramaStrip: View {
    let pages: [PreviewImage]
    /// 预览模型在后台解码好的各页位图，与 `pages` 一一对应（这里不再解码）。
    let images: [CGImage?]
    /// 导航小窗用的整条长卷缩略图。
    let thumbnail: CGImage?
    let showsSeams: Bool
    let preview: PreviewModel

    /// 封面与切片之间的间隔（像素，按 100% 计），与导航小窗的缩略图一致。
    private static var gapPixels: Double { PreviewModel.stripGapPixels }

    /// 一页和它解码好的位图。
    private struct Page {
        var image: PreviewImage
        var decoded: CGImage?
    }

    var body: some View {
        let entries = pages.indices.map { Page(image: pages[$0], decoded: images.indices.contains($0) ? images[$0] : nil) }
        let cover = entries.first { $0.image.role == .cover }
        let slides = entries.filter { $0.image.role != .cover }
        let height = Double(pages.map(\.pixelSize.height).max() ?? 1)
        let widths = pages.map { Double($0.pixelSize.width) * height / Double(max($0.pixelSize.height, 1)) }
        let total = widths.reduce(0, +) + (cover != nil && !slides.isEmpty ? Self.gapPixels : 0)
        ZoomCanvas(preview: preview, contentPixels: CGSize(width: total, height: height), thumbnail: thumbnail) { size, _ in
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

    private func page(_ page: Page, height: Double) -> some View {
        let image = page.image
        let aspect = Double(image.pixelSize.width) / Double(max(image.pixelSize.height, 1))
        return Group {
            if let cg = page.decoded {
                Image(nsImage: NSImage(cgImage: cg, size: .zero)).resizable()
                    .allowedDynamicRange(image.dynamicRange == .hdr ? .high : .standard)
            } else {
                // 还没解码出来的页：深色占位，不在暗的预览区里闪一块亮灰。
                Palette.group
            }
        }
        .frame(width: max(height, 1) * aspect, height: max(height, 1))
    }
}

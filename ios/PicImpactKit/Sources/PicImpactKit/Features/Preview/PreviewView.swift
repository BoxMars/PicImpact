import SwiftUI

/// 预览页（照片详情）。
///
/// 结构对应 Web 端 `preview-image.tsx`：图片 → 标题/描述 → 基本信息 → 拍摄参数 →
/// 设备信息 → 拍摄模式 → 技术参数 → 影调分析 → 直方图 → 标签。
///
/// ## 滚动行为（按用户描述实现）
/// 1. 往上滑时**顶栏（返回/分享）跟着滚走**，不再占位
/// 2. 图片**放大到与屏幕等宽**（左右内边距归零、圆角一并去掉，真正通栏）
/// 3. **图片与标题钉在顶部**，下面的信息区自由滑动
/// 4. 固定区与滚动区之间**没有分隔线**
///
/// 实现方式：顶栏放在滚动内容最上方（自然滚走），
/// 图片+标题作为 `LazyVStack` 的 **pinned section header**（滚到顶后钉住）。
/// 图片的展开程度由滚动位移驱动 —— 用的是 iOS 18 的 `onScrollGeometryChange`；
/// iOS 17 上没有这个 API，退化为"始终通栏"（终态一致，只是少了过渡动画）。
public struct PreviewView: View {
    @State private var model: PreviewModel
    private let features: SiteConfigDTO.Features
    private let onSelectTag: (String) -> Void

    /// 滚动位移，用来把图片从"内缩"过渡到"通栏"
    @State private var scrollOffset: CGFloat = 0

    /// 走完这段位移，图片就完全通栏。
    /// 顶栏高 32 + 上 12 + 下 12 = 56，留一点余量取 60。
    private static let expansionDistance: CGFloat = 60

    /// 返回：弹出当前页。用 `dismiss` 而不是自己管导航栈，
    /// 这样从任意入口（卡片、标签、深链接）进来都能正确返回。
    @Environment(\.dismiss) private var dismiss

    public init(
        model: PreviewModel,
        features: SiteConfigDTO.Features = .none,
        onSelectTag: @escaping (String) -> Void = { _ in }
    ) {
        _model = State(initialValue: model)
        self.features = features
        self.onSelectTag = onSelectTag
    }

    /// 0 = 顶栏还在，图片内缩；1 = 顶栏已滚走，图片通栏
    private var expansion: CGFloat {
        guard Self.supportsScrollTracking else { return 1 }
        return min(max(scrollOffset / Self.expansionDistance, 0), 1)
    }

    private static var supportsScrollTracking: Bool {
        if #available(iOS 18.0, macOS 15.0, *) { return true }
        return false
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                // 顶栏在滚动内容里：往上滑就跟着滚走（用户要求"看不到"）
                PreviewTopBar(image: model.image, onBack: { dismiss() })
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                Section {
                    PreviewInfoPanel(model: model, features: features, onSelectTag: onSelectTag)
                } header: {
                    // 图片 + 标题：滚到顶后钉住
                    PreviewPinnedHeader(model: model, expansion: expansion)
                }
            }
        }
        .modifier(ScrollOffsetReporter { offset in
            scrollOffset = offset
        })
        // 底部延伸到屏幕下缘：内容要能一直显示到最底下（用户要求"下方也不用遮挡"）。
        // 必须写在 islandPageBackground 之前 —— 那里的 .clipped() 是裁到当前框架的，
        // 先把框架扩到底边，裁剪才只在**上方**起作用。
        .ignoresSafeArea(edges: .bottom)
        // 图片滚到最上面钉住时不要从状态栏里透出来
        .islandPageBackground()
        // 顶部用自绘的 ACNH 控件（返回 / 分享），不再用系统导航栏。
        // 加平台判断是因为 `.navigationBar` 这个 placement 在 macOS 上不存在，
        // 而本包同时要给 macOS 的单元测试编译。
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        // 隐藏导航栏会让系统的手势返回失效，这里把它接回来
        .background(InteractivePopGestureEnabler().frame(width: 0, height: 0))
        #endif
        .task { await model.load() }
    }

}


/// 上报滚动位移。
///
/// `onScrollGeometryChange` 是 iOS 18 才有的，所以这里做可用性判断：
/// iOS 17 上什么都不做，`PreviewView` 会把展开度固定为 1（始终通栏）。
private struct ScrollOffsetReporter: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newValue in
                onChange(newValue)
            }
        } else {
            content
        }
    }
}

/// 详情页顶栏：左上「返回」、右上「分享」，都用 ACNH 的胶囊样式（图标 + 文字）。
///
/// 为什么自绘而不是用系统导航栏：整套界面是 ACNH 风格，
/// 系统导航栏的细线返回箭头与 ACNH 图标不是一套语言；
/// 而且导航栏只能放图标按钮，放不下"返回 / 分享"这样的文字。
///
/// 抽成独立视图是为了可测：它现在挂在 `PreviewView` 的滚动内容里，
/// 测试可以直接栅格化它。
struct PreviewTopBar: View {
    let image: ImageDTO
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            IslandBackButton(action: onBack)
            Spacer(minLength: 0)
            IslandShareButton(
                url: LinkActions.shareURL(for: image),
                iconSize: 16,
                fontSize: 12,
                style: .pill
            )
        }
    }
}

/// 详情页的**固定区**：主图 + 标题（滚到顶后钉住）。
///
/// `expansion`：0 = 顶栏还在，图片内缩；1 = 顶栏已滚走，图片通栏。
struct PreviewPinnedHeader: View {
    let model: PreviewModel
    let expansion: CGFloat

    /// 标题缩进：与信息卡片**内部**文字对齐。
    ///
    /// 卡片内有 16pt 内边距，加上页面 16pt，卡片内文字在 32pt；
    /// 标题取 32 才能与它对齐（这是用户先前明确要求过的）。
    private let titleInset: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            imageSection
                // 展开到通栏：内边距归零、圆角一并去掉
                .clipShape(RoundedRectangle(cornerRadius: 18 * (1 - expansion), style: .circular))
                .padding(.horizontal, 16 * (1 - expansion))

            titleSection
                .padding(.horizontal, titleInset)
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        // 必须不透明：下面滚上来的内容要从它背后经过
        .background(AnimalTokens.bg)
    }

    private var imageSection: some View {
        Group {
            if model.image.isLivePhoto {
                LivePhotoView(imageURL: model.image.displayURL, videoURL: model.image.videoResourceURL)
            } else {
                ProgressiveImageView(
                    preview: model.previewImage,
                    original: model.originalImage,
                    aspectRatio: model.image.aspectRatio
                )
            }
        }
    }

    @ViewBuilder
    private var titleSection: some View {
        if !model.image.title.isEmpty || !model.image.detail.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !model.image.title.isEmpty {
                    Text(model.image.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AnimalSignatures.cardText) // #725d42
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                    // 标题下的青色短横，作为 ACNH 风格的分隔强调
                    RoundedRectangle(cornerRadius: 2, style: .circular)
                        .fill(AnimalTokens.primary) // #19c8b9
                        .frame(width: 32, height: 3)
                }
                if !model.image.detail.isEmpty {
                    Text(model.image.detail)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AnimalTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }
            }
        }
    }
}

/// 详情页**滚动区**的内容（不含 `ScrollView` 本身）。
///
/// 不含滚动容器是刻意的：`ImageRenderer` 不渲染 `ScrollView` 的内容，
/// 去掉容器后整块才能在测试里栅格化断言。
struct PreviewInfoPanel: View {
    let model: PreviewModel
    let features: SiteConfigDTO.Features
    let onSelectTag: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.infoData.isEmpty || model.tone != nil || model.histogram != nil {
                infoPanel
            }

            if !model.image.labels.isEmpty {
                tagSection
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var infoPanel: some View {
        IslandCard {
            VStack(alignment: .leading, spacing: 14) {
                PreviewInfoSections(data: model.infoData)

                if let tone = model.tone {
                    IslandDashedDivider()
                    sectionBlock("Exif.toneAnalysis") {
                        ToneAnalysisView(analysis: tone)
                    }
                }

                if let histogram = model.histogram {
                    IslandDashedDivider()
                    sectionBlock("Exif.histogram") {
                        HistogramPanel(histogram: histogram)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func sectionBlock<Content: View>(
        _ titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IslandSectionTitle(IslandStrings.text(titleKey))
            content()
        }
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            IslandSectionTitle(IslandStrings.text("Exif.tags"))
            HStack(spacing: 6) {
                ForEach(model.image.labels, id: \.self) { label in
                    Button { onSelectTag(label) } label: {
                        Text("🏷 \(label)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AnimalTokens.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(AnimalTokens.primaryBG)
                            .clipShape(Capsule())
                            .overlay { Capsule().strokeBorder(AnimalTokens.primary, lineWidth: 1.5) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// 直方图。
///
/// 演变过程：最早是"浅色底 + 1px 描边 + 圆角"的面板；用户先要求去边框，
/// 之后又要求去掉外面那层浅色圆角容器（看起来像个胶囊）。
/// 现在直方图**直接贴在纸色上**，不再有任何包裹层 —— 深色矩形本身就是图表。
///
/// 单独抽成视图是为了能在测试里直接栅格化断言"没有包裹层"。
struct HistogramPanel: View {
    let histogram: Histogram

    var body: some View {
        HistogramView(histogram: histogram)
            .frame(height: 120)
    }
}

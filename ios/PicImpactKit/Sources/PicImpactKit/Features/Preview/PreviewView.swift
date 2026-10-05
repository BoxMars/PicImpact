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

    /// 并排模式下标题的**实测**高度 —— 信息栏靠它算出与照片顶对齐所需的顶部偏移（方案 C）。
    @State private var titleHeight: CGFloat = 0

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

    /// 详情页的布局决策。抽成纯函数是为了**能测** —— 这条规则来自用户：
    /// "设备方向与照片方向一致 → 原本结构；不一致 → 新结构（信息双栏）"。
    struct DetailLayoutMode: Equatable {
        var stacked: Bool
        var twoColumn: Bool
        var imageFraction: CGFloat
    }

    /// **两个维度是分开的**（这一点我一开始搞混过，被用户纠正）：
    ///
    /// - **结构**：设备与照片方向**一致**时左右并排（用户："竖屏+竖屏照片是双排"），
    ///   不一致时上下排。
    /// - **信息栏**：设备与照片方向**不一致**时双栏（用户："竖屏+竖屏照片是单栏信息"），
    ///   一致时单栏。
    ///
    /// 合起来：
    ///   竖屏+竖图 → 并排、单栏      竖屏+横图 → 上下排、双栏
    ///   横屏+横图 → 并排、单栏      横屏+竖图 → 上下排、双栏
    ///
    /// 窄屏（iPhone 竖屏）放不下并排，也放不下两栏，所以两者都退化为上下排 + 单栏。
    static func layoutMode(size: CGSize, photoAspectRatio: CGFloat) -> DetailLayoutMode {
        let isDevicePortrait = size.height > size.width
        let isPhotoPortrait = photoAspectRatio < 1
        let matched = isDevicePortrait == isPhotoPortrait
        let roomy = size.width >= wideBreakpoint
        return DetailLayoutMode(
            // 只有「竖屏 + 横图」走上下排（用户逐条确认过），其余组合都并排：
            //   竖屏+竖图 → 并排（单栏）    横屏+横图 → 并排（单栏）
            //   横屏+竖图 → 并排（双栏）    竖屏+横图 → 上下排（双栏）
            // 窄屏（iPhone 竖屏）放不下并排，必须退化
            stacked: !roomy || (isDevicePortrait && !isPhotoPortrait),
            // 信息双栏 = 设备与照片方向**不一致**
            twoColumn: !matched && roomy,
            // 信息要双栏时，图片让到 1/3 把宽度让给信息；单栏时按原来占 2/3
            imageFraction: (!matched && roomy) ? 1.0 / 3.0 : 2.0 / 3.0
        )
    }

    /// 宽屏断点：对齐 Web 的 `sm:`（640px）。
    /// 达到后详情页从"上下堆叠"改成"左右分栏"（Web 的 `sm:grid-cols-3`）。
    private static let wideBreakpoint: CGFloat = 640

    /// 窄屏（iPhone 竖屏）：保持原有行为 —— 顶栏滚走、图片展开通栏、图片+标题钉住。
    private func stackedLayout(twoColumn: Bool) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                // 顶栏在滚动内容里：往上滑就跟着滚走（用户要求"看不到"）
                PreviewTopBar(image: model.image, onBack: { dismiss() })
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                Section {
                    PreviewInfoPanel(
                        model: model,
                        features: features,
                        onSelectTag: onSelectTag,
                        twoColumn: twoColumn
                    )
                } header: {
                    // 图片 + 标题：滚到顶后钉住
                    PreviewPinnedHeader(model: model, expansion: expansion)
                }
            }
        }
        .modifier(ScrollOffsetReporter { offset in
            scrollOffset = offset
        })
    }

    /// 宽屏（iPad / iPhone 横屏）：照 Web 的 `sm:grid sm:grid-cols-3` ——
    /// 图片占 2/3 放左边并居中、高度上限 90vh；标题与信息占 1/3 放右边、独立滚动。
    ///
    /// 这样横屏照片不会被拉满整屏（也就不会"太宽显示不了"）：
    /// 图片宽度从整屏降到 2/3，高度再被 90vh 限制。
    /// 方案 C 的顶部偏移：让信息栏第一行与照片顶部落在同一条水平线上。
    ///
    /// 左栏（标题+照片）整块垂直居中 → 顶部在 `(columnHeight - 标题高 - 照片高) / 2`；
    /// 照片顶 = 该值 + 标题高。信息栏就从这里开始，所以返回这个和。
    /// 内容比栏还高（居中偏移为负）时返回 0，退化为从顶部开始，避免推出大量空白。
    static func infoTopInset(
        columnHeight: CGFloat,
        imageWidth: CGFloat,
        aspectRatio: CGFloat,
        titleHeight: CGFloat
    ) -> CGFloat {
        guard aspectRatio > 0, columnHeight > 0, imageWidth > 0 else { return 0 }
        let photoHeight = imageWidth / aspectRatio
        let centering = (columnHeight - titleHeight - photoHeight) / 2
        guard centering > 0 else { return 0 }
        return centering + titleHeight
    }

    private func wideLayout(size: CGSize, twoColumn: Bool, imageFraction: CGFloat) -> some View {
        let inset: CGFloat = 8              // Web: p-2
        let gap: CGFloat = 16               // Web: gap-4
        let maxHeight = size.height * 0.9   // Web: max-h-[90vh]
        let available = max(0, size.width - inset * 2 - gap)
        let imageWidth = available * imageFraction
        let infoWidth = available - imageWidth

        return VStack(spacing: 0) {
            PreviewTopBar(image: model.image, onBack: { dismiss() })
                .padding(.horizontal, inset)
                .padding(.vertical, 8)

            // 结构（用户给的，简单且自洽）：
            //   标题独占一行 → 图片与信息一行 → 两者放进同一个 VStack **整体居中**。
            // 这样同时满足两件事，而且不需要任何测量或偏移计算：
            //   居中 → 由外层 VStack 负责
            //   对齐 → 由 HStack(alignment: .top) 天然保证（图片与信息是同一行的兄弟）
            VStack(spacing: 12) {
                PreviewTitleBlock(model: model, inset: 32)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .top, spacing: gap) {
                    PreviewImageView(model: model)
                        .frame(width: imageWidth, alignment: .top)

                    ScrollView {
                        PreviewInfoPanel(
                            model: model,
                            features: features,
                            onSelectTag: onSelectTag,
                            twoColumn: twoColumn
                        )
                        .frame(width: infoWidth, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .frame(width: infoWidth, height: maxHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, inset)

            Spacer(minLength: 0)
        }
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
        GeometryReader { proxy in
            // 用户定义的规则（逐条确认后的最终版）—— 结构、信息栏是两个独立维度：
            //
            //  竖屏 + 竖屏照片 → 左右并排、信息单栏
            //  竖屏 + 横屏照片 → 上下排、信息双栏
            //  横屏 + 横屏照片 → 左右并排、信息单栏
            //  横屏 + 竖屏照片 → 左右并排、信息双栏   ← 用户："横屏+竖屏照片也是双栏"
            //
            //  结构：只有「竖屏 + 横图」上下排，其余都并排
            //  信息：方向一致 → 单栏；不一致 → 双栏
            let mode = Self.layoutMode(size: proxy.size, photoAspectRatio: model.image.aspectRatio)
            if mode.stacked {
                stackedLayout(twoColumn: mode.twoColumn)
            } else {
                wideLayout(
                    size: proxy.size,
                    twoColumn: mode.twoColumn,
                    imageFraction: mode.imageFraction
                )
            }
        }
        .contentMargins(.bottom, 0, for: .scrollContent)
        // 图片滚到最上面钉住时不要从状态栏里透出来
        .islandPageBackground()
        // 底部延伸到屏幕下缘：内容要一直显示到最底下（用户要求"下方也不用遮挡"）。
        // ⚠️ 必须放在 islandPageBackground **之后**（最外层）：
        // 写在它之前会被后面的包装抵消，实测 ScrollView 框架仍停在 839pt
        // （屏幕 874pt，少了 35pt 的 home indicator 安全区）。
        .ignoresSafeArea(edges: .bottom)
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

            // 缩进由 PreviewTitleBlock 自己负责，这里**不要**再加一层，
            // 否则会加两次（32+32=64pt），与卡片内文字错开 —— 有测试盯着这条对齐。
            titleSection
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        // 必须不透明：下面滚上来的内容要从它背后经过
        .background(AnimalTokens.bg)
    }

    private var imageSection: some View {
        PreviewImageView(model: model)
    }

    private var titleSection: some View {
        PreviewTitleBlock(model: model, inset: titleInset)
    }
}

/// 图片本体（Live Photo 或普通图片）。详情页的窄屏与宽屏共用。
struct PreviewImageView: View {
    let model: PreviewModel

    var body: some View {
        if model.image.isLivePhoto {
            LivePhotoView(imageURL: model.image.displayURL, videoURL: model.image.videoResourceURL)
        } else {
            ProgressiveImageView(
                preview: model.previewImage,
                original: model.originalImage,
                aspectRatio: model.image.aspectRatio,
                thumbHash: model.image.blurhash
            )
        }
    }
}

/// 标题 + 描述。窄屏在图片下方（缩进 32 与卡片内文字对齐），宽屏在右栏顶部。
struct PreviewTitleBlock: View {
    let model: PreviewModel
    let inset: CGFloat

    var body: some View {
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
            .padding(.horizontal, inset)
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
    /// 信息分区是否双栏（"新结构"下为 true）
    var twoColumn: Bool = false

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
                // 影调分析与直方图一并交给 PreviewInfoSections ——
                // 这样它们会跟信息分区一起参与分栏，不再各自整宽独占一行。
                PreviewInfoSections(
                    data: model.infoData,
                    twoColumn: twoColumn,
                    tone: model.tone,
                    histogram: model.histogram
                )
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

/// 并排模式下量标题高度用（方案 C 需要这个数值来对齐信息栏）。
struct TitleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

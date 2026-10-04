import SwiftUI

/// 预览页（照片详情）。
///
/// 结构对应 Web 端 `preview-image.tsx`：
/// 图片 → 标题/描述 → 基本信息 → 拍摄参数 → 设备信息 → 拍摄模式 →
/// 技术参数 → 影调分析 → 直方图 → 标签。
/// 桌面是两栏，触屏改为纵向堆叠（同样内容、同一层级、同一顺序）。
///
/// 视觉按 ACNH 设计系统组织：
/// - 主图与信息块都装进**纸色岛屿卡片**（2pt 描边 + 3pt 实心硬阴影），与画廊卡片同一套语言
/// - 分区标题是青色小标，分区之间是青色虚线
/// - 拍摄参数用带图标的胶囊，影调指标用比例条（数值本身与 Web 完全一致）
public struct PreviewView: View {
    @State private var model: PreviewModel
    private let features: SiteConfigDTO.Features
    private let onSelectTag: (String) -> Void

    public init(
        model: PreviewModel,
        features: SiteConfigDTO.Features = .none,
        onSelectTag: @escaping (String) -> Void = { _ in }
    ) {
        _model = State(initialValue: model)
        self.features = features
        self.onSelectTag = onSelectTag
    }

    public var body: some View {
        ScrollView {
            // 内容抽成独立视图：`ImageRenderer` 渲染 `ScrollView` 时**不会**渲染其内容，
            // 拆开后整块内容可以在测试里直接栅格化验证（否则详情页的渲染是个测试盲区）。
            PreviewContentView(model: model, features: features, onSelectTag: onSelectTag)
        }
        .background(AnimalTokens.bg)
        .task { await model.load() }
    }
}

/// 详情页的内容块（不含滚动容器）。见 `PreviewView` 里关于为什么拆出来的说明。
///
/// **没有操作按钮**：按用户要求移除了原来的三个按钮（复制链接 / 分享直链 / 下载原图）。
/// 分享与下载现在都在**画廊卡片**上，详情页专注于看图与读信息。
struct PreviewContentView: View {
    let model: PreviewModel
    let features: SiteConfigDTO.Features
    let onSelectTag: (String) -> Void

    /// 岛屿卡片的内边距。
    ///
    /// 卡片**外**的内容（标题、描述、标签）要额外缩进这么多，
    /// 才能与卡片**内**的文字左对齐 —— 否则卡片内的文字比标题多缩进一层
    /// （页面 16 + 卡片 16 = 32pt vs 标题 16pt），看起来是错位的。
    private let cardInnerPadding: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 主图也装进岛屿卡片：与画廊卡片同一套圆角/描边/硬阴影
            IslandCard {
                imageSection
            }

            if case let .failed(message) = model.phase {
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AnimalTokens.error)
                    .padding(.leading, cardInnerPadding)
            }

            // 以下三块在卡片之外，统一缩进到与卡片内文字同一条竖线
            titleSection
                .padding(.leading, cardInnerPadding)

            if !model.infoData.isEmpty || model.tone != nil || model.histogram != nil {
                infoPanel
            }

            if !model.image.labels.isEmpty {
                tagSection
                    .padding(.leading, cardInnerPadding)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 图片

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

    // MARK: - 标题

    @ViewBuilder
    private var titleSection: some View {
        if !model.image.title.isEmpty || !model.image.detail.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !model.image.title.isEmpty {
                    Text(model.image.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AnimalSignatures.cardText) // #725d42
                        .fixedSize(horizontal: false, vertical: true)
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
                }
            }
        }
    }

    // MARK: - 信息面板

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

    // MARK: - 标签

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
/// 直方图面板：浅色底 + 圆角，**不加边框**（按用户要求）。
///
/// 单独抽成视图是为了能在测试里直接栅格化 —— 否则"没有边框"这件事只能靠肉眼，
/// 而这次改动的全部内容恰恰就是去掉一层边框。
struct HistogramPanel: View {
    let histogram: Histogram

    var body: some View {
        HistogramView(histogram: histogram)
            .frame(height: 120)
            .padding(8)
            // 保留浅色底（它是让直方图从纸色上"浮"出来的依据），只去掉描边
            .background(AnimalTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .circular))
    }
}

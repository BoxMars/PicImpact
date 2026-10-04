import SwiftUI

/// 预览页（照片详情）。
///
/// 结构对应 Web 端 `preview-image.tsx`：图片 → 标题/描述 → 基本信息 → 拍摄参数 →
/// 设备信息 → 拍摄模式 → 技术参数 → 影调分析 → 直方图 → 标签。
///
/// ## 布局：上半固定、下半滚动
/// 按用户要求，**顶栏（返回/分享）、主图、标题固定不动**，只有信息区滚动。
/// 这样在看 EXIF / 影调数据时照片一直可见，不必来回滚动对照。
/// 固定区与滚动区之间用一条细线分隔，提示"下面才是可滚动的"。
///
/// 视觉按 ACNH 设计系统组织：主图与信息块都装进纸色岛屿卡片，
/// 分区标题是青色小标，分区之间是青色虚线，拍摄参数用带图标的胶囊，
/// 影调指标用比例条（数值本身与 Web 完全一致）。
public struct PreviewView: View {
    @State private var model: PreviewModel
    private let features: SiteConfigDTO.Features
    private let onSelectTag: (String) -> Void

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

    public var body: some View {
        VStack(spacing: 0) {
            // 固定区：顶栏（返回/分享） + 主图 + 标题。
            PreviewPinnedHeader(model: model, onBack: { dismiss() })

            // 一条细线划出"下面才是可滚动的"
            Rectangle()
                .fill(AnimalSignatures.cardBorder.opacity(0.5))
                .frame(height: 1)

            // 自由滑动区
            ScrollView {
                PreviewInfoPanel(model: model, features: features, onSelectTag: onSelectTag)
            }
        }
        .background(AnimalTokens.bg)
        // 顶部用自绘的 ACNH 控件（返回 / 分享），不再用系统导航栏。
        // 加平台判断是因为 `.navigationBar` 这个 placement 在 macOS 上不存在，
        // 而本包同时要给 macOS 的单元测试编译。
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task { await model.load() }
    }
}

/// 详情页的**固定区**：顶栏 + 主图 + 标题。
///
/// 拆成独立视图有两个原因：
/// 1. 它要在 `ScrollView` 之外（固定不动）
/// 2. `ImageRenderer` 渲染 `ScrollView` 时**不会**渲染其内容，
///    拆出来才能在测试里直接栅格化验证
struct PreviewPinnedHeader: View {
    let model: PreviewModel
    let onBack: () -> Void

    /// 岛屿卡片的内边距。
    ///
    /// 卡片**外**的内容（标题、描述）要额外缩进这么多，
    /// 才能与卡片**内**的文字左对齐 —— 否则卡片内的文字比标题多缩进一层
    /// （页面 16 + 卡片 16 = 32pt vs 标题 16pt），看起来是错位的。
    private let cardInnerPadding: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 顶栏：左上返回、右上分享，都是 ACNH 胶囊（图标 + 文字）。
            // 顶栏按页面边距对齐（chrome 的常规做法），不跟着标题做卡片内缩进。
            HStack(spacing: 8) {
                IslandBackButton(action: onBack)
                Spacer(minLength: 0)
                IslandShareButton(
                    url: LinkActions.shareURL(for: model.image),
                    iconSize: 16,
                    fontSize: 12,
                    style: .pill
                )
            }

            if case let .failed(message) = model.phase {
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AnimalTokens.error)
                    .padding(.leading, cardInnerPadding)
            }

            // 主图装进岛屿卡片：与画廊卡片同一套圆角/描边/硬阴影
            IslandCard {
                imageSection
            }

            titleSection
                .padding(.leading, cardInnerPadding)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
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

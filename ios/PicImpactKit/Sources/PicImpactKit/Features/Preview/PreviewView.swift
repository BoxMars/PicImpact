import SwiftUI

/// 预览页。
///
/// 结构对应 Web 端 `preview-image.tsx`：
/// 图片 → 标题/描述 → **操作行** → 基本信息 → 拍摄参数 → 设备信息 → 拍摄模式 →
/// 技术参数 → 影调分析 → 直方图 → 标签。
/// 桌面是两栏，触屏改为纵向堆叠（同样内容、同一层级、同一顺序）。
///
/// 视觉上按 ACNH 设计系统来：整块信息放进纸色岛屿卡片，分区标题是青色小标，
/// 分区之间用青色虚线分隔，参数用带图标的胶囊 —— 而不是罗列纯文本行。
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
struct PreviewContentView: View {
    let model: PreviewModel
    let features: SiteConfigDTO.Features
    let onSelectTag: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
                imageSection

                if case let .failed(message) = model.phase {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(AnimalTokens.error)
                }

                if !model.image.title.isEmpty {
                    Text(model.image.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AnimalSignatures.cardText)
                }
                if !model.image.detail.isEmpty {
                    Text(model.image.detail)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AnimalTokens.textSecondary)
                }

                actionRow

                if !model.infoData.isEmpty || model.tone != nil || model.histogram != nil {
                    infoPanel
                }

                if !model.image.labels.isEmpty {
                    tagSection
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

    // MARK: - 操作行
    //
    // 图标与卡片**不同**：详情页的"分享直链"是 `icon-chat`，卡片里是 `icon-helicopter`。
    // 这是 Web 本来的差异，不是笔误。

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            PreviewActionRow(actions: actions)
            if let error = model.downloadError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(AnimalTokens.error)
            }
        }
    }

    private var actions: [PreviewActionRow.Action] {
        var items: [PreviewActionRow.Action] = [
            .init(id: "copy", icon: .diy, label: "复制链接") {
                LinkActions.copyImageLink(model.image)
            },
            .init(id: "share", icon: .chat, label: "分享直链") {
                LinkActions.copyShareLink(model.image)
            },
        ]
        // 下载受站点配置控制（API 契约要求按 features 决定功能可见性）
        if features.download {
            items.append(.init(id: "download", icon: .shopping, label: model.isDownloading ? "下载中…" : "下载原图") {
                guard !model.isDownloading else { return }
                Task { await model.download() }
            })
        }
        return items
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
                        HistogramView(histogram: histogram)
                            .frame(height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .circular))
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

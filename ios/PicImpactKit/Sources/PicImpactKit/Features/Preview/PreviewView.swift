import SwiftUI

/// 预览页。
///
/// 结构对应 Web 端 `preview-image.tsx`：图片区 → 操作区 → 基本信息 → EXIF →
/// 影调分析 → 直方图 → 标签。桌面是两栏，触屏改为纵向堆叠（同样内容、同一层级）。
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
            VStack(alignment: .leading, spacing: AnimalTokens.spacingLG) {
                imageSection

                if case let .failed(message) = model.phase {
                    Text(message)
                        .font(.system(size: AnimalTokens.fontSize))
                        .foregroundStyle(AnimalTokens.error)
                }

                actionSection

                if !model.image.title.isEmpty {
                    Text(model.image.title)
                        .font(.system(size: AnimalTokens.fontLG, weight: .bold))
                        .foregroundStyle(AnimalTokens.text)
                }
                if !model.image.detail.isEmpty {
                    Text(model.image.detail)
                        .font(.system(size: AnimalTokens.fontSize))
                        .foregroundStyle(AnimalTokens.textSecondary)
                }

                IslandCard {
                    EXIFPanel(rows: model.exifRows())
                        .padding(AnimalTokens.spacingMD)
                }

                if let tone = model.tone {
                    IslandCard {
                        ToneAnalysisView(analysis: tone)
                            .padding(AnimalTokens.spacingMD)
                    }
                }

                if let histogram = model.histogram {
                    HistogramView(histogram: histogram)
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: AnimalTokens.radius, style: .circular))
                }

                if !model.image.labels.isEmpty {
                    tagSection
                }
            }
            .padding(.horizontal, MasonryLayout.horizontalPadding(forWidth: 393))
            .padding(.vertical, AnimalTokens.spacingLG)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(AnimalTokens.bg)
        .task { await model.load() }
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

    private var actionSection: some View {
        HStack(spacing: AnimalTokens.spacingMD) {
            if features.download {
                Button {
                    Task { await model.download() }
                } label: {
                    Label(model.isDownloading ? "下载中…" : "下载原图", systemImage: "arrow.down.circle")
                        .font(.system(size: AnimalTokens.fontSize, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AnimalTokens.primary)
                .disabled(model.isDownloading)
            }
            if let error = model.downloadError {
                Text(error)
                    .font(.system(size: AnimalTokens.fontSM))
                    .foregroundStyle(AnimalTokens.error)
            }
            Spacer(minLength: 0)
        }
    }

    private var tagSection: some View {
        HStack(spacing: AnimalTokens.spacingSM) {
            ForEach(model.image.labels, id: \.self) { label in
                Button { onSelectTag(label) } label: {
                    Text(label)
                        .font(.system(size: AnimalTokens.fontSM, weight: .semibold))
                        .foregroundStyle(AnimalSignatures.cardText)
                        .padding(.horizontal, AnimalTokens.spacingSM)
                        .padding(.vertical, AnimalTokens.spacingXS)
                        .background(AnimalTokens.primaryBG)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .circular))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

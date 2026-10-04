import SwiftUI

/// 画廊卡片（simple / ACNH 主题）。
///
/// 对应 Web 端 `components/gallery/simple/gallery-image.tsx` 的岛屿卡 +
/// 图片 + 下方信息块结构。
///
/// ## 为什么信息块高度要固定
/// Web 端用 `ResizeObserver` 实测每张卡的高度，再据此算瀑布流的跨行数。
/// iOS 端如果也走"先渲染再测量"，瀑布流会经历一次重排（肉眼可见的跳动），
/// 而且很容易踩到 Web 端踩过的正反馈坑（测量值含预留间距 → 跨行数变大 → 更高）。
/// 因此这里**把信息块高度固定下来**，由图片宽高比推出总高，
/// 让布局在渲染前就能完全确定（这也让 `MasonryLayout` 可以纯函数化、可测）。
public enum GalleryCellMetrics {
    /// 信息块高度（标题最多两行 + 一行元信息）
    public static let infoBlockHeight: CGFloat = 88
    /// 卡片内边距
    public static let padding: CGFloat = 10
    /// 标题行数上限
    public static let titleLineLimit = 2
    /// 卡片之间的垂直间距（与 Web 一致）
    public static let gap: CGFloat = 16
}

public struct GalleryCell: View {
    public let image: ImageDTO
    public let columnWidth: CGFloat
    public let loader: ImageLoader
    public let showDownload: Bool
    public let onTap: () -> Void
    public let onDownload: () -> Void

    public init(
        image: ImageDTO,
        columnWidth: CGFloat,
        loader: ImageLoader,
        showDownload: Bool = false,
        onTap: @escaping () -> Void = {},
        onDownload: @escaping () -> Void = {}
    ) {
        self.image = image
        self.columnWidth = columnWidth
        self.loader = loader
        self.showDownload = showDownload
        self.onTap = onTap
        self.onDownload = onDownload
    }

    /// 图片按列宽等比缩放后的高度。**不裁切**（与 Web 的 object-fit 语义一致）
    ///
    /// aspectRatio = width / height，故高度 = 列宽 / aspectRatio。
    /// 例如 4000×3000 → 高度 = 列宽 × 0.75。
    public var imageHeight: CGFloat {
        guard image.aspectRatio > 0 else { return columnWidth }
        return max(1, columnWidth / image.aspectRatio)
    }

    /// 卡片总高 = 图片 + 信息块
    public var totalHeight: CGFloat {
        imageHeight + GalleryCellMetrics.infoBlockHeight
    }

    public var body: some View {
        Button(action: onTap) {
            IslandCard {
                VStack(alignment: .leading, spacing: 0) {
                    CachedAsyncImage(url: image.displayURL, loader: loader, contentMode: .fill)
                        .frame(width: columnWidth, height: imageHeight)
                        .clipped()

                    infoBlock
                        .frame(height: GalleryCellMetrics.infoBlockHeight, alignment: .topLeading)
                }
            }
        }
        .buttonStyle(IslandPressStyle())
        .frame(width: columnWidth)
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: AnimalTokens.spacingXS) {
            Text(image.title.isEmpty ? " " : image.title)
                .font(.system(size: AnimalTokens.fontSize, weight: .bold))
                .foregroundStyle(AnimalSignatures.cardText)
                .lineLimit(GalleryCellMetrics.titleLineLimit)
                .multilineTextAlignment(.leading)

            HStack(spacing: AnimalTokens.spacingXS) {
                if let date = EXIFTimeFormatter.displayString(fromEXIF: image.exif?.dataTime) {
                    Text(date)
                        .font(.system(size: AnimalTokens.fontSM, weight: .medium))
                        .foregroundStyle(AnimalTokens.textSecondary)
                }
                Spacer(minLength: 0)
                if showDownload {
                    Button(action: onDownload) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(AnimalTokens.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !image.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(image.labels.prefix(2), id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AnimalSignatures.cardText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AnimalTokens.primaryBG)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .circular))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GalleryCellMetrics.padding)
        .padding(.vertical, AnimalTokens.spacingSM)
    }
}

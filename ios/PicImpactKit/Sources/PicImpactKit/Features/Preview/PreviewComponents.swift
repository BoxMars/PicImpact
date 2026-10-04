import SwiftUI

/// 预览图：缩略图先淡入，原图就绪后叠加淡入。
///
/// 复刻 Web 端 `progressive-image.tsx` 的分层行为：
/// - 底层是 800px 缩略图（先到，立刻可见，避免空白帧）
/// - 上层是原图，绝对定位覆盖，0.6s opacity 淡入
/// - 两者都用 `object-fit: contain` 语义（**等比且不裁切**）
public struct ProgressiveImageView: View {
    private let preview: PlatformImage?
    private let original: PlatformImage?
    private let aspectRatio: CGFloat

    public init(preview: PlatformImage?, original: PlatformImage?, aspectRatio: CGFloat) {
        self.preview = preview
        self.original = original
        self.aspectRatio = aspectRatio > 0 ? aspectRatio : 1
    }

    public var body: some View {
        ZStack {
            if let preview {
                image(preview)
                    .transition(.opacity)
            } else {
                AnimalTokens.bgSecondary
                    .overlay(ProgressView().controlSize(.small))
            }

            if let original, original !== preview {
                image(original)
                    .transition(.opacity)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .animation(.easeInOut(duration: 0.6), value: original == nil)
    }

    @ViewBuilder
    private func image(_ value: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: value)
            .resizable()
            .aspectRatio(contentMode: .fit)
        #elseif canImport(AppKit)
        Image(nsImage: value)
            .resizable()
            .aspectRatio(contentMode: .fit)
        #endif
    }
}

/// EXIF 面板：两列标签 + 值，右侧对齐。
/// 颜色取自设计令牌（label `#9f927d`、value `#725d42`），与 Web 端预览页一致。
public struct EXIFPanel: View {
    private let rows: [PreviewModel.EXIFRow]
    private let basicInfoTitle: String

    public init(rows: [PreviewModel.EXIFRow], basicInfoTitle: String = "基本信息") {
        self.rows = rows
        self.basicInfoTitle = basicInfoTitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AnimalTokens.spacingSM) {
            Text(basicInfoTitle)
                .font(.system(size: AnimalTokens.fontSize, weight: .bold))
                .foregroundStyle(AnimalTokens.text)

            ForEach(rows) { row in
                HStack(alignment: .top, spacing: AnimalTokens.spacingSM) {
                    Text(row.label)
                        .font(.system(size: AnimalTokens.fontSM, weight: .medium))
                        .foregroundStyle(AnimalTokens.textSecondary)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(.system(size: AnimalTokens.fontSM, weight: .semibold))
                        .foregroundStyle(AnimalSignatures.cardText)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }
}

/// Live Photo（`type != 1`）。
///
/// Web 端用 `<live-photo src videoSrc>` 自定义元素；iOS 直接播视频即可，
/// 若要真正以 Live Photo 保存到相册则需 `PHLivePhoto`，属后续增强。
public struct LivePhotoView: View {
    private let imageURL: URL?
    private let videoURL: URL?

    public init(imageURL: URL?, videoURL: URL?) {
        self.imageURL = imageURL
        self.videoURL = videoURL
    }

    public var body: some View {
        VStack(spacing: AnimalTokens.spacingSM) {
            if let videoURL {
                // 用 VideoPlayer 需要 AVKit；这里保持最小依赖，先给出可播放的入口
                Link(destination: videoURL) {
                    Label("播放动态照片", systemImage: "play.circle.fill")
                        .font(.system(size: AnimalTokens.fontSize, weight: .semibold))
                        .foregroundStyle(AnimalTokens.primary)
                }
            }
            if let imageURL {
                CachedAsyncImage(url: imageURL, loader: ImageLoader(), contentMode: .fit)
            }
        }
    }
}

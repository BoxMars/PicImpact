import SwiftUI

/// 画廊头部（对应 Web `simple-gallery.tsx` 的 "Island header"）。
///
/// 结构与 Web 逐项对应：
/// ```
/// icon-critterpedia(28) + [缎带标题] + icon-camera(28)   ← HStack, gap 8
/// 打字机副标题（14pt / #9f927d / 字距 0.04em）
/// 里程点胶囊：icon-miles(18) + "{n} 张照片已收集"
/// ─── 波浪分隔线 ───
/// ```
/// 容器内边距取自 Web 的 `padding: '2.5rem 1rem 0.5rem'`，元素间距 `gap: 12`。
public struct GalleryHeader: View {

    private let title: String
    private let subtitle: String
    private let photoCount: Int

    public init(title: String, subtitle: String, photoCount: Int) {
        self.title = title
        self.subtitle = subtitle
        self.photoCount = photoCount
    }

    /// Web 里的两段文案。标题实际取自站点配置（生产值与这里一致）。
    public static let defaultSubtitle = "光と影で綴る、パパとママと私の物語。"

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                // 图标 + 缎带标题 + 图标
                HStack(spacing: 8) {
                    AnimalIcon(.critterpedia, size: 28)
                    IslandRibbon(text: title, fontSize: 28)
                    AnimalIcon(.camera, size: 28)
                }

                // 打字机副标题
                Typewriter(subtitle, millisecondsPerCharacter: 60) { visible in
                    Text(visible)
                        .font(.system(size: 14, weight: .medium))
                        .tracking(0.04 * 14)
                        .foregroundStyle(AnimalTokens.textSecondary) // #9f927d
                        .multilineTextAlignment(.center)
                        // 打字过程中行高会跳动，锁一个最小高度避免整块上下抖
                        .frame(minHeight: 20)
                }

                if photoCount > 0 {
                    counterPill
                }
            }
            .padding(.top, 40)        // 2.5rem
            .padding(.horizontal, 16) // 1rem
            .padding(.bottom, 8)      // 0.5rem

            // Divider(type: wave-yellow) + margin: 0.75rem 0 0
            WaveDivider()
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    /// Nook Miles 风格的计数胶囊
    private var counterPill: some View {
        HStack(spacing: 6) {
            AnimalIcon(.miles, size: 18)
            Text("\(photoCount) 张照片已收集")
                .font(.system(size: 12, weight: .heavy))
                .tracking(0.04 * 12)
                .foregroundStyle(AnimalSignatures.cardText) // #725d42
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 14)
        .background(AnimalSignatures.cardPaper)          // rgb(247,243,223)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .circular))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .circular)
                .strokeBorder(AnimalSignatures.cardBorder, lineWidth: 1.5)
        }
        .shadow(color: AnimalSignatures.cardShadowHard, radius: 0, x: 0, y: 2)
    }
}

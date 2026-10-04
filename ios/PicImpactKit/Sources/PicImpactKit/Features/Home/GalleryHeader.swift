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
                // 图标 + 缎带标题 + 图标。
                //
                // 为什么用 ViewThatFits：Web 是桌面布局，28pt 的缎带加上左右各 1.6em 内边距
                // 接近 410pt —— 在 402pt 宽的手机上会**横向溢出被切掉**（实测包围盒顶到屏幕右缘）。
                // 这里按可用宽度逐级选更小的字号，缎带的几何全是 em 相对单位，会整体等比缩小。
                // 桌面 / iPad 上仍然取第一档 28pt，与 Web 一致。
                ViewThatFits(in: .horizontal) {
                    ribbonRow(fontSize: 28)
                    ribbonRow(fontSize: 24)
                    ribbonRow(fontSize: 21)
                    ribbonRow(fontSize: 18)
                    ribbonRow(fontSize: 16)
                    ribbonRow(fontSize: 14)
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

    /// 缎带标题行。字号越小整条缎带越窄（几何全是 em 相对单位）
    private func ribbonRow(fontSize: CGFloat) -> some View {
        HStack(spacing: 8) {
            AnimalIcon(.critterpedia, size: 28)
            IslandRibbon(text: title, fontSize: fontSize)
            AnimalIcon(.camera, size: 28)
        }
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
        // 这里原本把 .shadow 写在 .overlay 之后 —— 于是描边内侧多出一条阴影线
        // （用户反馈的"两个边框"之一）。现在统一走 islandSurface。
        .islandSurface(borderWidth: 1.5, cornerRadius: 20, shadowOffsetY: 2)
    }
}

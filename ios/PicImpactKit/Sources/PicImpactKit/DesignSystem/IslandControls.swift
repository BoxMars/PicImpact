import SwiftUI

/// ACNH 风格的分享按钮：调**系统分享面板**，分享站点上的对应链接。
///
/// 用 `ShareLink` 而不是自己包 `UIActivityViewController`：
/// 它是 SwiftUI 的标准入口，iPad 上的 popover 锚点、取消回调等都由系统处理，
/// 自己包反而容易在 iPad 上崩（popover 必须有 sourceView）。
///
/// 样式与卡片/详情页的其他控件一致：纸色底 + 描边 + 硬阴影 + 图标文字。
public struct IslandShareButton: View {
    private let url: URL
    private let label: String
    private let icon: AnimalIconName
    private let iconSize: CGFloat
    private let fontSize: CGFloat
    private let style: Style

    public enum Style {
        /// 详情页顶部那种带底/描边/阴影的胶囊
        case pill
        /// 卡片操作行那种只有图标与文字、不带边框
        case plain
    }

    public init(
        url: URL,
        label: String = "分享",
        icon: AnimalIconName = .helicopter,
        iconSize: CGFloat = 16,
        fontSize: CGFloat = 11,
        style: Style = .plain
    ) {
        self.url = url
        self.label = label
        self.icon = icon
        self.iconSize = iconSize
        self.fontSize = fontSize
        self.style = style
    }

    public var body: some View {
        ShareLink(item: url) {
            content
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .plain:
            label0
        case .pill:
            label0
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(AnimalSignatures.cardPaper)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .circular))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .circular)
                        .strokeBorder(AnimalSignatures.cardBorder, lineWidth: 1.5)
                }
                .shadow(color: AnimalSignatures.cardShadowHard, radius: 0, x: 0, y: 2)
        }
    }

    private var label0: some View {
        HStack(spacing: 5) {
            AnimalIcon(icon, size: iconSize)
            Text(label)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(AnimalSignatures.cardText) // #725d42
                .fixedSize()
        }
    }
}

/// ACNH 风格的返回按钮（图标 + 文字）。
///
/// 箭头是自己画的：这套设计系统里的 ACNH 图标（相机/里程点/购物袋…）没有方向箭头，
/// 而系统 SF Symbol 的 `chevron.left` 是细线风格，和旁边的 ACNH 图标放在一起不像一套。
/// 自绘一个圆头折线箭头更协调，也不引入外部素材。
public struct IslandBackButton: View {
    private let label: String
    private let action: () -> Void

    public init(label: String = "返回", action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Chevron(direction: .left)
                    .stroke(
                        AnimalSignatures.cardText, // #725d42
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 7, height: 12)
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AnimalSignatures.cardText)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(AnimalSignatures.cardPaper)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .circular))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .circular)
                    .strokeBorder(AnimalSignatures.cardBorder, lineWidth: 1.5)
            }
            .shadow(color: AnimalSignatures.cardShadowHard, radius: 0, x: 0, y: 2)
        }
        .buttonStyle(IslandCardPressStyle())
        .accessibilityLabel(label)
    }
}

/// 圆头折线箭头。用它而不是 SF Symbol，理由见 `IslandBackButton`。
struct Chevron: Shape {
    enum Direction {
        case left
        case right
    }

    let direction: Direction

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch direction {
        case .left:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .right:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        return path
    }
}

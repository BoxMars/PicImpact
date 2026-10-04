import SwiftUI

/// 分区标题。对应 Web `preview-image.tsx` 的 `SectionTitle`：
/// `font-size: 11 / font-weight: 800 / letter-spacing: .06em / color: #19c8b9 / uppercase`。
public struct IslandSectionTitle: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .tracking(0.06 * 11)
            .foregroundStyle(AnimalTokens.primary) // #19c8b9
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 标签—值行。对应 Web 的 `Row`：
/// label `#9f927d` / 500，value `#725d42` / 600，两端对齐。
public struct IslandRow: View {
    private let label: String
    private let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AnimalTokens.textSecondary) // #9f927d
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AnimalSignatures.cardText) // #725d42
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 虚线分隔线。对应 Web 的 `<Divider type="dashed-teal" />`：
/// `linear-gradient(to right, #19c8b9 50%, transparent 50%) center / 12px 2px repeat-x`
/// —— 也就是 6px 实 / 6px 空的 2px 高虚线，横向重复。
public struct IslandDashedDivider: View {
    private let color: Color
    private let dash: CGFloat
    private let gap: CGFloat
    private let thickness: CGFloat

    public init(
        color: Color = AnimalTokens.primary,
        dash: CGFloat = 6,
        gap: CGFloat = 6,
        thickness: CGFloat = 2
    ) {
        self.color = color
        self.dash = dash
        self.gap = gap
        self.thickness = thickness
    }

    public var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: thickness, dash: [dash, gap])
            )
        }
        .frame(height: thickness)
    }
}

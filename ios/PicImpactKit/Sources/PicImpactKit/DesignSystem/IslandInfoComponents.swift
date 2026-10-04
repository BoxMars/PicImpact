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

/// 拍摄参数项（图标 + 值）。
///
/// Web 里这里是 `ParamBadge`：高 32、圆角 16、描边 1.5 `#c4b89e`、底 `rgb(247,243,223)`、
/// 阴影 `0 2px 0 0 #bdaea0`。**按用户要求去掉了边框**，并且顺带去掉同色底与硬阴影：
/// 底色与卡片同为纸色（本来就看不出），只去描边会剩一道悬空的硬阴影，比保留边框更怪。
/// 现在是纯粹的"图标 + 文字"，与前文卡片操作行的处理一致。
///
/// 图标 14、值 11pt/700/`#725d42` 仍与 Web 一致。
public struct IslandParamBadge: View {
    private let icon: AnimalIconName
    private let value: String
    private let accessibilityLabel: String

    public init(icon: AnimalIconName, value: String, label: String) {
        self.icon = icon
        self.value = value
        self.accessibilityLabel = label
    }

    public var body: some View {
        HStack(spacing: 6) {
            AnimalIcon(icon, size: 14)
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AnimalSignatures.cardText) // #725d42
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityLabel) \(value)")
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

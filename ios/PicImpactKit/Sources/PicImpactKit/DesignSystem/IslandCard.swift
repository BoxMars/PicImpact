import SwiftUI

/// ACNH 岛屿纸卡 —— 本项目最核心的视觉元素。
///
/// 复刻自 `components/gallery/simple/gallery-image.tsx` 的实际内联样式：
///
/// ```
/// border-radius   18
/// background      rgb(247, 243, 223)
/// border          2px solid #c4b89e
/// box-shadow      0 3px 0 0 #bdaea0,        ← 硬阴影，"贴纸厚度"
///                 0 4px 16px rgba(121,79,39,0.08)   ← 柔阴影
/// transition      box-shadow .25s ease, transform .25s ease
/// ```
///
/// ## 两个最容易做丢的细节
/// 1. **硬阴影的 `radius` 必须为 0**。那不是投影，是实心偏移 —— 纸卡的"厚度"全靠它。
///    给了模糊半径就变成普通投影，整张卡立刻失去 ACNH 味。
/// 2. 圆角是 **`.circular`（正圆角）**，不是 iOS 常用的 `.continuous`（超椭圆/squircle）。
///    CSS 的 `border-radius` 对应正圆角，用错会让拐角弧度肉眼可辨地不同。
///
/// 描边用 `strokeBorder`（画在边界内侧），对应 CSS 里 `box-sizing: border-box` 时
/// border 占据元素自身盒内的行为。
public struct IslandCard<Content: View>: View {

    private let cornerRadius: CGFloat
    private let fill: Color
    private let borderColor: Color
    private let borderWidth: CGFloat
    private let hardShadowColor: Color
    private let hardShadowOffsetY: CGFloat
    private let softShadowColor: Color
    private let softShadowRadius: CGFloat
    private let softShadowOffsetY: CGFloat
    private let content: Content

    public init(
        cornerRadius: CGFloat = AnimalSignatures.cardCornerRadius,
        fill: Color = AnimalSignatures.cardPaper,
        borderColor: Color = AnimalSignatures.cardBorder,
        borderWidth: CGFloat = AnimalSignatures.cardBorderWidth,
        hardShadowColor: Color = AnimalSignatures.cardShadowHard,
        hardShadowOffsetY: CGFloat = AnimalSignatures.cardShadowOffsetY,
        softShadowColor: Color = AnimalSignatures.cardShadowSoft,
        softShadowRadius: CGFloat = AnimalSignatures.cardShadowSoftRadius,
        softShadowOffsetY: CGFloat = AnimalSignatures.cardShadowSoftOffsetY,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.fill = fill
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.hardShadowColor = hardShadowColor
        self.hardShadowOffsetY = hardShadowOffsetY
        self.softShadowColor = softShadowColor
        self.softShadowRadius = softShadowRadius
        self.softShadowOffsetY = softShadowOffsetY
        self.content = content()
    }

    private var shape: RoundedRectangle {
        // .circular 对齐 CSS border-radius；不要用 .continuous
        RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
    }

    public var body: some View {
        content
            .background(fill)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: borderWidth)
            }
            // 先硬后柔：硬阴影是"厚度"，必须保持实心（radius 0）
            .shadow(color: hardShadowColor, radius: 0, x: 0, y: hardShadowOffsetY)
            .shadow(color: softShadowColor, radius: softShadowRadius, x: 0, y: softShadowOffsetY)
    }
}

/// ACNH 的按压效果：卡片"压下去"，实心厚度消失。
///
/// 对应 `animal-island-ui` 的 `box-shadow: 0 3px 0 0 <active>` → 按下时厚度收缩。
/// 触屏上没有 hover，按压反馈就是这里最主要的状态表达（设计文档 §7）。
public struct IslandPressStyle: ButtonStyle {
    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = AnimalSignatures.cardCornerRadius) {
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        let offset = configuration.isPressed ? AnimalSignatures.cardShadowOffsetY : 0
        return configuration.label
            .offset(y: offset)
            .shadow(
                color: configuration.isPressed ? .clear : AnimalSignatures.cardShadowHard,
                radius: 0,
                x: 0,
                y: configuration.isPressed ? 0 : AnimalSignatures.cardShadowOffsetY
            )
            .animation(.easeInOut(duration: AnimalTokens.motionBase), value: configuration.isPressed)
    }
}

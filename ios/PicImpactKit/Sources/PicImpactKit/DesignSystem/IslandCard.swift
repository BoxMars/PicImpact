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
            // 先硬后柔：硬阴影是"厚度"，必须保持实心（radius 0）
            .shadow(color: hardShadowColor, radius: 0, x: 0, y: hardShadowOffsetY)
            .shadow(color: softShadowColor, radius: softShadowRadius, x: 0, y: softShadowOffsetY)
            // ⚠️ 描边必须放在阴影**之后**。
            // 反过来写（阴影在描边之后）会在描边内侧挤出一条阴影色的线：
            // 阴影作用的对象变成"含描边的合成视图"，其顶边落在卡片内部，
            // 于是卡片顶边看起来有两条边框。实测（单变量对照）：
            //   阴影在描边之后 → y30:#C4B89E y32:内容 y33:#BDAEA0 y35:内容
            //   阴影在描边之前 → y30:#C4B89E y32:内容            ← 干净
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: borderWidth)
            }
    }
}

/// 卡片类视图的按压样式：**只做位移，不叠加任何阴影**。
///
/// 卡片的"厚度"由 `IslandCard` 自己的硬阴影提供，按压时只需把卡片下移一点，
/// 视觉上就是"按进了纸面"。绝不在这里再加阴影 —— 那正是顶上出现第二条边框的原因。
///
/// 关于"1:1"：Web 端卡片只有 `:hover`（桌面）效果（硬阴影转青色 + 上移 2px），
/// 触屏没有 hover，按压反馈属于设计文档 §7 里"结果一致、实现必然不同"的范畴。
public struct IslandCardPressStyle: ButtonStyle {
    private let offset: CGFloat

    public init(offset: CGFloat = 2) {
        self.offset = offset
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? offset : 0)
            .animation(.easeInOut(duration: AnimalTokens.motionFast), value: configuration.isPressed)
    }
}

/// ACNH 的按压效果：控件"压下去"，实心厚度消失。
///
/// 对应 `animal-island-ui` 的 `box-shadow: 0 3px 0 0 <active>` → 按下时厚度收缩。
///
/// ## ⚠️ 只能用在**自身没有硬阴影**的控件上
/// 它自己会提供那层硬阴影。若套在已经带硬阴影的视图上（例如 `IslandCard`），
/// 阴影会被画两次：外层这层作用的对象是"已带阴影的整张卡"，于是它会把卡片上方那圈
/// **柔阴影也当成剪影**、整体下移 3px 画成实心 `#BDAEA0` ——
/// 结果就是卡片顶边出现第二条"边框"（实测：顶边 y 上先一条 `#C4B89E`，紧接一条 `#BDAEA0`）。
/// 卡片类视图请用 `IslandCardPressStyle`。
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

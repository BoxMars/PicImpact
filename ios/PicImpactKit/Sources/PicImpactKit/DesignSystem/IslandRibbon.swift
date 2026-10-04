import SwiftUI

/// ACNH 缎带标题（对应 `animal-island-ui` 的 `<Title size="large" color="app-pink">`）。
///
/// Web 端这个组件完全由 CSS 图形拼出来（不是图片），这里按同样的几何用 SwiftUI 画：
///
/// ```
/// ① 后面板  ×2  1.7em 见方，left/right: -0.6em，bottom: -0.4em，背景 --rb
///               用 clip-path 切出燕尾形（外侧收进去）
/// ② 折角    ×2  0.95em × 0.45em 的直角三角形（CSS 用 border 三角实现），颜色 --rk
///               位于 top: calc(100% - .05em)，左 0.15em / 右 0.16em
/// ③ 前面板      圆角 0.2em，左右各内缩 0.1em，背景 --rf，底部有一道极淡的内阴影
/// ④ 文字        白色、字重 900、字距 0.04em、padding-top 0.11em
/// ```
///
/// 层级（z-index 1→4）：后面板 → 折角 → 前面板 → 文字。
///
/// **未复刻的部分**：CSS 里前面板有一个 `perspective(11.5em) rotateX(3deg)` 的 3° 倾斜。
/// 3° 在视觉上几乎不可辨，用 SwiftUI 做透视变换会引入额外复杂度与失真风险，故略过。
public struct IslandRibbon: View {

    /// 配色。对应 CSS 变量 `--rf`（前面板）/ `--rb`（后面板）/ `--rk`（折角）/ `--rt`（文字）。
    public struct Palette: Sendable {
        public let front: Color
        public let back: Color
        public let fold: Color
        public let text: Color

        public init(front: Color, back: Color, fold: Color, text: Color) {
            self.front = front
            self.back = back
            self.fold = fold
            self.text = text
        }

        /// `color="app-pink"`：--rf #f8a6b2 / --rb #e06880 / --rk #a03060 / --rt #fff
        public static let appPink = Palette(
            front: Color(red: 0xF8 / 255, green: 0xA6 / 255, blue: 0xB2 / 255),
            back: Color(red: 0xE0 / 255, green: 0x68 / 255, blue: 0x80 / 255),
            fold: Color(red: 0xA0 / 255, green: 0x30 / 255, blue: 0x60 / 255),
            text: .white
        )
    }

    private let text: String
    private let fontSize: CGFloat
    private let palette: Palette

    public init(text: String, fontSize: CGFloat = 28, palette: Palette = .appPink) {
        self.text = text
        self.fontSize = fontSize
        self.palette = palette
    }

    /// CSS 里的 `em` 全部相对于字号
    private var em: CGFloat { fontSize }

    public var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .black))
            .tracking(0.04 * em)
            .foregroundStyle(palette.text)
            .lineLimit(1)
            .fixedSize()
            // ribbonText 的 padding-top: .11em
            .padding(.top, 0.11 * em)
            // height: 2em，padding: 0 1.6em
            .padding(.horizontal, 1.6 * em)
            .frame(height: 2 * em)
            // --- 以下 background 的书写顺序 = 从前到后 ---
            // ③ 前面板（z 3）：左右各内缩 .1em，圆角 .2em
            .background {
                RoundedRectangle(cornerRadius: 0.2 * em, style: .circular)
                    .fill(palette.front)
                    .overlay {
                        // box-shadow: inset 0 -.06em #0000000d —— 底部一道极淡的内阴影
                        RoundedRectangle(cornerRadius: 0.2 * em, style: .circular)
                            .fill(
                                LinearGradient(
                                    colors: [.clear, Color.black.opacity(0.05)],
                                    startPoint: .init(x: 0.5, y: 0.88),
                                    endPoint: .init(x: 0.5, y: 1)
                                )
                            )
                    }
                    .padding(.horizontal, 0.1 * em)
            }
            // ② 折角（z 2）
            .background(alignment: .topLeading) {
                FoldTriangle(pointingRight: true)
                    .fill(palette.fold)
                    .frame(width: 0.95 * em, height: 0.45 * em)
                    .offset(x: 0.15 * em, y: 2 * em - 0.05 * em)
            }
            .background(alignment: .topTrailing) {
                FoldTriangle(pointingRight: false)
                    .fill(palette.fold)
                    .frame(width: 0.95 * em, height: 0.45 * em)
                    .offset(x: -0.16 * em, y: 2 * em - 0.05 * em)
            }
            // ① 后面板（z 1）
            .background(alignment: .topLeading) {
                // border-radius: .08em 0 0 .08em 与 clip-path 取交集
                SwallowtailPanel(mirrored: false)
                    .fill(palette.back)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 0.08 * em,
                        bottomLeadingRadius: 0.08 * em,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0,
                        style: .circular
                    ))
                    .frame(width: 1.7 * em, height: 1.7 * em)
                    .offset(x: -0.6 * em, y: 0.7 * em)
            }
            .background(alignment: .topTrailing) {
                // border-radius: 0 .08em .08em 0
                SwallowtailPanel(mirrored: true)
                    .fill(palette.back)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0.08 * em,
                        topTrailingRadius: 0.08 * em,
                        style: .circular
                    ))
                    .frame(width: 1.7 * em, height: 1.7 * em)
                    .offset(x: 0.6 * em, y: 0.7 * em)
            }
    }
}

// MARK: - 形状

/// 后面板：圆角矩形 + 燕尾形裁切。
///
/// CSS 是 `border-radius: .08em 0 0 .08em` 与
/// `clip-path: polygon(100% 0%, 100% 100%, 0% 100%, 30% 50%, 0% 0%)` 叠加（取交集）。
/// 这里用两层 `clipShape` 表达同一个交集。
struct SwallowtailPanel: Shape {
    let mirrored: Bool

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        if mirrored {
            // polygon(0 0, 100% 0, 70% 50%, 100% 100%, 0 100%)
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: 0.7 * w, y: 0.5 * h))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
        } else {
            // polygon(100% 0, 100% 100%, 0 100%, 30% 50%, 0 0)
            path.move(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: 0.3 * w, y: 0.5 * h))
            path.addLine(to: CGPoint(x: 0, y: 0))
        }
        path.closeSubpath()
        return path
    }
}

/// 折角：CSS 用 border 造出来的直角三角形。
///
/// - 左折角：`border-width: 0 .95em .45em 0` + 右边框着色 → 顶点 (w,0) (w,h) (0,0)
/// - 右折角：`border-width: 0 0 .45em .95em` + 左边框着色 → 顶点 (0,0) (0,h) (w,0)
struct FoldTriangle: Shape {
    /// true = 直角边在右侧（左折角），false = 直角边在左侧（右折角）
    let pointingRight: Bool

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        if pointingRight {
            path.move(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: 0))
        } else {
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: w, y: 0))
        }
        path.closeSubpath()
        return path
    }
}

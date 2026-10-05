import SwiftUI

extension View {
    /// 岛屿外观：填充 → 裁剪 → **硬阴影** → 柔阴影（可选） → **描边**。
    ///
    /// ## ⚠️ 顺序不能变：阴影一律在描边**之前**
    /// 反过来写（描边在前、阴影在后）会在描边内侧挤出一条阴影色的线 ——
    /// 看起来这个控件有**两条边框**。实测剖面（顶边，2x）：
    /// ```
    /// y20-22 #C4B89E 描边   y23 #F7F3DF 纸色   y24-26 #BDAEA0 阴影   y27 #F7F3DF
    /// ```
    ///
    /// ## 为什么必须合并到一个函数
    /// 这个"纸色底 + 描边 + 硬阴影"的模式原先在**五个地方各写了一遍**，
    /// 其中**三处写反了顺序**（骨架、计数胶囊、地图标记），用户为此反馈过三次。
    /// 手写多遍必然出错 —— 所以现在只留这一个实现，顺序只有一处可能写错。
    func islandSurface(
        fill: Color = AnimalSignatures.cardPaper,
        border: Color = AnimalSignatures.cardBorder,
        borderWidth: CGFloat = 2,
        cornerRadius: CGFloat,
        shadowColor: Color = AnimalSignatures.cardShadowHard,
        shadowOffsetY: CGFloat = 3,
        softShadow: (color: Color, radius: CGFloat, offsetY: CGFloat)? = nil
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        return self
            .background(fill)
            .clipShape(shape)
            // 硬阴影是"厚度"，必须保持实心（radius 0）
            .shadow(color: shadowColor, radius: 0, x: 0, y: shadowOffsetY)
            .shadow(
                color: softShadow?.color ?? .clear,
                radius: softShadow?.radius ?? 0,
                x: 0,
                y: softShadow?.offsetY ?? 0
            )
            // 描边最后 —— 顺序反了就会出现"两条边框"
            .overlay {
                shape.strokeBorder(border, lineWidth: borderWidth)
            }
    }

    /// 胶囊：小一号的岛屿外观（返回 / 分享按钮用）
    func islandPill(cornerRadius: CGFloat = 16) -> some View {
        islandSurface(borderWidth: 1.5, cornerRadius: cornerRadius, shadowOffsetY: 2)
    }
}

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
                .islandPill()
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

/// ACNH 风格的「箭头 + 文字」胶囊按钮（返回 / 回到顶部共用）。
///
/// 箭头是**自绘**的：这套 ACNH 图标（相机/聊天/图鉴/设计/DIY/直升机/地图/里程点/
/// 购物袋/光圈）里**没有方向箭头**，而 SF Symbol 的细线箭头与它们不是一套语言。
/// 另外库里也没有"向上"语义的图标，所以"回到顶部"同样用自绘箭头，
/// 视觉上与返回按钮保持同一套。
public struct IslandChevronButton: View {
    private let direction: Chevron.Direction
    private let label: String
    private let action: () -> Void

    public init(direction: Chevron.Direction, label: String, action: @escaping () -> Void) {
        self.direction = direction
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Chevron(direction: direction)
                    .stroke(
                        AnimalSignatures.cardText, // #725d42
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
                    // up / down 是"竖着的"箭头，宽高要对调
                    .frame(
                        width: direction == .up ? 12 : 7,
                        height: direction == .up ? 7 : 12
                    )
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AnimalSignatures.cardText)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .islandPill()
        }
        .buttonStyle(IslandCardPressStyle())
        .accessibilityLabel(label)
    }
}

/// 返回按钮（等价于 `IslandChevronButton(direction: .left, label: "返回")`）
public struct IslandBackButton: View {
    private let label: String
    private let action: () -> Void

    public init(label: String = "返回", action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some View {
        IslandChevronButton(direction: .left, label: label, action: action)
    }
}

/// 圆头折线箭头。用它而不是 SF Symbol，理由见 `IslandBackButton`。
/// 自绘的圆头折线箭头。公开是为了让 `IslandChevronButton` 的公开接口能引用它的方向。
public struct Chevron: Shape {
    public enum Direction: Sendable {
        case left
        case right
        case up
    }

    public let direction: Direction

    public init(direction: Direction) {
        self.direction = direction
    }

    public func path(in rect: CGRect) -> Path {
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
        case .up:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        return path
    }
}

extension View {
    /// 页面底色 + **盖住顶部安全区（状态栏）**。
    ///
    /// ## 适用范围：**只给详情页用**
    /// 首页刻意保留沉浸式（内容可以滚到状态栏底下），所以首页**不要**加这个。
    /// 用户明确说明：状态栏不出现内容这条限制只针对详情页。
    ///
    /// ## 为什么需要
    /// 详情页隐藏了系统导航栏（为了用自绘的 ACNH 顶栏），而 `ScrollView` 的内容
    /// 会**溢出到安全区**（SwiftUI 的固有行为：内容可以滚进状态栏，但贴在它上面的
    /// overlay / background 不会）。于是图片会从状态栏底下透出来，
    /// 时间与电量压在照片上根本看不清。
    ///
    /// ## ⚠️ 必须先 `.clipped()`
    /// 只加一层 `.background(...ignoresSafeArea())` 是**没用的** ——
    /// 溢出的内容会把那层背景挡住。实测（状态栏区域里页面底色的占比）：
    /// ```
    /// 不加处理                0%（全是照片）
    /// 只加忽略安全区的背景      0%（被溢出的内容挡住）
    /// 先 clipped 再加背景      100%（#F8F8F0 + 灵动岛，照片不再透出）
    /// ```
    func islandPageBackground(_ color: Color? = nil) -> some View {
        self
            // 先把溢出到安全区的滚动内容裁掉
            .clipped()
            // 底色铺满整屏：上下两条安全区都覆盖。
            // 只忽略顶部会漏出**窗口白底**（实测详情页底部 30pt 变成 #FFFFFF）——
            // 因为内容被允许延伸到底边，而底色没跟过去。
            .background((color ?? AnimalTokens.bg).ignoresSafeArea())
    }
}

#if canImport(UIKit)
import UIKit

/// 重新启用系统的「边缘右滑返回」手势。
///
/// ## 为什么需要
/// 详情页用 `.toolbar(.hidden, for: .navigationBar)` 隐藏了系统导航栏
/// （为了用自绘的 ACNH 顶栏）。而**隐藏导航栏会让
/// `UINavigationController.interactivePopGestureRecognizer` 失效** ——
/// 于是右滑退出的手势用不了。这是 UIKit 的既有行为，不是 SwiftUI 的 bug。
///
/// 修法是把这个手势重新接上：把它的 delegate 换成我们自己，
/// 在「栈里还有上一页」时允许手势开始。
///
/// ## 为什么 delegate 要判断层数
/// 如果无条件返回 true，在根页面上也会开始手势，
/// 结果导航栈会卡住（页面滑到一半回不来）—— 这是这个 hack 常见的坑。
struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        EnablerController(coordinator: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // 每次更新也重试一次：详情页是**被 push 进来的**，viewDidAppear 时机之外
        // 还可能因为导航层级变化而丢 delegate。
        (uiViewController as? EnablerController)?.attach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 用一个真正的子控制器，在 `viewDidAppear` 里接管手势 ——
    /// 比原来"DispatchQueue.main.async 一次性尝试"可靠：那一次很可能早于视图进入导航层级，
    /// 于是 navigationController 还是 nil，delegate 根本没设上。
    final class EnablerController: UIViewController {
        private weak var coordinator: Coordinator?
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("不支持") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
        }

        func attach() {
            guard let navigation = navigationController,
                  let gesture = navigation.interactivePopGestureRecognizer,
                  let coordinator else { return }
            gesture.isEnabled = true
            gesture.delegate = coordinator
            // 把导航控制器交给 coordinator —— 不要在手势回调里 cast gesture.view
            coordinator.navigation = navigation
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// 由 EnablerController 在拿到导航控制器后写入。
        ///
        /// ⚠️ 不要在 `gestureRecognizerShouldBegin` 里用
        /// `gestureRecognizer.view as? UINavigationController` 来判断：
        /// **那个 view 不保证是导航控制器**，cast 失败就会 return false，
        /// 结果是手势永远无法开始 —— 这正是"详情页不能右滑返回"的成因（用户反馈过两次）。
        weak var navigation: UINavigationController?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // 拿不到导航控制器时不拦（交给系统判断），拿得到就只在非根页面放行
            guard let navigation else { return true }
            return navigation.viewControllers.count > 1
        }
    }
}

#endif

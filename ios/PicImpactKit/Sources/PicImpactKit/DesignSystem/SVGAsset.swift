import SwiftUI

/// 渲染包内任意 SVG 资源（按 viewBox 等比 `contain` 缩放并居中）。
///
/// 与 CSS 的 `background-size: contain; background-position: center` 语义一致 ——
/// `animal-island-ui` 的图标与分隔线都是这么摆放的。
///
/// `AnimalIcon` 是它的类型化封装（限定在 8 个图标名内），
/// 这里保留通用入口给分隔线等其他素材。
public struct SVGAsset: View {
    private let resourceName: String

    public init(_ resourceName: String) {
        self.resourceName = resourceName
    }

    public var body: some View {
        Canvas { context, canvasSize in
            guard let icon = AnimalIconCache.shared.icon(named: resourceName),
                  icon.viewBox.width > 0, icon.viewBox.height > 0 else { return }

            // ⚠️ 必须挡住"某一维无约束"的情况。
            // 无约束时 canvasSize 的对应分量是无穷大，scale 也会变成无穷大，
            // 而 `context.scaleBy(x: .infinity)` 会让 CoreGraphics **直接卡死**
            // （实测：分隔线放在弹性容器里就会触发，且不报错、只是永远不返回）。
            // 这里选择"不画"而不是猜一个尺寸 —— 调用方给了有限尺寸就会正常绘制。
            guard canvasSize.width.isFinite, canvasSize.height.isFinite,
                  canvasSize.width > 0, canvasSize.height > 0 else { return }

            let scale = min(
                canvasSize.width / icon.viewBox.width,
                canvasSize.height / icon.viewBox.height
            )
            guard scale.isFinite, scale > 0 else { return }
            let offsetX = (canvasSize.width - icon.viewBox.width * scale) / 2
                - icon.viewBox.minX * scale
            let offsetY = (canvasSize.height - icon.viewBox.height * scale) / 2
                - icon.viewBox.minY * scale

            context.translateBy(x: offsetX, y: offsetY)
            context.scaleBy(x: scale, y: scale)

            for shape in icon.shapes {
                context.fill(
                    shape.path,
                    with: .color(shape.color),
                    style: FillStyle(eoFill: shape.evenOdd)
                )
            }
        }
        .accessibilityHidden(true)
    }
}

/// 波浪分隔线（对应 Web 的 `<Divider type="wave-yellow" style={{ margin: '0.75rem 0 0' }} />`）。
///
/// Web 的 `.animal-divider` 是 `width:100%; height:12px`，
/// 背景为 `url(wave-yellow.svg) center / contain no-repeat` ——
/// 注意是 **contain + 不重复**：素材是 375×10，在 12px 高的框里会被缩放到约 450×12 并居中，
/// 并不会横向平铺。这里照此实现，不做"看起来更合理"的平铺。
public struct WaveDivider: View {
    public init() {}

    public var body: some View {
        SVGAsset("wave-yellow")
            .frame(height: 12)
            .frame(maxWidth: .infinity)
    }
}

/// 打字机逐字显示（对应 Web 的 `<Typewriter speed={60}>`）。
///
/// Web 的 `speed` 单位是毫秒/字；这里也用它作参数名与默认值，避免两边对不上。
public struct Typewriter<Content: View>: View {
    private let text: String
    private let millisecondsPerCharacter: Double
    private let content: (String) -> Content

    @State private var visibleCount = 0
    @State private var task: Task<Void, Never>?

    public init(
        _ text: String,
        millisecondsPerCharacter: Double = 60,
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        self.text = text
        self.millisecondsPerCharacter = millisecondsPerCharacter
        self.content = content
    }

    public var body: some View {
        content(String(text.prefix(visibleCount)))
            .onAppear { start() }
            .onDisappear { task?.cancel(); task = nil }
    }

    private func start() {
        task?.cancel()
        visibleCount = 0
        task = Task { @MainActor in
            let interval = UInt64(max(0, millisecondsPerCharacter) * 1_000_000)
            for index in 1...max(1, text.count) {
                if Task.isCancelled { return }
                if index <= text.count { visibleCount = index }
                if interval > 0 {
                    try? await Task.sleep(nanoseconds: interval)
                }
            }
        }
    }
}

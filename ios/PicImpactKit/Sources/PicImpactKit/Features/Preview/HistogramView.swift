import SwiftUI

/// 直方图视图。
///
/// 逐项复刻 Web 端 `histogram-chart.tsx` 的绘制参数：
/// - 背景 `rgba(28,28,30,0.95)`
/// - 网格线 `rgba(255,255,255,0.04)`，`0.5` 宽，等分 3 条
/// - 四个通道：红 `rgb(255,105,97)`、绿 `rgb(52,199,89)`、蓝 `rgb(64,156,255)`、
///   亮度 `rgba(255,255,255,0.6)`
/// - **亮度通道先画**（alpha 0.3）作为背景，再叠加 RGB
/// - 柱宽 = 图表宽 / 箱数，实际绘制宽度取其 0.8
///
/// ## 最容易做错的视觉细节
/// **每根柱的渐变是从「这根柱自己的顶部」到底部**（顶部不透明 → 底部 10% 透明度），
/// 而不是整块图表区域一个渐变。若改成后者，矮柱只会显示渐变的淡色中段、几乎看不见，
/// 与 Web 的形状明显不同。所以这里对每根柱单独构造渐变。
public struct HistogramView: View {
    public let histogram: Histogram

    public init(histogram: Histogram) {
        self.histogram = histogram
    }

    private enum Palette {
        static let background = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.95)
        static let grid = Color.white.opacity(0.04)
        static let red = Color(red: 255 / 255, green: 105 / 255, blue: 97 / 255)
        static let green = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
        static let blue = Color(red: 64 / 255, green: 156 / 255, blue: 255 / 255)
        static let luminance = Color.white.opacity(0.6)
    }

    public var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height

            context.fill(
                Path(CGRect(x: 0, y: 0, width: width, height: height)),
                with: .color(Palette.background)
            )

            // 3 条极简网格线
            for index in 1...3 {
                let y = (height / 4) * CGFloat(index)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
                context.stroke(path, with: .color(Palette.grid), lineWidth: 0.5)
            }

            let maxValue = histogram.maxValue
            guard maxValue > 0 else { return }

            // 先画亮度通道（作为背景），再叠加 RGB —— 顺序与 Web 一致
            drawBars(context: &context, data: histogram.luminance, color: Palette.luminance,
                     alpha: 0.3, maxValue: maxValue, size: size)
            drawBars(context: &context, data: histogram.red, color: Palette.red,
                     alpha: 1, maxValue: maxValue, size: size)
            drawBars(context: &context, data: histogram.green, color: Palette.green,
                     alpha: 1, maxValue: maxValue, size: size)
            drawBars(context: &context, data: histogram.blue, color: Palette.blue,
                     alpha: 1, maxValue: maxValue, size: size)
        }
        .background(Palette.background)
    }

    private func drawBars(
        context: inout GraphicsContext,
        data: [Int],
        color: Color,
        alpha: Double,
        maxValue: Int,
        size: CGSize
    ) {
        guard !data.isEmpty, maxValue > 0 else { return }
        let width = size.width
        let height = size.height
        let barWidth = width / CGFloat(data.count)

        for (index, value) in data.enumerated() where value > 0 {
            let barHeight = (CGFloat(value) / CGFloat(maxValue)) * height
            let x = CGFloat(index) * barWidth
            let y = height - barHeight

            // 关键：每根柱各自的渐变（顶部自身色 → 底部 10% 透明度）
            let top = color.opacity(alpha)
            let bottom = color.opacity(alpha * 0.1)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [top, bottom]),
                startPoint: CGPoint(x: x, y: y),
                endPoint: CGPoint(x: x, y: height)
            )
            context.fill(
                Path(CGRect(x: x, y: y, width: barWidth * 0.8, height: barHeight)),
                with: shading
            )
        }
    }
}

/// 影调分析面板
public struct ToneAnalysisView: View {
    public let analysis: ToneAnalysis
    private let labels: [ToneAnalysis.ToneType: String]

    public init(analysis: ToneAnalysis, labels: [ToneAnalysis.ToneType: String] = [:]) {
        self.analysis = analysis
        self.labels = labels
    }

    /// 影调类型的文案。**必须**与 Web 的 `getToneTypeLabel` 映射一致：
    /// 它走 i18n 键（`Exif.toneLowKey` 等），值是"低调/高调/正常/高对比度"。
    /// 早先这里硬编码成"常规""高对比"——是错的，与 Web 显示不一致。
    private var defaultLabels: [ToneAnalysis.ToneType: String] {
        [
            .lowKey: IslandStrings.text("Exif.toneLowKey"),
            .highKey: IslandStrings.text("Exif.toneHighKey"),
            .normal: IslandStrings.text("Exif.toneNormal"),
            .highContrast: IslandStrings.text("Exif.toneHighContrast"),
        ]
    }

    private var labelFont: Font { .system(size: 12, weight: .medium) }
    private var valueColor: Color { AnimalSignatures.cardText } // #725d42

    public var body: some View {
        VStack(spacing: 9) {
            // 影调结论单独一行，值用更粗的字重
            HStack(spacing: 8) {
                Text(IslandStrings.text("Exif.toneType"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AnimalTokens.textSecondary)
                Spacer(minLength: 0)
                Text(labels[analysis.toneType] ?? defaultLabels[analysis.toneType] ?? analysis.toneType.rawValue)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(valueColor)
            }

            // 四项指标：标签 + 进度条 + 数值。
            // 数值与 Web 完全一致（亮度/对比度直接加 %，阴影/高光乘 100 取整），
            // 进度条是纯粹的视觉增强，让四个比例一眼可比。
            metric("Exif.brightness", percent: analysis.brightness)
            metric("Exif.contrast", percent: analysis.contrast)
            metric("Exif.shadowRatio", percent: Int((analysis.shadowRatio * 100).rounded()))
            metric("Exif.highlightRatio", percent: Int((analysis.highlightRatio * 100).rounded()))
        }
    }

    private func metric(_ titleKey: String, percent: Int) -> some View {
        HStack(spacing: 8) {
            Text(IslandStrings.text(titleKey))
                .font(labelFont)
                .foregroundStyle(AnimalTokens.textSecondary)
                .frame(width: 58, alignment: .leading)
            ToneBar(percent: percent)
            Text("\(percent)%")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(valueColor)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

/// 影调指标的比例条（纯视觉增强，不承载信息）。
public struct ToneBar: View {
    private let percent: Int

    public init(percent: Int) {
        self.percent = percent
    }

    public var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(percent, 0), 100)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AnimalSignatures.cardBorder.opacity(0.35))
                Capsule()
                    .fill(AnimalTokens.primary) // #19c8b9
                    // 最小值 3 让 0% 附近也留一点可见的形状，避免看起来像没渲染
                    .frame(width: max(3, proxy.size.width * CGFloat(clamped) / 100))
            }
        }
        .frame(height: 8)
    }
}

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

    private var defaultLabels: [ToneAnalysis.ToneType: String] {
        [
            .lowKey: "低调",
            .highKey: "高调",
            .normal: "常规",
            .highContrast: "高对比",
        ]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AnimalTokens.spacingSM) {
            Text(labels[analysis.toneType] ?? defaultLabels[analysis.toneType] ?? analysis.toneType.rawValue)
                .font(.system(size: AnimalTokens.fontSize, weight: .bold))
                .foregroundStyle(AnimalTokens.text)

            row("亮度", "\(analysis.brightness)")
            row("对比度", "\(analysis.contrast)")
            row("暗部", String(format: "%.0f%%", analysis.shadowRatio * 100))
            row("亮部", String(format: "%.0f%%", analysis.highlightRatio * 100))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: AnimalTokens.fontSM, weight: .medium))
                .foregroundStyle(AnimalTokens.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: AnimalTokens.fontSM, weight: .semibold))
                .foregroundStyle(AnimalSignatures.cardText)
        }
    }
}

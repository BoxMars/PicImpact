import CoreGraphics
import SwiftUI
import Testing

@testable import PicImpactKit

/// T11 渲染验证：直方图的视觉签名。
///
/// 重点是**每根柱自身的渐变**（顶部不透明 → 底部 10% 透明度）。
/// 若误做成"整块图表一个渐变"，矮柱会几乎看不见 —— 这是 Web 端明确记录过的视觉特征，
/// 所以这里用像素断言把它固定住。
///
/// 手法：让**只有一个通道非零**来隔离被测对象（否则亮度通道会以 0.3 alpha 垫在下面，
/// 叠色后就无法精确判定）。
@Suite("T11 · 直方图渲染（像素级）")
@MainActor
struct HistogramViewTests {

    typealias Pixels = IslandCardTests.Pixels

    static func rasterize(_ view: some View, width: CGFloat, height: CGFloat) -> Pixels? {
        IslandCardTests.rasterize(view.frame(width: width, height: height))
    }

    static func emptyBins() -> [Int] { [Int](repeating: 0, count: Histogram.binCount) }

    /// 只有红通道的第 0 箱有值 → 画出一根满高的红柱，其余区域为背景
    static func singleRedBarHistogram(value: Int = 1000) -> Histogram {
        var red = emptyBins()
        red[0] = value
        return Histogram(red: red, green: emptyBins(), blue: emptyBins(), luminance: emptyBins())
    }

    @Test("无数据区显示的是深色背景 rgba(28,28,30,0.95)")
    func backgroundIsDarkPanel() throws {
        let view = HistogramView(histogram: Self.singleRedBarHistogram())
        let pixels = try #require(Self.rasterize(view, width: 256, height: 128), "未产出图像")
        // 右侧没有柱子
        let ok = pixels.matches(220, 64, 0x1C1C1E, tolerance: 6)
        #expect(ok, "空白区应为深色面板，实际 \(pixels.describe(220, 64))")
    }

    @Test("柱子顶部接近该通道的本色（红 rgb(255,105,97)）")
    func barTopIsChannelColor() throws {
        let view = HistogramView(histogram: Self.singleRedBarHistogram())
        let pixels = try #require(Self.rasterize(view, width: 256, height: 128))
        // 第 0 箱：barWidth = 256/128 = 2，实际绘制宽度 1.6，取 x=0
        let top = pixels.at(0, 3)
        #expect(top.a > 200, "柱顶应基本不透明，实际 \(pixels.describe(0, 3))")
        #expect(top.r > 200, "柱顶红色分量应很高，实际 \(pixels.describe(0, 3))")
        #expect(top.g > 60 && top.g < 150, "柱顶绿色分量应接近 105，实际 \(pixels.describe(0, 3))")
    }

    @Test("柱身向下渐隐：底部明显比顶部暗（这就是那个视觉签名）")
    func barFadesTowardBottom() throws {
        let view = HistogramView(histogram: Self.singleRedBarHistogram())
        let pixels = try #require(Self.rasterize(view, width: 256, height: 128))

        let top = pixels.at(0, 3).r
        let middle = pixels.at(0, 64).r
        let bottom = pixels.at(0, 124).r

        #expect(top > middle, "红色分量应随高度递减：顶部 \(top)，中部 \(middle)")
        #expect(middle >= bottom, "红色分量应随高度递减：中部 \(middle)，底部 \(bottom)")
        // 底部按 10% 透明度与深色背景混合，必然明显低于顶部
        #expect(bottom < top / 2, "底部应明显更暗：顶部 \(top)，底部 \(bottom)")
    }

    @Test("亮度通道若有值会被画成浅色（且先于 RGB 绘制）")
    func luminanceChannelDrawsPale() throws {
        var luminance = Self.emptyBins()
        luminance[0] = 1000
        let histogram = Histogram(
            red: Self.emptyBins(), green: Self.emptyBins(), blue: Self.emptyBins(), luminance: luminance
        )
        let pixels = try #require(Self.rasterize(HistogramView(histogram: histogram), width: 256, height: 128))
        // 白色 0.6 alpha × 绘制 alpha 0.3 ≈ 0.18，叠在深色背景上 → 偏暗的灰
        let sample = pixels.at(0, 3)
        #expect(sample.r > 40, "亮度柱应比背景亮，实际 \(pixels.describe(0, 3))")
        #expect(sample.r < 200, "亮度柱不该是纯白（alpha 已衰减），实际 \(pixels.describe(0, 3))")
    }

    @Test("全部为零时不崩、只画背景")
    func zeroHistogramDrawsBackgroundOnly() throws {
        let histogram = Histogram(
            red: Self.emptyBins(), green: Self.emptyBins(), blue: Self.emptyBins(), luminance: Self.emptyBins()
        )
        let pixels = try #require(Self.rasterize(HistogramView(histogram: histogram), width: 256, height: 128))
        let ok = pixels.matches(128, 64, 0x1C1C1E, tolerance: 6)
        #expect(ok, "全零时整块应只有背景，实际 \(pixels.describe(128, 64))")
    }

    @Test("矮柱不被渐隐吃掉：柱顶仍是接近本色的不透明色")
    func shortBarStaysVisible() throws {
        // 这条断言才是真正能区分"每根柱各自渐变"与"整块图表一个渐变"的用例。
        // 满高的柱子不行：满高时 y = 0，两种写法的渐变端点完全相同，测不出差别。
        // 矮柱才有差别 —— 若用整块渐变，矮柱位于渐变的尾段，会淡到几乎看不见
        //（这正是 Web 端记录过的错误做法）。
        var red = Self.emptyBins()
        red[0] = 100 // 矮柱：高度 = 100/1000 × 128 ≈ 12.8
        red[100] = 1000 // 归一化基准（放在很右边，避免与 x∈[0,1.6) 的矮柱重叠）
        let histogram = Histogram(
            red: red, green: Self.emptyBins(), blue: Self.emptyBins(), luminance: Self.emptyBins()
        )
        let pixels = try #require(Self.rasterize(HistogramView(histogram: histogram), width: 256, height: 128))

        // 矮柱从 y ≈ 115 向上，取柱身内部一行
        let top = pixels.at(0, 116)
        #expect(
            top.a > 200,
            "矮柱柱顶应基本不透明（每根柱各自的渐变），实际 \(pixels.describe(0, 116))"
        )
        #expect(top.r > 200, "矮柱柱顶应是该通道本色，实际 \(pixels.describe(0, 116))")

        // 对照：在矮柱右侧的图表底部区域（无柱子）应仍是背景色
        let belowMatches = pixels.matches(60, 126, 0x1C1C1E, tolerance: 6)
        #expect(
            belowMatches,
            "无柱子处应保持背景色，实际 \(pixels.describe(60, 126))"
        )
    }

    @Test("归一化以四通道全局最大值为准（与 Web 的 maxVal 一致）")
    func normalizationUsesGlobalMax() {
        var red = Self.emptyBins()
        var green = Self.emptyBins()
        red[10] = 500
        green[10] = 1000
        let histogram = Histogram(red: red, green: green, blue: Self.emptyBins(), luminance: Self.emptyBins())
        #expect(histogram.maxValue == 1000, "应取四通道全局最大值，实际 \(histogram.maxValue)")
    }
}

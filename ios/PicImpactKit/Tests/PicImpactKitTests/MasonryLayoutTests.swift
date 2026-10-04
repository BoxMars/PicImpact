import CoreGraphics
import Foundation
import Testing

@testable import PicImpactKit

/// T6 验证：行优先瀑布流布局。
///
/// 核心手段是**与真实浏览器渲染结果对齐**：`Fixtures/masonry-browser-golden.json` 是
/// Chrome 用 Web 端同一个 `MasonryGrid` 组件渲染 12 张卡后导出的实际坐标。
/// 如果 Swift 实现的放置规则与 CSS Grid 有任何偏差，逐项 x/y 比对就会失败。
@Suite("T6 · 行优先瀑布流布局")
struct MasonryLayoutTests {

    /// 计划里指定的 12 个高度（与浏览器探针用的完全一致）
    static let designHeights: [CGFloat] = [180, 260, 140, 300, 200, 160, 240, 120, 280, 190, 220, 150]

    struct GoldenItem: Decodable {
        let n: Int
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }

    struct Golden: Decodable {
        let containerWidth: Double
        let columnGap: String
        let gridAutoRows: String
        let rowGap: String
        let items: [GoldenItem]
    }

    static let golden: Golden? = {
        guard let url = Bundle.module.url(
            forResource: "masonry-browser-golden",
            withExtension: "json",
            subdirectory: "Fixtures"
        ),
        let data = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(Golden.self, from: data)
        else {
            Issue.record("找不到浏览器基准 masonry-browser-golden.json —— 无法证明与 Web 一致")
            return nil
        }
        return decoded
    }()

    // MARK: - 与真实浏览器比对（最重要的一条）

    @Test("放置结果与 Chrome 实际渲染逐项一致（x/y）")
    func matchesBrowserGolden() throws {
        let golden = try #require(Self.golden)
        // 基准里记录的是 Web 的真实参数，先断言这几点没变（变了说明 Web 端改过，基准需重取）
        #expect(golden.columnGap == "16px", "Web 的 columnGap 变了，基准需重新生成")
        #expect(golden.gridAutoRows == "8px", "Web 的 grid-auto-rows 变了，基准需重新生成")
        #expect(golden.rowGap == "0px", "Web 的行间距实现方式变了，基准需重新生成")

        let layout = MasonryLayout.layout(
            heights: golden.items.map { CGFloat($0.h) },
            metrics: .web(containerWidth: CGFloat(golden.containerWidth), columns: 3)
        )

        #expect(layout.placements.count == golden.items.count)

        for (index, expected) in golden.items.enumerated() {
            let actual = layout.placements[index]
            // 列宽是分数（1248-32)/3 = 405.333…，浏览器对最后一列有舍入分配，
            // 因此 x 给 0.05 的容差；y 必须精确（它只是 row * 8）
            #expect(
                abs(actual.frame.minX - CGFloat(expected.x)) < 0.05,
                "第 \(expected.n) 项 x 不一致：Swift \(actual.frame.minX)，浏览器 \(expected.x)"
            )
            #expect(
                actual.frame.minY == CGFloat(expected.y),
                "第 \(expected.n) 项 y 不一致：Swift \(actual.frame.minY)，浏览器 \(expected.y)"
            )
        }
    }

    // MARK: - 计划里的四条断言

    @Test("断言 1：最上面一排按 x 排序是 [1,2,3]（行优先，不是列优先）")
    func firstRowIsRowMajor() throws {
        let golden = try #require(Self.golden)
        let layout = MasonryLayout.layout(
            heights: golden.items.map { CGFloat($0.h) },
            metrics: .web(containerWidth: CGFloat(golden.containerWidth), columns: 3)
        )
        let minY = layout.placements.map(\.frame.minY).min() ?? 0
        let firstRow = layout.placements
            .filter { $0.frame.minY == minY }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { $0.index + 1 }
        #expect(firstRow == [1, 2, 3], "第一排应为 [1,2,3]，实际 \(firstRow)")
    }

    @Test("断言 2：视觉阅读顺序（先 y 后 x）是 1…12 连续")
    func readingOrderIsSequential() throws {
        let golden = try #require(Self.golden)
        let layout = MasonryLayout.layout(
            heights: golden.items.map { CGFloat($0.h) },
            metrics: .web(containerWidth: CGFloat(golden.containerWidth), columns: 3)
        )
        let order = layout.placements
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .map { $0.index + 1 }
        #expect(order == Array(1...12), "阅读顺序应为 1…12，实际 \(order)")
    }

    @Test("断言 3：每项高度等于内容高度（未被容器拉伸）")
    func heightsAreNotStretched() throws {
        let layout = MasonryLayout.layout(
            heights: Self.designHeights,
            metrics: .web(containerWidth: 1248, columns: 3)
        )
        for (index, expected) in Self.designHeights.enumerated() {
            let actual = layout.placements[index].frame.height
            // 这正是 Web 端踩过的坑：一旦被拉伸，这里会变成 3448 而不是 180
            #expect(actual == expected, "第 \(index + 1) 项高度应为 \(expected)，实际 \(actual)")
        }
    }

    @Test("断言 4：占位高度足够放下内容并留出间距，且总高有界")
    func areaHeightsLeaveGapAndAreBounded() throws {
        let layout = MasonryLayout.layout(
            heights: Self.designHeights,
            metrics: .web(containerWidth: 1248, columns: 3)
        )
        for placement in layout.placements {
            let leftover = placement.areaHeight - placement.frame.height
            #expect(leftover >= 16, "第 \(placement.index + 1) 项底部间距只有 \(leftover)，应 ≥ 16")
            #expect(leftover < 16 + 8, "第 \(placement.index + 1) 项底部间距 \(leftover) 超出取整误差")
        }
        // 总高应为"所有项占位高度之和 / 列数"的量级，绝不该出现失控增长
        let naive = Self.designHeights.reduce(0, +) / 3
        #expect(layout.contentHeight < naive * 2, "总高 \(layout.contentHeight) 异常（可能是正反馈）")
    }

    // MARK: - 边界与参数

    @Test("空输入不崩")
    func emptyInput() {
        let layout = MasonryLayout.layout(heights: [], metrics: .web(containerWidth: 1248, columns: 3))
        #expect(layout.placements.isEmpty)
        #expect(layout.contentHeight == 0)
    }

    @Test("列宽与 Web 的 grid-template-columns 一致")
    func columnWidthMatchesCSS() {
        let metrics = MasonryLayout.Metrics.web(containerWidth: 1248, columns: 3)
        // 浏览器实测得到的模板列宽（见基准 templateColumns）
        #expect(abs(metrics.columnWidth - 405.328) < 0.01, "列宽 \(metrics.columnWidth) 与浏览器不符")
    }

    @Test("响应式断点与 Web 的 sm/lg 对齐")
    func breakpointsMatchWeb() {
        // Tailwind: grid-cols-1 / sm(640)-grid-cols-2 / lg(1024)-grid-cols-3
        #expect(MasonryLayout.columns(forWidth: 393) == 1)
        #expect(MasonryLayout.columns(forWidth: 639) == 1)
        #expect(MasonryLayout.columns(forWidth: 640) == 2)
        #expect(MasonryLayout.columns(forWidth: 1023) == 2)
        #expect(MasonryLayout.columns(forWidth: 1024) == 3)
        // Tailwind: px-3 / sm(640)-px-6 / md(768)-px-10
        #expect(MasonryLayout.horizontalPadding(forWidth: 393) == 12)
        #expect(MasonryLayout.horizontalPadding(forWidth: 700) == 24)
        #expect(MasonryLayout.horizontalPadding(forWidth: 1024) == 40)
    }

    @Test("单列时按顺序纵向堆叠")
    func singleColumnStacksSequentially() {
        let layout = MasonryLayout.layout(heights: Self.designHeights, metrics: .web(containerWidth: 393, columns: 1))
        for (index, placement) in layout.placements.enumerated() {
            #expect(placement.column == 0)
            #expect(placement.index == index)
        }
        for i in 1..<layout.placements.count {
            #expect(layout.placements[i].frame.minY > layout.placements[i - 1].frame.minY)
        }
    }
}

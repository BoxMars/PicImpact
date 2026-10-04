import CoreGraphics
import Foundation

/// 行优先瀑布流布局（复刻 Web 端的 CSS Grid 实现）。
///
/// ## 为什么不用"填最短列"的经典瀑布流
/// Web 端最初用 CSS 多列（`columns-3`），那是**列优先**的：先把第 1 列填满再填第 2 列，
/// 于是按时间排序的照片变成"一列读到底"，相邻照片在视觉上是上下关系而非左右关系。
/// 现在改为 CSS Grid（`grid-auto-flow: row` 默认行优先）+ 逐项按实测高度跨行。
/// **iOS 必须复刻同一套放置规则，否则同一个相册在两端的顺序会不一样。**
///
/// ## 规则（与 Web 端逐条对应）
/// - `rowUnit` = 8px（Web 的 `grid-auto-rows: 8px`）
/// - 每项占位 `span = ceil(内容高度 / rowUnit) + gapRows`，其中 `gapRows = ceil(rowGap / rowUnit)`
///   —— 间距不是靠 CSS row-gap，而是靠多占的行挤出来（所以 Web 端测量到 `rowGap: 0px`）
/// - 放置顺序：从游标位置起，按**行优先**扫描，找第一个能容纳 `span` 行的空位；
///   **游标只向前推进，绝不回头复用已扫过的空洞**（这正是行优先顺序得以保持的原因）
///
/// ## 已被真实浏览器验证
/// `Tests/PicImpactKitTests/Fixtures/masonry-browser-golden.json` 是 Chrome 实际渲染
/// 12 张卡后导出的坐标。`MasonryLayoutTests` 逐项比对 x/y —— 也就是说这个实现
/// 不是"看起来对"，而是与真实浏览器渲染结果一致。
///
/// ## 一个必须避开的坑（Web 端实测踩过）
/// 网格项若允许被容器拉伸（CSS 的 `align-items: stretch`），测得的高度会把
/// "为间距多留的行"也算进去，下一轮 span 再变大 → 正反馈，每轮长 `rowGap` 像素直至失控。
/// Web 端曾把 180px 的块撑到 3448px。**调用方传入的必须是内容高度，不能被容器拉伸。**
public struct MasonryLayout: Equatable {

    /// 布局参数
    public struct Metrics: Equatable, Sendable {
        public var containerWidth: CGFloat
        public var columns: Int
        public var columnGap: CGFloat
        /// 行高粒度。Web 端为 `grid-auto-rows: 8px`
        public var rowUnit: CGFloat
        /// 视觉行间距（通过多占行实现）
        public var rowGap: CGFloat

        public init(
            containerWidth: CGFloat,
            columns: Int,
            columnGap: CGFloat = 16,
            rowUnit: CGFloat = 8,
            rowGap: CGFloat = 16
        ) {
            self.containerWidth = containerWidth
            self.columns = max(1, columns)
            self.columnGap = columnGap
            self.rowUnit = max(1, rowUnit)
            self.rowGap = rowGap
        }

        /// Web 端实测值（见 golden fixture：columnGap 16px / gridAutoRows 8px / rowGap 0px）
        public static func web(containerWidth: CGFloat, columns: Int) -> Metrics {
            Metrics(containerWidth: containerWidth, columns: columns)
        }

        /// 列宽。与 CSS `grid-template-columns: repeat(n, 1fr)` 一致
        public var columnWidth: CGFloat {
            (containerWidth - columnGap * CGFloat(columns - 1)) / CGFloat(columns)
        }

        var gapRows: Int {
            max(1, Int((rowGap / rowUnit).rounded(.up)))
        }
    }

    /// 单个项的放置结果
    public struct Placement: Equatable, Sendable {
        public let index: Int
        /// 网格列序号（0 起）
        public let column: Int
        /// 网格行序号（0 起）
        public let row: Int
        /// 内容框：x/y 为左上角，height 是**内容高度**（不含底部间距）
        public let frame: CGRect
        /// 占位高度 = span * rowUnit（内容高度 + 底部间距）
        public let areaHeight: CGFloat
    }

    public let placements: [Placement]
    /// 容器内容总高度（最后一项的 y + 占位高度）
    public let contentHeight: CGFloat

    /// 计算布局。
    /// - Parameter heights: 每一项的**内容高度**（图片等比缩放后的高度 + 信息块高度），顺序即服务端返回顺序
    public static func layout(heights: [CGFloat], metrics: Metrics) -> MasonryLayout {
        guard !heights.isEmpty else {
            return MasonryLayout(placements: [], contentHeight: 0)
        }

        let columns = metrics.columns
        let columnWidth = metrics.columnWidth
        let rowUnit = metrics.rowUnit
        let gapRows = metrics.gapRows

        // 每列已占用的行区间（用区间而不是二维数组：项数多时内存与扫描都更省）
        var occupied: [[Range<Int>]] = Array(repeating: [], count: columns)

        func isFree(column: Int, rows: Range<Int>) -> Bool {
            !occupied[column].contains { $0.overlaps(rows) }
        }

        var placements: [Placement] = []
        placements.reserveCapacity(heights.count)

        // 游标：只向前推进，绝不回头 —— 这是与 CSS Grid `grid-auto-flow: row`（sparse）一致的关键
        var cursorRow = 0
        var cursorColumn = 0

        // 防御：正常不会触发，但避免任何输入导致死循环
        let maxRowBound = heights.reduce(0) { $0 + Int(($1 / rowUnit).rounded(.up)) + gapRows + 1 } + 1

        for (index, height) in heights.enumerated() {
            let contentHeight = max(0, height)
            let span = Int((contentHeight / rowUnit).rounded(.up)) + gapRows

            var placedRow = cursorRow
            var placedColumn = cursorColumn
            var found = false

            var row = cursorRow
            while row <= maxRowBound {
                let startColumn = (row == cursorRow) ? cursorColumn : 0
                var column = startColumn
                while column < columns {
                    if isFree(column: column, rows: row..<(row + span)) {
                        placedRow = row
                        placedColumn = column
                        found = true
                        break
                    }
                    column += 1
                }
                if found { break }
                row += 1
            }

            // 理论上到不了这里；真到了就顺延到末尾，宁可位置略偏也不要崩
            if !found {
                placedRow = (occupied.map { $0.last?.upperBound ?? 0 }.max() ?? 0)
                placedColumn = 0
            }

            occupied[placedColumn].append(placedRow..<(placedRow + span))
            occupied[placedColumn].sort { $0.lowerBound < $1.lowerBound }

            cursorRow = placedRow
            cursorColumn = placedColumn

            let x = CGFloat(placedColumn) * (columnWidth + metrics.columnGap)
            let y = CGFloat(placedRow) * rowUnit
            placements.append(
                Placement(
                    index: index,
                    column: placedColumn,
                    row: placedRow,
                    frame: CGRect(x: x, y: y, width: columnWidth, height: contentHeight),
                    areaHeight: CGFloat(span) * rowUnit
                )
            )
        }

        let contentHeight = placements.map { $0.frame.minY + $0.areaHeight }.max() ?? 0
        return MasonryLayout(placements: placements, contentHeight: contentHeight)
    }

    /// 按响应式断点选择列数。断点与 Web 端 Tailwind 的 `grid-cols-1 sm:grid-cols-2 lg:grid-cols-3` 对齐：
    /// `< 640 → 1 列`、`640 ~ 1024 → 2 列`、`>= 1024 → 3 列`。
    public static func columns(forWidth width: CGFloat) -> Int {
        if width >= 1024 { return 3 }
        if width >= 640 { return 2 }
        return 1
    }

    /// 首页网格容器的左右内边距。对应 Web 的 `px-3 sm:px-6 md:px-10`（12 / 24 / 40）。
    public static func horizontalPadding(forWidth width: CGFloat) -> CGFloat {
        if width >= 768 { return 40 }
        if width >= 640 { return 24 }
        return 12
    }

    /// 容器最大宽度（Web 端 `maxWidth: 1280`）
    public static let maxContainerWidth: CGFloat = 1280
}

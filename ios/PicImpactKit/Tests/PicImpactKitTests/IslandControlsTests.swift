import CoreGraphics
import SwiftUI
import Testing

@testable import PicImpactKit

/// 返回 / 分享胶囊的外观验证。
///
/// 存在的理由：这两个按钮的"纸色底 + 描边 + 硬阴影"最初是**手写**的，
/// 而 `.shadow` 被写在了 `.overlay { strokeBorder }` 之后 —— 正是 `IslandCard`
/// 上已经踩过一次的坑：描边内侧会挤进一条阴影色的线，看起来按钮有两条边框。
/// 实测剖面（顶边，2x）：`y20-22 #C4B89E` → `y23 纸色` → `y24-26 #BDAEA0` → `y27 纸色`。
///
/// 现在外观统一由 `View.islandPill()` 提供，顺序只写一遍。
@Suite("岛屿控件 · 返回/分享胶囊")
@MainActor
struct IslandControlsTests {

    typealias Pixels = IslandCardTests.Pixels

    static func sharePill() -> some View {
        IslandShareButton(url: URL(string: "https://felina.boxz.dev/preview/x")!, style: .pill)
            .padding(10)
            .background(Color.white)
    }

    static func backPill() -> some View {
        IslandBackButton {}
            .padding(10)
            .background(Color.white)
    }

    @Test("返回按钮顶边只有一条边框")
    func backPillHasSingleBorder() throws {
        try Self.assertSingleTopBorder(try #require(IslandCardTests.rasterize(Self.backPill(), scale: 2)), label: "返回")
    }

    @Test("分享按钮顶边只有一条边框")
    func sharePillHasSingleBorder() throws {
        try Self.assertSingleTopBorder(try #require(IslandCardTests.rasterize(Self.sharePill(), scale: 2)), label: "分享")
    }

    @Test("胶囊整体仍画出纸色底与描边（别把外观一起改没了）")
    func pillStillLooksLikePill() throws {
        let pixels = try #require(IslandCardTests.rasterize(Self.backPill(), scale: 2))
        var paper = 0
        var border = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                if pixels.matches(x, y, 0xF7F3DF, tolerance: 4) { paper += 1 }
                if pixels.matches(x, y, 0xC4B89E, tolerance: 4) { border += 1 }
            }
        }
        #expect(paper > 200, "胶囊应有纸色底")
        #expect(border > 50, "胶囊应有描边")
    }

    /// 从描边开始往下扫一段：不得出现阴影色。
    ///
    /// 关键点是**扫满一段窗口**而不是遇到内容就停 —— 那条阴影线恰恰紧跟在
    /// 描边内侧的一像素纸色之后（`y23 纸色` → `y24 阴影`），提前退出会漏掉。
    static func assertSingleTopBorder(_ pixels: Pixels, label: String) throws {
        let midX = pixels.width / 2
        var borderRow: Int?
        for y in 0..<min(40, pixels.height) where pixels.matches(midX, y, 0xC4B89E, tolerance: 6) {
            borderRow = y
            break
        }
        let start = try #require(borderRow, "\(label)：顶边没找到描边")

        var shadowRows: [Int] = []
        for y in start..<min(start + 12, pixels.height)
        where pixels.matches(midX, y, 0xBDAEA0, tolerance: 6) {
            shadowRows.append(y)
        }
        #expect(
            shadowRows.isEmpty,
            "\(label)：描边内侧出现了阴影色（行 \(shadowRows)）—— 按钮会看起来有两条边框"
        )
    }
}

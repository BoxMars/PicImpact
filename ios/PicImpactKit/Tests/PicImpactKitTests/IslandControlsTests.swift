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
/// 现在外观统一由 `View.islandSurface()` 提供，顺序只写一遍；
/// "描边内侧不得有阴影色"这条断言由 `IslandSurfaceTests` 对**所有**组件统一覆盖。
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

}

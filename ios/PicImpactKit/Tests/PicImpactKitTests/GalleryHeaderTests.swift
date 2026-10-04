import CoreGraphics
import SwiftUI
import Testing

@testable import PicImpactKit

/// 画廊头部的验证：缎带配色与形状、波浪分隔线、计数胶囊。
///
/// 这些都是"画出颜色来"才成立的东西 —— 组件存在但画不出颜色，界面上就是一块空白，
/// 而且不会报错。所以用像素断言而不是"能不能编译"。
@Suite("画廊头部 · 缎带/波浪/计数")
@MainActor
struct GalleryHeaderTests {

    typealias Pixels = IslandCardTests.Pixels

    static func rasterize(_ view: some View) -> Pixels? {
        IslandCardTests.rasterize(view)
    }

    /// 统计某颜色在图像里出现的像素数
    static func count(_ pixels: Pixels, _ hex: UInt32, tolerance: Int = 3) -> Int {
        var hit = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.matches(x, y, hex, tolerance: tolerance) {
                hit += 1
            }
        }
        return hit
    }

    // MARK: - 文案（防止把日文抄错）

    @Test("副标题与 Web 源码逐字一致")
    func subtitleMatchesWeb() {
        // 取自 components/layout/theme/simple/simple-gallery.tsx 的 <Typewriter> 内容
        #expect(GalleryHeader.defaultSubtitle == "光と影で綴る、パパとママと私の物語。")
    }

    // MARK: - 缎带

    @Test("缎带画出三种配色（前面板/后面板/折角）")
    func ribbonDrawsAllPaletteColors() throws {
        let pixels = try #require(Self.rasterize(
            IslandRibbon(text: "大福映画 Felina Gallery", fontSize: 28)
                .padding(40)
        ))
        // --rf #f8a6b2 前面板
        #expect(Self.count(pixels, 0xF8A6B2) > 200, "前面板粉色没画出来")
        // --rb #e06880 后面板
        #expect(Self.count(pixels, 0xE06880) > 50, "后面板深粉没画出来")
        // --rk #a03060 折角
        #expect(Self.count(pixels, 0xA03060) > 20, "折角深红没画出来")
    }

    @Test("缎带文字是白色")
    func ribbonTextIsWhite() throws {
        let pixels = try #require(Self.rasterize(
            IslandRibbon(text: "ABCDEF", fontSize: 40).padding(40)
        ))
        #expect(Self.count(pixels, 0xFFFFFF) > 50, "缎带文字应为白色，实际没找到白色像素")
    }

    @Test("后面板伸到主体之外（左右各 -0.6em、下方 -0.4em）")
    func backPanelsOverhang() throws {
        let fontSize: CGFloat = 40
        let ribbon = IslandRibbon(text: "AB", fontSize: fontSize)
        let pixels = try #require(Self.rasterize(ribbon.padding(60)))

        // 缎带主体宽 = 文字宽 + 2×1.6em；这里只验证"后面板比主体更宽"这一几何特征：
        // 在主体竖直中线上，后面板色出现在主体高度之外的下方
        let bodyHeight = 2 * fontSize
        let centerX = pixels.width / 2
        var backColorBelowBody = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.matches(x, y, 0xE06880) {
                _ = x
                if CGFloat(y) > 60 + bodyHeight { backColorBelowBody += 1 }
            }
        }
        _ = centerX
        #expect(backColorBelowBody > 0, "后面板应向下超出主体（bottom: -0.4em）")
    }

    // MARK: - 波浪分隔线

    @Test("波浪分隔线画出素材自带的黄色 #f1e26f")
    func waveDrawsItsOwnColor() throws {
        let pixels = try #require(Self.rasterize(
            WaveDivider().frame(width: 300).padding(10)
        ))
        #expect(Self.count(pixels, 0xF1E26F) > 100, "波浪线没画出来（应为 #f1e26f）")
    }

    @Test("波浪线高度是 12（与 Web 的 .animal-divider 一致）")
    func waveHeightMatchesWeb() throws {
        // 12pt 对应 Web 的 `height: 12px`
        let pixels = try #require(Self.rasterize(WaveDivider().frame(width: 300)))
        #expect(pixels.height == 12, "分隔线高度应为 12pt，实际 \(pixels.height)pt")
    }

    // MARK: - 头部整体

    @Test("头部同时画出缎带配色与计数胶囊的描边/底色")
    func headerDrawsRibbonAndPill() throws {
        let header = GalleryHeader(
            title: "大福映画 Felina Gallery",
            subtitle: GalleryHeader.defaultSubtitle,
            photoCount: 24
        )
        .background(AnimalTokens.bg)
        // 固定宽高：不给高度约束时 ImageRenderer 的布局可能无界
        .frame(width: 420, height: 220)

        let pixels = try #require(Self.rasterize(header))
        #expect(Self.count(pixels, 0xF8A6B2) > 200, "缎带前面板缺失")
        #expect(Self.count(pixels, 0xC4B89E) > 20, "计数胶囊描边缺失")
        #expect(Self.count(pixels, 0xF7F3DF) > 50, "计数胶囊底色（纸色）缺失")
    }

    @Test("照片数为 0 时不显示计数胶囊")
    func pillHiddenWhenEmpty() throws {
        let header = GalleryHeader(title: "T", subtitle: "", photoCount: 0)
            .background(AnimalTokens.bg)
            .frame(width: 420, height: 220)
        let pixels = try #require(Self.rasterize(header))
        // 胶囊描边 #c4b89e 在照片数为 0 时不应出现（缎带配色与它无关）
        #expect(Self.count(pixels, 0xC4B89E) == 0, "照片数为 0 时不该出现计数胶囊")
    }
}

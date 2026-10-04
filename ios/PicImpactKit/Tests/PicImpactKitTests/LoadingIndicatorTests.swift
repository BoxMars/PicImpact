import CoreGraphics
import SwiftUI
import Testing

@testable import PicImpactKit

/// 针对"同屏出现两个刷新图标"的回归测试。
///
/// 用户反馈过两次：下拉刷新时、以及首次加载在途时下拉刷新时，都能看到两个刷新。
/// 根因是**系统**的 `.refreshable` 指示器与 App 自己画的 spinner 会同时存在
/// （首次加载在途时 `refresh()` 因 `isLoading` 守卫立刻返回，`phase` 仍是
/// `.loadingFirstPage`，内联那个 spinner 也还亮着）。
///
/// 修法是从结构上消除可能性：**App 自己不再画任何 spinner**。
/// 于是"同屏两个刷新"不再依赖状态机的时序正确性。
@Suite("加载指示器 · 不得出现两个刷新")
@MainActor
struct LoadingIndicatorTests {

    typealias Pixels = IslandCardTests.Pixels

    static func distinctColors(_ pixels: Pixels) -> Int {
        var colors = Set<String>()
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let p = pixels.at(x, y)
                colors.insert("\(p.r),\(p.g),\(p.b)")
            }
        }
        return colors.count
    }

    static func count(_ pixels: Pixels, _ hex: UInt32, tolerance: Int = 6) -> Int {
        var hit = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.matches(x, y, hex, tolerance: tolerance) {
                hit += 1
            }
        }
        return hit
    }

    @Test("图片加载中是平色占位，不画 spinner")
    func imagePlaceholderIsFlat() throws {
        // 判据用"颜色种数"而不是某个具体颜色：spinner 的颜色取决于平台与 tint
        // （实测 macOS 下 ProgressView 渲染成 #FFCC00/#FF383C 共 21 种颜色），
        // 按颜色猜会随平台失效；而"平色"这个特征是稳定的。
        let pixels = try #require(IslandCardTests.rasterize(
            CachedAsyncImage(url: URL(string: "https://never.invalid/a.jpg"), loader: ImageLoader())
                .frame(width: 200, height: 150)
                .background(Color.white),
            scale: 2
        ))
        let colors = Self.distinctColors(pixels)
        #expect(
            colors <= 4,
            "加载中的占位应是平色（画了 spinner 的话颜色会明显变多），实际 \(colors) 种颜色"
        )
        // 平色应当是 bgSecondary，而不是空白/透明
        #expect(Self.count(pixels, 0xF0E8D8, tolerance: 4) > 1000, "占位应是 bgSecondary 平色块")
    }

    @Test("首次加载显示骨架卡（纸色/描边/硬阴影），不是 spinner")
    func firstLoadShowsSkeleton() throws {
        let pixels = try #require(IslandCardTests.rasterize(
            GallerySkeleton(width: 320).padding(16).background(AnimalTokens.bg),
            scale: 2
        ))
        // 骨架必须画出卡片的三种特征色；单纯的 spinner 一种都没有
        #expect(Self.count(pixels, 0xF7F3DF, tolerance: 4) > 1000, "骨架应有纸色块")
        #expect(Self.count(pixels, 0xC4B89E, tolerance: 4) > 100, "骨架应有卡片描边")
        #expect(Self.count(pixels, 0xBDAEA0, tolerance: 4) > 50, "骨架应有硬阴影")
    }
}

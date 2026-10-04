import CoreGraphics
import SwiftUI
import Testing

@testable import PicImpactKit

/// 岛屿外观的**全组件**回归测试：描边内侧不得挤进阴影色。
///
/// ## 为什么是一条数据驱动的测试，而不是每个组件各写一条
/// "纸色底 + 描边 + 硬阴影"这个模式原先在五个地方各写了一遍，
/// 其中三处把 `.shadow` 写在了 `.overlay { strokeBorder }` 之后，
/// 于是控件看起来有**两条边框**（用户为此反馈过三次，每次我只修了他看到的那一处）。
///
/// 现在实现统一到 `View.islandSurface()`，测试也统一：把所有用到它的组件列在一个表里
/// 逐个检查 —— 这样"漏测某个组件"不会重演。
///
/// 判定方式：从每个 x 往下找第一个描边像素，再看紧随其后的几行里有没有阴影色。
/// 顺序正确时那条阴影在控件**外侧**（下方），不会紧跟在描边后面。
@Suite("岛屿外观 · 描边与阴影顺序（全组件）")
@MainActor
struct IslandSurfaceTests {

    typealias Pixels = IslandCardTests.Pixels

    static func surfaces() -> [(String, AnyView)] {
        [
            ("IslandCard", AnyView(
                IslandCard { Color.clear.frame(width: 200, height: 120) }
                    .padding(16).background(Color.white)
            )),
            ("返回胶囊", AnyView(
                IslandBackButton {}.padding(16).background(Color.white)
            )),
            ("回到顶部胶囊", AnyView(
                IslandChevronButton(direction: .up, label: "顶部") {}
                    .padding(16).background(Color.white)
            )),
            ("分享胶囊", AnyView(
                IslandShareButton(url: URL(string: "https://felina.boxz.dev/preview/x")!, style: .pill)
                    .padding(16).background(Color.white)
            )),
            ("加载骨架", AnyView(
                GallerySkeleton(width: 200).padding(16).background(Color.white)
            )),
            ("头部计数胶囊", AnyView(
                GalleryHeader(title: "T", subtitle: "", photoCount: 24)
                    .padding(16).background(Color.white)
            )),
        ]
    }

    @Test("所有岛屿外观的顶边都只有一条边框")
    func allSurfacesHaveSingleTopBorder() throws {
        for (name, view) in Self.surfaces() {
            let pixels = try #require(IslandCardTests.rasterize(view, scale: 2), "\(name) 未产出图像")
            let badRows = Self.shadowRowsInsideStroke(pixels)
            #expect(
                badRows.isEmpty,
                "\(name)：描边内侧出现了阴影色（行 \(badRows)）—— 该控件会看起来有两条边框"
            )
        }
    }

    /// 返回"描边之后紧跟阴影色"的行号。空数组表示顺序正确。
    static func shadowRowsInsideStroke(_ pixels: Pixels) -> [Int] {
        var badRows: Set<Int> = []
        // 每 2px 采样一列即可（描边横贯整个控件宽度）
        for x in stride(from: 1, to: pixels.width, by: 2) {
            var strokeRow: Int?
            for y in 0..<pixels.height {
                if pixels.matches(x, y, 0xC4B89E, tolerance: 8) {
                    strokeRow = y
                    break
                }
            }
            guard let start = strokeRow else { continue }
            // 描边本身约 3px（1.5pt @2x）或 4px（2pt @2x），再看随后的 5 行
            for y in (start + 1)..<min(start + 8, pixels.height)
            where pixels.matches(x, y, 0xBDAEA0, tolerance: 8) {
                badRows.insert(y)
            }
        }
        return badRows.sorted()
    }
}

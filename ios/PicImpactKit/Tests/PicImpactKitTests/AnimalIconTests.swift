import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import PicImpactKit

/// 针对「卡片里的小图标不显示」这个问题的验证。
///
/// 图标最初放在 asset catalog 里，但 macOS 的 `swift build` 不跑 actool，
/// 资源不会编译成 `Assets.car`，`Image(name:)` 静默取不到东西 —— 界面上只是少一块，不报错。
/// 现在改为普通 SVG 资源 + 本包自己解析渲染，于是可以在 macOS 上**直接断言渲染结果**。
///
/// 这条测试链是：资源在不在 → 能不能解析成矢量 → **栅格化后有没有画出该有的颜色**。
/// 最后一环才是"图标真的会显示"的证据。
@Suite("ACNH 图标 · 资源、解析与渲染")
@MainActor
struct AnimalIconTests {

    typealias Pixels = IslandCardTests.Pixels

    // MARK: - 资源

    @Test("8 份 SVG 素材都在包资源里")
    func sourcesAreBundled() throws {
        for name in AnimalIconName.allCases {
            let url = try #require(
                Bundle.picImpactKit.url(forResource: "Icons/\(name.rawValue)", withExtension: "svg"),
                "找不到 \(name.rawValue).svg —— 卡片上会静默缺一块"
            )
            let svg = try String(contentsOf: url, encoding: .utf8)
            #expect(svg.contains("<svg"), "\(name.rawValue) 不是有效 SVG")
            #expect(svg.count > 200, "\(name.rawValue) 内容过短，可能是空文件")
        }
    }

    @Test("图标名与上游 animal-island-ui 的命名一致（改名会直接导致不显示）")
    func namesMatchUpstream() {
        #expect(AnimalIconName.camera.rawValue == "icon-camera")
        #expect(AnimalIconName.variant.rawValue == "icon-variant")
        #expect(AnimalIconName.miles.rawValue == "icon-miles")
        #expect(AnimalIconName.map.rawValue == "icon-map")
        #expect(AnimalIconName.critterpedia.rawValue == "icon-critterpedia")
        #expect(AnimalIconName.diy.rawValue == "icon-diy")
        #expect(AnimalIconName.helicopter.rawValue == "icon-helicopter")
        #expect(AnimalIconName.shopping.rawValue == "icon-shopping")
        #expect(AnimalIconName.allCases.count == 8)
    }

    @Test("尺寸常量与 Web 一致：芯片 14、操作行 18")
    func sizesMatchWeb() {
        #expect(AnimalIconSize.chip == 14)
        #expect(AnimalIconSize.action == 18)
    }

    // MARK: - 解析

    @Test("8 个图标都能解析出有效 viewBox 与若干矢量形状")
    func parsingProducesShapes() throws {
        for name in AnimalIconName.allCases {
            let icon = try #require(
                AnimalIconCache.shared.icon(named: name.rawValue),
                "\(name.rawValue) 解析失败"
            )
            #expect(icon.viewBox.width > 0 && icon.viewBox.height > 0, "\(name.rawValue) viewBox 异常")
            #expect(icon.shapes.count >= 2, "\(name.rawValue) 只解析出 \(icon.shapes.count) 个形状，疑似丢了路径")
        }
    }

    @Test("含 fill-rule=\"evenodd\" 的形状被正确标记（否则图标镂空会被实心填掉）")
    func evenOddIsPreserved() throws {
        let icon = try #require(AnimalIconCache.shared.icon(named: AnimalIconName.shopping.rawValue))
        #expect(icon.shapes.contains { $0.evenOdd }, "应至少有一个 evenodd 形状")
    }

    @Test("矢量路径解析覆盖 M/L/H/V/C/Z")
    func pathParsingCoversUsedCommands() {
        let path = SVGIcon.path(from: "M0 0 L10 0 H20 V10 C22 12 24 14 26 16 Z")
        let bounds = path.boundingRect
        #expect(bounds.width > 20, "路径宽度异常：\(bounds)")
        #expect(bounds.height > 10, "路径高度异常：\(bounds)")
    }

    @Test("相对命令（小写）与绝对命令等价")
    func relativeCommandsMatchAbsolute() {
        let absolute = SVGIcon.path(from: "M10 10 L20 10 L20 20 Z").boundingRect
        let relative = SVGIcon.path(from: "m10 10 l10 0 l0 10 z").boundingRect
        #expect(abs(absolute.minX - relative.minX) < 0.001)
        #expect(abs(absolute.width - relative.width) < 0.001)
        #expect(abs(absolute.height - relative.height) < 0.001)
    }

    // MARK: - 渲染（这才是"图标会不会显示"的证据）

    /// 注意**不加 padding**：加了之后 16pt 与 64pt 的画布里留白占比不同
    /// （24×24 vs 72×72），覆盖率就不可比了 —— 测试度量本身会失真。
    static func rasterize(_ icon: AnimalIconName, size: CGFloat = 64) -> Pixels? {
        IslandCardTests.rasterize(AnimalIcon(icon, size: size))
    }

    @Test("每个图标栅格化后都画出了不透明像素（不是空视图）")
    func iconsActuallyDraw() throws {
        for name in AnimalIconName.allCases {
            let pixels = try #require(Self.rasterize(name), "\(name.rawValue) 未产出图像")
            var opaque = 0
            for y in 0..<pixels.height {
                for x in 0..<pixels.width where pixels.at(x, y).a > 200 {
                    opaque += 1
                }
            }
            #expect(opaque > 200, "\(name.rawValue) 只画出 \(opaque) 个不透明像素，疑似空视图")
        }
    }

    @Test("图标是彩色的（多种颜色），不是单色剪影")
    func iconsAreMulticolored() throws {
        for name in AnimalIconName.allCases {
            let pixels = try #require(Self.rasterize(name))
            var colors = Set<String>()
            for y in 0..<pixels.height {
                for x in 0..<pixels.width where pixels.at(x, y).a > 200 {
                    let p = pixels.at(x, y)
                    colors.insert("\(p.r),\(p.g),\(p.b)")
                }
            }
            #expect(colors.count >= 3, "\(name.rawValue) 只有 \(colors.count) 种颜色，可能被当成单色模板了")
        }
    }

    @Test("渲染结果含有各自的品牌色（逐个图标的指纹）")
    func iconsShowSignatureColors() throws {
        // 这些 hex 取自 dist/files/*.svg 的原始 fill，是"画对了"的指纹
        let expectations: [(AnimalIconName, UInt32)] = [
            (.camera, 0xFF66AD),
            (.camera, 0x9364DE),
            (.shopping, 0x409B5E),
            (.diy, 0xFAD12B),
            (.helicopter, 0xFFAD00),
            (.critterpedia, 0x34ADB6),
            (.miles, 0x5ABF98),
            (.variant, 0x5AA15B),
        ]
        for (name, hex) in expectations {
            let pixels = try #require(Self.rasterize(name, size: 96))
            var hit = 0
            for y in 0..<pixels.height {
                for x in 0..<pixels.width where pixels.matches(x, y, hex, tolerance: 3) {
                    hit += 1
                }
            }
            #expect(
                hit > 0,
                "\(name.rawValue) 渲染结果里找不到特征色 \(String(format: "#%06X", hex)) —— 说明该图标没画出来"
            )
        }
    }

    @Test("缩放正确：16pt 与 64pt 的不透明像素占比接近（矢量而非位图拉伸）")
    func scalesAsVector() throws {
        let small = try #require(Self.rasterize(.camera, size: 16))
        let large = try #require(Self.rasterize(.camera, size: 64))

        func coverage(_ pixels: Pixels) -> Double {
            var opaque = 0
            for y in 0..<pixels.height {
                for x in 0..<pixels.width where pixels.at(x, y).a > 200 { opaque += 1 }
            }
            return Double(opaque) / Double(pixels.width * pixels.height)
        }

        let smallCoverage = coverage(small)
        let largeCoverage = coverage(large)
        #expect(smallCoverage > 0.05, "16pt 下几乎没画出内容：\(smallCoverage)")
        #expect(
            abs(smallCoverage - largeCoverage) < 0.15,
            "16pt 覆盖 \(smallCoverage) 与 64pt 覆盖 \(largeCoverage) 差异过大"
        )
    }
}

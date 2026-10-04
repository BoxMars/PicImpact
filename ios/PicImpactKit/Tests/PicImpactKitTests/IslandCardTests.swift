import CoreGraphics
import SwiftUI
import Testing

@testable import PicImpactKit

/// T3 验证：岛屿纸卡的视觉签名。
///
/// 做法是**栅格化后采样像素**，把"看起来对不对"变成可判定断言。
/// 为了能精确判定，测试会通过 `IslandCard` 可注入的参数**逐个隔离视觉成分**
/// （验硬阴影时关掉柔阴影，反之亦然），否则两层阴影叠在一起只能给出模糊区间。
///
/// 两点实现约定：
/// 1. 像素值允许 ±3 容差（色彩管理/合成会有微小偏移）；**令牌定义本身**的精确相等由 T2 保证。
/// 2. 断言一律先把比较结果算成 `Bool` 再交给 `#expect` —— 否则 swift-testing 会把整个
///    像素缓冲当作表达式参数捕获并打印出来（几万行输出），反而看不清失败原因。
@Suite("T3 · 岛屿纸卡视觉签名")
@MainActor
struct IslandCardTests {

    // MARK: - 渲染工具

    struct Pixels {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0, 0) }
            let offset = (y * width + x) * 4
            return (Int(rgba[offset]), Int(rgba[offset + 1]), Int(rgba[offset + 2]), Int(rgba[offset + 3]))
        }

        func matches(_ x: Int, _ y: Int, _ hex: UInt32, tolerance: Int = 3) -> Bool {
            let pixel = at(x, y)
            return abs(pixel.r - Int((hex >> 16) & 0xFF)) <= tolerance
                && abs(pixel.g - Int((hex >> 8) & 0xFF)) <= tolerance
                && abs(pixel.b - Int(hex & 0xFF)) <= tolerance
        }

        func describe(_ x: Int, _ y: Int) -> String {
            let p = at(x, y)
            return String(format: "#%02X%02X%02X a=%d", p.r, p.g, p.b, p.a)
        }
    }

    static func rasterize(_ view: some View, scale: CGFloat = 1) -> Pixels? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = false
        guard let cgImage = renderer.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let rendered: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        return Pixels(width: width, height: height, rgba: buffer)
    }

    /// 卡片内容尺寸与画布内边距（固定几何，便于像素定位）
    static let cardWidth: CGFloat = 200
    static let cardHeight: CGFloat = 100
    static let pad: CGFloat = 30

    /// 卡片在画布中的像素范围：
    ///   x: pad ..< pad + cardWidth
    ///   y: pad ..< pad + cardHeight   （最后一行是 pad + cardHeight - 1）
    static var cardTop: Int { Int(pad) }
    static var cardBottomExclusive: Int { Int(pad + cardHeight) }
    static var cardMidX: Int { Int(pad + cardWidth / 2) }

    static func card(hardShadow: Bool = true, softShadow: Bool = true) -> some View {
        IslandCard(
            hardShadowColor: hardShadow ? AnimalSignatures.cardShadowHard : .clear,
            softShadowColor: softShadow ? AnimalSignatures.cardShadowSoft : .clear
        ) {
            Color.clear.frame(width: cardWidth, height: cardHeight)
        }
        .padding(pad)
    }

    /// 采样并断言（只把 Bool 交给 #expect，避免打印整块像素缓冲）
    static func expectPixel(
        _ pixels: Pixels,
        _ x: Int,
        _ y: Int,
        _ hex: UInt32,
        tolerance: Int = 3,
        _ label: String
    ) {
        let ok = pixels.matches(x, y, hex, tolerance: tolerance)
        #expect(ok, "\(label)：期望 \(String(format: "#%06X", hex))，实际 \(pixels.describe(x, y))")
    }

    // MARK: - 断言

    @Test("纸面色：卡片内部就是 CardColor.default 的 rgb(247,243,223)")
    func fillIsPaperColor() throws {
        let pixels = try #require(Self.rasterize(Self.card()), "ImageRenderer 未产出图像")
        Self.expectPixel(pixels, Self.cardMidX, Self.cardTop + 20, 0xF7F3DF, "卡片内部填充")
    }

    @Test("描边：上下边缘是 2px 的 #C4B89E（全库最高频的颜色）")
    func borderIsPaperBorderColor() throws {
        let pixels = try #require(Self.rasterize(Self.card()))
        // 上边缘：卡片从 cardTop 开始，2px 描边的第一行
        Self.expectPixel(pixels, Self.cardMidX, Self.cardTop + 1, 0xC4B89E, "上边缘描边")
        // 下边缘：卡片最后两行
        Self.expectPixel(pixels, Self.cardMidX, Self.cardBottomExclusive - 2, 0xC4B89E, "下边缘描边")
    }

    @Test("硬阴影：紧贴卡片下方 3px 是实心的 #BDAEA0（“贴纸厚度”）")
    func hardShadowIsSolidOffset() throws {
        // 关掉柔阴影，只留硬阴影 —— 否则两层叠加只能给出模糊区间
        let pixels = try #require(Self.rasterize(Self.card(softShadow: false)))

        // 卡片自身占据 [cardTop, cardBottomExclusive)，硬阴影整体下移 3px，
        // 因此它露出的部分正好是接下来 3 行
        for offset in 0..<3 {
            let y = Self.cardBottomExclusive + offset
            Self.expectPixel(pixels, Self.cardMidX, y, 0xBDAEA0, "硬阴影第 \(offset + 1) 行")
        }
        // 再往下应当干净（画布底色透明）
        let beyond = Self.cardBottomExclusive + 4
        let clearAlpha = pixels.at(Self.cardMidX, beyond).a
        #expect(clearAlpha == 0, "硬阴影不应超出 3px 偏移范围，实际 \(pixels.describe(Self.cardMidX, beyond))")
    }

    @Test("柔阴影：半透明且随距离衰减（不是实心块）")
    func softShadowIsTranslucentAndFades() throws {
        let pixels = try #require(Self.rasterize(Self.card(hardShadow: false)))

        let alphaNear = pixels.at(Self.cardMidX, Self.cardBottomExclusive + 2).a
        let alphaFar = pixels.at(Self.cardMidX, Self.cardBottomExclusive + 12).a

        #expect(alphaNear > 0, "柔阴影应可见，实际 a=\(alphaNear)")
        #expect(alphaFar < alphaNear, "柔阴影应随距离衰减：近处 a=\(alphaNear)，远处 a=\(alphaFar)")
        #expect(alphaNear < 255, "柔阴影不应完全不透明，实际 a=\(alphaNear)")
    }

    @Test("圆角：拐角被裁掉，且与直角形成可对照的差异")
    func cornerIsCircularAndClipped() throws {
        // 用**差分**断言，而不是给一个宽松阈值：
        // 同一位置，圆角卡应是近乎透明（抗锯齿后仅剩极少覆盖），直角卡应是不透明描边色。
        let rounded = try #require(Self.rasterize(Self.card()))
        let square = try #require(Self.rasterize(
            IslandCard(cornerRadius: 0) {
                Color.clear.frame(width: Self.cardWidth, height: Self.cardHeight)
            }
            .padding(Self.pad)
        ))

        let roundedCorner = rounded.at(Self.cardTop, Self.cardTop)
        let squareCorner = square.at(Self.cardTop, Self.cardTop)

        #expect(
            roundedCorner.a < 40,
            "圆角卡的顶点应几乎透明（抗锯齿残留），实际 \(rounded.describe(Self.cardTop, Self.cardTop))"
        )
        #expect(
            squareCorner.a > 200,
            "直角卡的顶点应不透明，实际 \(square.describe(Self.cardTop, Self.cardTop))"
        )
        let squareCornerIsBorder = square.matches(Self.cardTop, Self.cardTop, 0xC4B89E)
        #expect(squareCornerIsBorder, "直角卡顶点应为描边色，实际 \(square.describe(Self.cardTop, Self.cardTop))")

        // 圆角内 6px 已经进入卡片
        let insideAlpha = rounded.at(Self.cardTop + 6, Self.cardTop + 6).a
        #expect(insideAlpha > 0, "圆角内 6px 应已有内容，实际 \(rounded.describe(Self.cardTop + 6, Self.cardTop + 6))")
    }

    @Test("顶边只有一条边框：描边与内容之间不得夹入阴影色（回归）")
    func topEdgeHasSingleBorder() throws {
        // 这条是回归测试。曾经的写法是 `.overlay { strokeBorder }` 在前、`.shadow` 在后，
        // 结果阴影作用的对象变成"含描边的合成视图"，其顶边落在卡片内部，
        // 于是在描边内侧挤出一条 `#BDAEA0` —— 看起来卡片顶上就有两条边框。
        // 实测剖面（错误顺序）：y30:#C4B89E  y32:内容  y33:#BDAEA0  y35:内容
        //
        // ⚠️ 判定必须扫满一个**窗口**，不能在遇到第一个内容像素时就 break ——
        // 那条阴影色恰好出现在内容**之后**一行，提前退出会漏掉它（第一版就是这么漏的）。
        let content = VStack(spacing: 0) {
            Color.blue.frame(width: Self.cardWidth, height: Self.cardHeight)
        }
        let pixels = try #require(
            Self.rasterize(IslandCard { content }.padding(Self.pad)),
            "ImageRenderer 未产出图像"
        )

        func isBorder(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
            abs(p.r - 0xC4) <= 8 && abs(p.g - 0xB8) <= 8 && abs(p.b - 0x9E) <= 8
        }
        func isShadow(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
            abs(p.r - 0xBD) <= 8 && abs(p.g - 0xAE) <= 8 && abs(p.b - 0xA0) <= 8
        }

        var borderRows = 0
        var shadowRows: [Int] = []
        var contentRows = 0
        // 顶边往下 15px（5pt）：足以覆盖 2pt 描边 + 阴影偏移 3pt
        for y in Self.cardTop..<(Self.cardTop + 15) {
            let p = pixels.at(Self.cardMidX, y)
            if isBorder(p) { borderRows += 1; continue }
            if isShadow(p) { shadowRows.append(y); continue }
            if p.b > 200, p.r < 100 { contentRows += 1 }
        }

        // 注意 scale：ImageRenderer 默认 scale = 1，所以 2pt 描边在这里只有 2px
        // （截图里是 3x = 6px）。按 6 去卡会误判。
        #expect(borderRows >= 2, "顶边描边应约 2pt，实际 \(borderRows) px")
        #expect(contentRows > 0, "描边之后应能看到内容")
        #expect(
            shadowRows.isEmpty,
            "描边与内容之间出现了阴影色（行 \(shadowRows)）—— 卡片顶边会看起来有两条边框"
        )
    }

    @Test("几何：渲染宽度等于卡片宽度加内边距（描边含在内，对应 CSS border-box）")
    func renderedSizeMatchesBorderBox() throws {
        let pixels = try #require(Self.rasterize(Self.card()))
        let expectedWidth = Int(Self.cardWidth + Self.pad * 2)
        #expect(pixels.width == expectedWidth, "渲染宽度应为 \(expectedWidth)，实际 \(pixels.width)")
        #expect(pixels.height >= Int(Self.cardHeight + Self.pad), "渲染高度应至少容纳卡片，实际 \(pixels.height)")
    }
}

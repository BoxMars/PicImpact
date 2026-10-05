import CoreGraphics
import SwiftUI
import Testing

@testable import PicImpactKit

/// 详情页信息区的渲染验证。
///
/// 为什么用像素断言：分区标题、参数胶囊、设备行图标都是"画出来才存在"的东西，
/// 结构与文案由 `PreviewModelTests` 覆盖，这里专门确认**真的渲染出了颜色与图标**。
/// （模拟器没有"点击"命令，无法自动进详情页截图，所以在这一层做端到端验证。）
@Suite("详情页信息区 · 分区与图标渲染")
@MainActor
struct PreviewInfoSectionsTests {

    typealias Pixels = IslandCardTests.Pixels

    static func count(_ pixels: Pixels, _ hex: UInt32, tolerance: Int = 3) -> Int {
        var hit = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.matches(x, y, hex, tolerance: tolerance) {
                hit += 1
            }
        }
        return hit
    }

    /// 与生产数据同形状的一份信息数据
    static func makeData() -> PreviewInfoData {
        var data = PreviewInfoData()
        data.basicInfo = [
            .init(id: "dimensions", label: "尺寸", value: "4032 × 3024"),
            .init(id: "pixels", label: "像素", value: "12.2 MP"),
            .init(id: "data_time", label: "拍摄时间", value: "2026-10-02 20:15:12"),
        ]
        data.captureParams = [
            .init(id: "focal_length", label: "焦距", value: "5.96 mm"),
            .init(id: "f_number", label: "光圈", value: "f/1.6"),
            .init(id: "exposure_time", label: "曝光时间", value: "1/13"),
            .init(id: "iso", label: "感光度", value: "ISO 640"),
        ]
        data.device = [
            .init(id: "camera", label: "相机", value: "Apple iPhone 17"),
            .init(id: "lens", label: "镜头", value: "iPhone 17 back dual wide camera 5.96mm f/1.6"),
            .init(id: "focal_length", label: "焦距", value: "5.96 mm"),
        ]
        data.captureMode = [
            .init(id: "exposure_program", label: "曝光程序", value: "Normal program"),
            .init(id: "exposure_mode", label: "曝光模式", value: "Auto exposure"),
            .init(id: "white_balance", label: "白平衡", value: "Auto white balance"),
        ]
        data.technical = [.init(id: "bits", label: "位深度", value: "8")]
        return data
    }

    static func rasterize(_ view: some View) -> Pixels? {
        IslandCardTests.rasterize(view)
    }

    /// 按**真实设备的分辨率**（3x）渲染。
    ///
    /// 这些图标只有 14pt；在 scale=1 下就是 14×14 像素，
    /// 抗锯齿会把特征色全部混掉，导致"图标明明画了却测不到"。
    /// 真机是 3x，所以这里也用 3x —— 测的才是真实观感。
    static func rasterizeAtDeviceScale(_ view: some View) -> Pixels? {
        IslandCardTests.rasterize(view, scale: 3)
    }

    @Test("分区标题是青色 #19c8b9")
    func sectionTitlesAreTeal() throws {
        let pixels = try #require(Self.rasterize(
            PreviewInfoSections(data: Self.makeData())
                .background(AnimalSignatures.cardPaper)
                .frame(width: 340, height: 520)
        ))
        #expect(Self.count(pixels, 0x19C8B9) > 20, "分区标题的青色没画出来")
    }

    @Test("拍摄参数不带图标，与其他分区一样是标签—值行（按用户要求，回归）")
    func captureParamsHaveNoIcons() throws {
        // 这里曾经是四个带图标的两列胶囊（icon-map/variant/miles/critterpedia）。
        // 按用户要求改成与其他分区一致的标签—值行，图标全部移除。
        let pixels = try #require(Self.rasterizeAtDeviceScale(
            PreviewInfoSections(data: Self.makeData())
                .background(AnimalSignatures.cardPaper)
                .frame(width: 340, height: 560)
        ))
        let forbidden: [(String, UInt32)] = [
            ("icon-map", 0x59C9C0),
            ("icon-variant", 0x5AA15B),
            ("icon-miles", 0x5ABF98),
            ("icon-critterpedia", 0x34ADB6),
            ("icon-camera", 0xFF66AD),
            ("icon-design", 0xFFCF4F),
        ]
        for (name, hex) in forbidden {
            #expect(
                Self.count(pixels, hex, tolerance: 4) == 0,
                "\(name) 的特征色仍在，说明该分区还在画图标"
            )
        }
        // 但内容（标签与数值）必须还在：用正文色判断
        #expect(Self.count(pixels, 0x725D42, tolerance: 6) > 0, "标签—值行的文字应仍在")
    }

    @Test("设备信息不显示图标（按用户要求，回归）")
    func deviceIconsAreAbsent() throws {
        // 曾经在设备信息行前面放 icon-camera / icon-design。
        // 按用户要求改为只显示文字，这里守住"图标不再出现"。
        let pixels = try #require(Self.rasterizeAtDeviceScale(
            PreviewInfoSections(data: Self.makeData())
                .background(AnimalSignatures.cardPaper)
                .frame(width: 340, height: 520)
        ))
        #expect(Self.count(pixels, 0xFF66AD, tolerance: 4) == 0, "设备信息不该再出现 icon-camera")
        #expect(Self.count(pixels, 0xFFCF4F, tolerance: 4) == 0, "设备信息不该再出现 icon-design")
        // 注：早先这里还有一条"拍摄参数的 icon-map 仍应存在"。
        // 后来按用户要求参数分区也去掉了图标，那条断言随之作废 ——
        // 现在整个信息区都不该有图标，由 captureParamsHaveNoIcons 统一覆盖。
    }

    @Test("分区之间是青色虚线（有实有虚，不是实线）")
    func dashedDividerIsDashed() throws {
        // 宽 120、虚线 6/6，取中间一行统计青色与空白的交替次数
        let pixels = try #require(Self.rasterize(
            IslandDashedDivider().frame(width: 120).padding(4).background(Color.white)
        ))
        let y = pixels.height / 2
        var runs = 0
        var lastWasTeal = false
        for x in 0..<pixels.width {
            let isTeal = pixels.matches(x, y, 0x19C8B9, tolerance: 20)
            if isTeal != lastWasTeal { runs += 1; lastWasTeal = isTeal }
        }
        #expect(runs >= 6, "虚线应多次交替，实际交替 \(runs) 次 —— 可能是实线")
    }

    @Test("空数据时不渲染任何内容")
    func emptyDataRendersNothing() throws {
        let pixels = try #require(Self.rasterize(
            PreviewInfoSections(data: PreviewInfoData())
                .background(AnimalSignatures.cardPaper)
                .frame(width: 340, height: 200)
        ))
        // 整块应只有纸色，没有任何青色标题或描边
        #expect(Self.count(pixels, 0x19C8B9) == 0, "空数据不该有分区标题")
        #expect(Self.count(pixels, 0xC4B89E) == 0, "空数据不该有胶囊描边")
    }

    @Test("详情页滚动区真的把分区接上了（渲染冒烟）")
    func previewInfoPanelWiresSections() throws {
        let json = """
        {"id":"p1","imageName":"IMG_1.jpeg","url":"https://x/o.jpg","previewUrl":"https://x/p.webp",
         "videoUrl":"","blurhash":"","width":4032,"height":3024,"title":"标题","detail":"描述",
         "type":1,"labels":[],"lon":"","lat":"",
         "exif":{"make":"Apple","model":"iPhone 17","lens_model":"back camera","focal_length":"5.96 mm",
                 "f_number":"f/1.6","exposure_time":"1/13","exposure_program":"Normal program",
                 "exposure_mode":"Auto exposure","white_balance":"Auto white balance",
                 "iso_speed_rating":640,"data_time":"2026:10:02 20:15:12","bits":"8"},
         "albumLicense":null,"createdAt":null}
        """
        let image = try APIDecoding.makeDecoder().decode(ImageDTO.self, from: Data(json.utf8))
        let model = PreviewModel(image: image, loader: ImageLoader())

        // 渲染滚动区内容而不是 PreviewView：ImageRenderer 不渲染 ScrollView 的内容。
        // 2x 是因为整块在 3x 下会超过栅格化尺寸守卫。
        let pixels = try #require(IslandCardTests.rasterize(
            PreviewInfoPanel(model: model, features: .none, onSelectTag: { _ in })
                .frame(width: 393, height: 1200),
            scale: 2
        ))
        // 青色分区标题、纸色面板、以及参数图标都应出现在详情页里
        #expect(Self.count(pixels, 0x19C8B9) > 0, "详情页应出现青色分区标题（说明分区接上了）")
        #expect(Self.count(pixels, 0xF7F3DF) > 1000, "详情页应出现纸色信息面板")
        #expect(Self.count(pixels, 0x59C9C0, tolerance: 6) > 0, "详情页应出现参数图标（icon-map）")
    }

    @Test("详情页标题与卡片内文字左对齐")
    func titleAlignsWithCardContent() throws {
        let json = """
        {"id":"p1","imageName":"IMG_1.jpeg","url":"https://x/o.jpg","previewUrl":"https://x/p.webp",
         "videoUrl":"","blurhash":"","width":4032,"height":3024,"title":"标题","detail":"",
         "type":1,"labels":[],"lon":"","lat":"",
         "exif":{"make":"Apple","model":"iPhone 17","lens_model":"back camera","focal_length":"5.96 mm",
                 "f_number":"f/1.6","exposure_time":"1/13","exposure_program":"Normal program",
                 "iso_speed_rating":640,"data_time":"2026:10:02 20:15:12","bits":"8"},
         "albumLicense":null,"createdAt":null}
        """
        let image = try APIDecoding.makeDecoder().decode(ImageDTO.self, from: Data(json.utf8))
        let model = PreviewModel(image: image, loader: ImageLoader())
        let pixels = try #require(IslandCardTests.rasterize(
            VStack(spacing: 0) {
                PreviewPinnedHeader(model: model, expansion: 1)
                PreviewInfoPanel(model: model, features: .none, onSelectTag: { _ in })
            }
                .frame(width: 393, height: 1200),
            scale: 2
        ))

        // 标题下方那条青色短横与卡片内的分区标题（同为 #19c8b9）应在同一条竖线上。
        // 短横在卡片之前出现，取它作为"卡片外内容的起始 x"。
        func tealMinX(from y0: Int, to y1: Int) -> Int? {
            for x in 0..<pixels.width {
                for y in y0..<min(y1, pixels.height) where pixels.matches(x, y, 0x19C8B9, tolerance: 10) {
                    return x
                }
            }
            return nil
        }

        // 找到第一处青色（标题短横）
        var accentMinX: Int?
        var accentY = 0
        outer: for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.matches(x, y, 0x19C8B9, tolerance: 10) {
                accentMinX = x; accentY = y; break outer
            }
        }
        let accent = try #require(accentMinX, "没找到标题的青色短横")
        // 卡片内的第一个青色标题（短横之后）
        let section = try #require(tealMinX(from: accentY + 6, to: pixels.height), "没找到卡片内的青色分区标题")

        #expect(
            abs(accent - section) <= 4,
            "标题(短横 x=\(accent))与卡片内文字(x=\(section))没有左对齐 —— 相差 \(abs(accent - section))px"
        )
    }

    @Test("详情页里的直方图没有边框（在真实组合上检查，回归）")
    func histogramHasNoBorderInDetailPage() throws {
        // 为什么在 PreviewInfoPanel（详情页滚动区的真实组合）上测，而不是只测 HistogramPanel：
        // 边框可以在**调用点**加（我第一版就是这么加的），只测组件会漏掉。
        // 这段测的是真实组合。
        let json = """
        {"id":"p1","imageName":"IMG_1.jpeg","url":"https://x/o.jpg","previewUrl":"https://x/p.webp",
         "videoUrl":"","blurhash":"","width":4032,"height":3024,"title":"标题","detail":"",
         "type":1,"labels":[],"lon":"","lat":"",
         "exif":{"make":"Apple","model":"iPhone 17","lens_model":"back camera","focal_length":"5.96 mm",
                 "f_number":"f/1.6","exposure_time":"1/13","exposure_program":"Normal program",
                 "iso_speed_rating":640,"data_time":"2026:10:02 20:15:12","bits":"8"},
         "albumLicense":null,"createdAt":null}
        """
        let image = try APIDecoding.makeDecoder().decode(ImageDTO.self, from: Data(json.utf8))
        let model = PreviewModel(image: image, loader: ImageLoader())

        // 先让直方图有数据可画，否则整块不会渲染
        let bins = (0..<Histogram.binCount).map { _ in 1 }
        let histogram = Histogram(red: bins, green: bins, blue: bins, luminance: bins)
        model.histogram = histogram

        let pixels = try #require(IslandCardTests.rasterize(
            PreviewInfoPanel(model: model, features: .none, onSelectTag: { _ in })
                .frame(width: 393, height: 1400),
            scale: 2
        ))

        // 定位直方图：直方图是**最后一个分区**，所以取最后一处青色分区标题
        // （"直方图"三个字，#19c8b9）作为锚点。
        //
        // 为什么不用直方图自身的深色底定位：柱体会把底色盖住 ——
        // 实测若把所有箱设成相同值，每根柱都是满高，底色只剩边缘几十个像素，
        // 按底色找会完全找不到（第一版就是这么失败的）。
        var lastTealRow = -1
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.matches(x, y, 0x19C8B9, tolerance: 10) {
                lastTealRow = y
                break
            }
        }
        let anchor = try #require(lastTealRow > 0 ? lastTealRow : nil, "没找到分区标题")

        // 面板高度 120pt、上下各 8pt 内边距，2x 下约 272px；
        // 再往下就是卡片自己的 16pt 底部内边距与外框（约 +292），故取到 +275 为止。
        let y0 = anchor + 20
        let y1 = min(pixels.height - 1, anchor + 275)

        // 面板范围里不该出现描边。
        //
        // ⚠️ 必须同时查两种颜色：描边常常带透明度。实测我原来那层用
        // `cardBorder.opacity(0.5)` 画，渲染出来是 **#DAD0BB**（与 #c4b89e 相差很远），
        // 只按 #c4b89e 精确比色**抓不到它** —— 我第一版测试就是这样漏掉的。
        // 所以实心与半透明混合两种都查。
        let inset = 80
        var border = 0
        for y in y0...y1 {
            for x in inset..<(pixels.width - inset) {
                if pixels.matches(x, y, 0xC4B89E, tolerance: 4)
                    || pixels.matches(x, y, 0xDAD0BB, tolerance: 4) {
                    border += 1
                }
            }
        }

        #expect(
            border == 0,
            "详情页的直方图不该有边框，实测在 y=\(y0)...\(y1) 命中 \(border) px 的 #c4b89e"
        )
    }

    @Test("详情页顶栏有 ACNH 的返回与分享（且在最上方）")
    func topBarHasBackAndShare() throws {
        let json = """
        {"id":"p1","imageName":"IMG_1.jpeg","url":"https://x/o.jpg","previewUrl":"https://x/p.webp",
         "videoUrl":"","blurhash":"","width":4032,"height":3024,"title":"标题","detail":"",
         "type":1,"labels":[],"lon":"","lat":"",
         "exif":{"make":"Apple","model":"iPhone 17","lens_model":"back camera","focal_length":"5.96 mm",
                 "f_number":"f/1.6","exposure_time":"1/13","exposure_program":"Normal program",
                 "iso_speed_rating":640,"data_time":"2026:10:02 20:15:12","bits":"8"},
         "albumLicense":null,"createdAt":null}
        """
        let image = try APIDecoding.makeDecoder().decode(ImageDTO.self, from: Data(json.utf8))
        let model = PreviewModel(image: image, loader: ImageLoader())
        // 渲染真正的顶栏视图。注意不要给它固定高度：里面有 maxWidth: .infinity +
        // 居中对齐，给了固定高度内容会被**垂直居中**，顶栏就跑到画面中间去
        // （第一版正是这样，导致"分享按钮不在上部"的假失败）。
        let pixels = try #require(IslandCardTests.rasterize(
            PreviewTopBar(image: image, onBack: {})
                .padding(12)
                .frame(width: 393),
            scale: 2
        ))

        // 顶栏的布局要求：返回在左、分享在右。
        //
        // ⚠️ 不能用描边色 #c4b89e 定位返回按钮：两个胶囊的描边**同色**，
        // 它的包围盒会把分享按钮一起框进来（第一版就是这么假失败的）。
        // 只有分享图标（icon-helicopter #FFAD00）是唯一标记；
        // 返回按钮靠"左半区有文字色 #725d42"间接证明（它的箭头与"返回"二字）。
        var shareMinX = Int.max
        var shareMaxX = -1
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.matches(x, y, 0xFFAD00, tolerance: 8) {
                shareMinX = min(shareMinX, x)
                shareMaxX = max(shareMaxX, x)
            }
        }
        #expect(shareMaxX >= 0, "顶栏没找到分享按钮（icon-helicopter）")
        #expect(shareMinX > pixels.width / 2, "分享按钮应在右侧")

        func textPixels(in range: Range<Int>) -> Int {
            var n = 0
            for y in 0..<pixels.height {
                for x in range where pixels.matches(x, y, 0x725D42, tolerance: 10) { n += 1 }
            }
            return n
        }
        #expect(textPixels(in: 0..<(pixels.width / 2)) > 0, "左半区应有返回按钮（箭头与文字）")
        #expect(textPixels(in: (pixels.width / 2)..<pixels.width) > 0, "右半区应有分享按钮的文字")
    }

    @Test("图片与标题属于固定区，不在滚动区里（回归）")
    func imageAndTitleLiveInPinnedHeader() throws {
        // 布局要求：图片与标题钉住，信息区自由滑动。
        // 可机检的部分是"这两块内容归属哪个视图"。
        //
        // ⚠️ 这条测试曾被一次区域替换误删（替换的结束位置定位到了下一段），
        // 导致用例数从 128 掉到 127 —— 所以改测试后要核对用例数。
        let json = """
        {"id":"p1","imageName":"IMG_1.jpeg","url":"https://x/o.jpg","previewUrl":"https://x/p.webp",
         "videoUrl":"","blurhash":"","width":4032,"height":3024,"title":"标题","detail":"描述",
         "type":1,"labels":[],"lon":"","lat":"",
         "exif":{"make":"Apple","model":"iPhone 17","lens_model":"back camera","focal_length":"5.96 mm",
                 "f_number":"f/1.6","exposure_time":"1/13","exposure_program":"Normal program",
                 "iso_speed_rating":640,"data_time":"2026:10:02 20:15:12","bits":"8"},
         "albumLicense":null,"createdAt":null}
        """
        let image = try APIDecoding.makeDecoder().decode(ImageDTO.self, from: Data(json.utf8))
        let model = PreviewModel(image: image, loader: ImageLoader())

        let header = try #require(IslandCardTests.rasterize(
            PreviewPinnedHeader(model: model, expansion: 1).frame(width: 393),
            scale: 2
        ))
        let panel = try #require(IslandCardTests.rasterize(
            PreviewInfoPanel(model: model, features: .none, onSelectTag: { _ in })
                .frame(width: 393, height: 1200),
            scale: 2
        ))

        // 固定区必须把主图包进去 —— 否则它只有标题，高度会矮很多（约 128pt）。
        // 为什么用高度而不是颜色：直方图面板的底也是 bgSecondary(#f0e8d8)，
        // 与图片占位同色，按颜色判断会把滚动区里的直方图误认成主图。
        let headerHeightPT = CGFloat(header.height) / 2
        #expect(
            headerHeightPT > 300,
            "固定区高 \(headerHeightPT)pt，过矮 —— 主图疑似不在固定区"
        )

        // 滚动区必须有信息分区，且不该有顶栏的分享按钮
        #expect(Self.count(panel, 0x19C8B9, tolerance: 6) > 0, "滚动区应有青色分区标题")
        #expect(Self.count(panel, 0xFFAD00, tolerance: 8) == 0, "滚动区不该有分享按钮")

        // 顶栏（含分享按钮）是独立的视图，不在这两块里
        let topBar = try #require(IslandCardTests.rasterize(
            PreviewTopBar(image: image, onBack: {}).padding(12).frame(width: 393),
            scale: 2
        ))
        #expect(Self.count(topBar, 0xFFAD00, tolerance: 8) > 0, "顶栏应有分享按钮")
    }

    @Test("图片随滚动放大：内缩 → 通栏（用户要求的核心效果）")
    func imageExpandsToFullBleed() throws {
        // expansion = 0：顶栏还在，图片内缩 16pt 且带圆角
        // expansion = 1：顶栏滚走，图片左右贴边（通栏）
        let json = """
        {"id":"p1","imageName":"IMG_1.jpeg","url":"https://x/o.jpg","previewUrl":"https://x/p.webp",
         "videoUrl":"","blurhash":"","width":4032,"height":3024,"title":"标题","detail":"",
         "type":1,"labels":[],"lon":"","lat":"",
         "exif":{"make":"Apple","model":"iPhone 17","lens_model":"back camera","focal_length":"5.96 mm",
                 "f_number":"f/1.6","exposure_time":"1/13","exposure_program":"Normal program",
                 "iso_speed_rating":640,"data_time":"2026:10:02 20:15:12","bits":"8"},
         "albumLicense":null,"createdAt":null}
        """
        let image = try APIDecoding.makeDecoder().decode(ImageDTO.self, from: Data(json.utf8))
        let model = PreviewModel(image: image, loader: ImageLoader())

        // 主图未加载时是平色占位 #f0e8d8，用它定位图片的水平范围。
        // （该颜色在固定区里只有图片用；标题是文字色、强调条是青色。）
        func imageSpan(_ expansion: CGFloat) throws -> (minX: Int, maxX: Int, width: Int) {
            let pixels = try #require(IslandCardTests.rasterize(
                PreviewPinnedHeader(model: model, expansion: expansion).frame(width: 393),
                scale: 2
            ))
            var minX = Int.max
            var maxX = -1
            for y in 0..<pixels.height {
                for x in 0..<pixels.width where pixels.matches(x, y, 0xF0E8D8, tolerance: 4) {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
            return (minX, maxX, pixels.width)
        }

        let inset = try imageSpan(0)
        let full = try imageSpan(1)

        #expect(inset.minX > 0, "未展开时图片应内缩，实际 minX=\(inset.minX)")
        #expect(full.minX == 0, "展开后图片应贴左边缘，实际 minX=\(full.minX)")
        #expect(full.maxX == full.width - 1, "展开后图片应贴右边缘，实际 maxX=\(full.maxX)")
        #expect(full.maxX - full.minX > inset.maxX - inset.minX, "展开后图片应更宽")
    }
}

/// 影调分析与直方图必须能**只靠缩略图**算出来。
///
/// 回归背景：`PreviewModel.load()` 原本把分析放在**原图下载之后** —— 原图是几 MB，
/// 用户滑到详情页时这两栏还没出现（"iPad 上看不到影调分析和直方图"）。
/// 现在缩略图到位就先算一次，所以"只用缩略图能算出结果"是这条修复的前提。
@Suite("影调与直方图的分析时机")
@MainActor
struct PreviewAnalysisTimingTests {
    @Test("只有缩略图时也能算出影调分析与直方图")
    func analysisWorksFromPreviewOnly() async {
        let json = """
        {"id":"x","title":"t","detail":"","width":4,"height":3,"type":1,
         "url":"https://example.invalid/o.jpg","previewUrl":"https://example.invalid/p.jpg",
         "exif":{"f_number":"f/1.6"},"labels":[]}
        """
        guard let image = try? APIDecoding.makeDecoder().decode(ImageDTO.self, from: Data(json.utf8)) else {
            Issue.record("测试用 ImageDTO 解码失败"); return
        }
        let model = PreviewModel(image: image, loader: ImageLoader())

        #if canImport(AppKit)
        let preview = NSImage(size: NSSize(width: 16, height: 12), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        model.previewImage = preview
        #endif

        await model.runAnalysis()

        #expect(model.tone != nil, "只给缩略图也应算出影调分析（这是不再等原图的前提）")
        #expect(model.histogram != nil, "只给缩略图也应算出直方图")
    }
}

/// 详情页布局规则（用户定义，已按用户更正过两次）：
/// **设备方向与照片方向一致 → 左右并排 + 信息双栏**；不一致 → 上下排 + 单栏。
@Suite("详情页布局决策")
struct DetailLayoutModeTests {
    private let portraitDevice = CGSize(width: 1024, height: 1366)   // iPad 竖屏
    private let landscapeDevice = CGSize(width: 1366, height: 1024)  // iPad 横屏
    private let phonePortrait = CGSize(width: 402, height: 874)
    private let landscapePhoto: CGFloat = 4.0 / 3.0
    private let portraitPhoto: CGFloat = 3.0 / 4.0

    @Test("竖屏设备 + 竖屏照片：左右并排、信息双栏、图片占 1/3")
    func portraitMatchesPortrait() {
        let m = PreviewView.layoutMode(size: portraitDevice, photoAspectRatio: portraitPhoto)
        #expect(m.stacked == false, "方向一致时应左右并排，而不是上下排")
        #expect(m.twoColumn, "并排时信息双栏")
        #expect(abs(m.imageFraction - 1.0 / 3.0) < 0.001, "双栏时图片让到 1/3")
    }

    @Test("竖屏设备 + 横屏照片：上下排、信息单栏")
    func portraitWithLandscapePhoto() {
        let m = PreviewView.layoutMode(size: portraitDevice, photoAspectRatio: landscapePhoto)
        #expect(m.stacked, "方向不一致时上下排")
        #expect(m.twoColumn == false, "上下排时信息单栏")
    }

    @Test("横屏设备 + 横屏照片：左右并排、信息双栏、图片占 1/3")
    func landscapeMatchesLandscape() {
        let m = PreviewView.layoutMode(size: landscapeDevice, photoAspectRatio: landscapePhoto)
        #expect(m.stacked == false)
        #expect(m.twoColumn)
        #expect(abs(m.imageFraction - 1.0 / 3.0) < 0.001)
    }

    @Test("横屏设备 + 竖屏照片：上下排、信息单栏")
    func landscapeWithPortraitPhoto() {
        let m = PreviewView.layoutMode(size: landscapeDevice, photoAspectRatio: portraitPhoto)
        #expect(m.stacked, "方向不一致时上下排")
        #expect(m.twoColumn == false)
    }

    @Test("iPhone 竖屏：屏幕放不下并排，一律上下排且单栏")
    func phonePortraitCases() {
        let a = PreviewView.layoutMode(size: phonePortrait, photoAspectRatio: portraitPhoto)
        #expect(a.stacked)
        #expect(a.twoColumn == false, "窄屏的双栏会挤成一团，所以即使方向一致也不双栏")
        let b = PreviewView.layoutMode(size: phonePortrait, photoAspectRatio: landscapePhoto)
        #expect(b.stacked)
        #expect(b.twoColumn == false)
    }
}

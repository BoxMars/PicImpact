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
            .init(id: "focal_length", icon: .map, value: "5.96 mm", label: "焦距"),
            .init(id: "f_number", icon: .variant, value: "f/1.6", label: "光圈"),
            .init(id: "exposure_time", icon: .miles, value: "1/13", label: "曝光时间"),
            .init(id: "iso", icon: .critterpedia, value: "ISO 640", label: "感光度"),
        ]
        data.deviceItems = [
            .init(id: "camera", icon: .camera, text: "Apple iPhone 17"),
            .init(id: "lens", icon: .design, text: "iPhone 17 back dual wide camera 5.96mm f/1.6"),
        ]
        data.deviceFocalRow = .init(id: "device_focal", label: "焦距", value: "5.96 mm")
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

    @Test("拍摄参数四个胶囊的图标都画出来了")
    func paramBadgeIconsRender() throws {
        let pixels = try #require(Self.rasterizeAtDeviceScale(
            PreviewInfoSections(data: Self.makeData())
                .background(AnimalSignatures.cardPaper)
                .frame(width: 340, height: 520)
        ))
        // 逐图标特征色：map 青 / variant 绿 / miles 青绿 / critterpedia 蓝绿
        let expectations: [(String, UInt32)] = [
            ("焦距 icon-map", 0x59C9C0),
            ("光圈 icon-variant", 0x5AA15B),
            ("曝光时间 icon-miles", 0x5ABF98),
            ("感光度 icon-critterpedia", 0x34ADB6),
        ]
        for (label, hex) in expectations {
            #expect(
                Self.count(pixels, hex, tolerance: 4) > 0,
                "\(label) 的特征色 \(String(format: "#%06X", hex)) 没画出来"
            )
        }
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
        // 但拍摄参数那四个胶囊的图标仍在（那是另一处，不受影响）
        #expect(Self.count(pixels, 0x59C9C0, tolerance: 4) > 0, "拍摄参数的 icon-map 仍应存在")
    }

    @Test("参数胶囊是纸色底 + 描边 + 硬阴影")
    func paramBadgeLooksLikeIslandCard() throws {
        let pixels = try #require(Self.rasterize(
            IslandParamBadge(icon: .map, value: "5.96 mm", label: "焦距")
                .padding(12)
                .background(Color.white)
        ))
        #expect(Self.count(pixels, 0xF7F3DF) > 200, "胶囊底色应为纸色")
        #expect(Self.count(pixels, 0xC4B89E) > 20, "胶囊应有描边")
        #expect(Self.count(pixels, 0xBDAEA0) > 20, "胶囊应有硬阴影（0 2px 0 0）")
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

    @Test("PreviewView 真的把分区接上了（渲染冒烟）")
    func previewViewWiresSections() throws {
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

        // 渲染内容块而不是 PreviewView：ImageRenderer 不渲染 ScrollView 的内容。
        // 2x 是因为整块在 3x 下会超过栅格化尺寸守卫。
        let pixels = try #require(IslandCardTests.rasterize(
            PreviewContentView(model: model, features: .none, onSelectTag: { _ in })
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
            PreviewContentView(model: model, features: .none, onSelectTag: { _ in })
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
}

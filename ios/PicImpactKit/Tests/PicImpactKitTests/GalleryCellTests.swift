import CoreGraphics
import SwiftUI
import Testing

@testable import PicImpactKit

/// 画廊卡片的渲染验证（信息块与操作行）。
@Suite("卡片 · 操作行与信息块渲染")
@MainActor
struct GalleryCellTests {

    typealias Pixels = IslandCardTests.Pixels

    static func makeImage() -> ImageDTO {
        let json = """
        {"id":"card-1","imageName":"IMG_1.jpeg","url":"https://x/o.jpg","previewUrl":"https://x/p.webp",
         "videoUrl":"","blurhash":"","width":4032,"height":3024,"title":"圆头圆脑圆肚皮","detail":"描述",
         "type":1,"labels":[],"lon":"","lat":"",
         "exif":{"make":"Apple","model":"iPhone 17","lens_model":"back camera","focal_length":"5.96 mm",
                 "f_number":"f/1.6","exposure_time":"1/13","exposure_program":"Normal program",
                 "iso_speed_rating":640,"data_time":"2026:10:02 20:15:12","bits":"8"},
         "albumLicense":null,"createdAt":null}
        """
        return try! APIDecoding.makeDecoder().decode(ImageDTO.self, from: Data(json.utf8))
    }

    static func makeCell(showDownload: Bool = true, isDownloading: Bool = false) -> GalleryCell {
        GalleryCell(
            image: makeImage(),
            columnWidth: 320,
            loader: ImageLoader(),
            showDownload: showDownload,
            isDownloading: isDownloading
        )
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

    @Test("操作行只有「分享 / 下载」两个按钮，不再有复制链接")
    func actionRowHasTwoLabeledButtons() throws {
        // 按用户要求：卡片下方按钮从三个（复制链接/分享/下载）改为两个（分享/下载）并带文字。
        // 用图标特征色判断（按设备 3x 渲染，否则 16pt 图标的颜色会被抗锯齿混掉）：
        //   icon-helicopter #FFAD00（分享）、icon-shopping #409B5E（下载）应在
        //   icon-diy 的独占色 #E68E6D（复制链接）应**不**在
        //
        // 为什么不用 diy 更显眼的 #FAD12B 做标记：icon-helicopter 自己含 #FFD103，
        // 与 #FAD12B 只差 (5,0,40)，抗锯齿混合后会产生落在容差内的像素
        // （实测 2 个：#FCD231 / #FDD42A）。**标记色要选抗锯齿后也不会撞的**：
        // #E68E6D 与直升机那套橙黄（#FFAD00 / #FFD103）相距很远，不会误判。
        let pixels = try #require(IslandCardTests.rasterize(Self.makeCell(), scale: 3))
        #expect(Self.count(pixels, 0xFFAD00) > 0, "分享按钮（icon-helicopter）没画出来")
        #expect(Self.count(pixels, 0x409B5E) > 0, "下载按钮（icon-shopping）没画出来")
        #expect(Self.count(pixels, 0xE68E6D) == 0, "复制链接按钮（icon-diy）应已移除")
    }

    @Test("关闭下载权限时操作行只剩分享")
    func downloadsHiddenWithoutFeature() throws {
        let pixels = try #require(IslandCardTests.rasterize(Self.makeCell(showDownload: false), scale: 3))
        #expect(Self.count(pixels, 0xFFAD00) > 0, "分享按钮应始终在")
        #expect(Self.count(pixels, 0x409B5E) == 0, "未开启下载能力时不应出现下载按钮")
    }

    @Test("下载中显示进度指示而不是下载按钮")
    func downloadingShowsSpinner() throws {
        let pixels = try #require(
            IslandCardTests.rasterize(Self.makeCell(isDownloading: true), scale: 3)
        )
        #expect(Self.count(pixels, 0xFFAD00) > 0, "分享按钮应在")
        #expect(Self.count(pixels, 0x409B5E) == 0, "下载中应换成进度指示，不该还是购物袋图标")
    }

    @Test("日期只显示到天（与 Web 的 YYYY-MM-DD 一致）")
    func cardShowsDateOnly() throws {
        // 渲染出的文字读不出来，这里验证数据层的格式；
        // 像素层只确认"日期文字确实画在了卡片上"（用日期文字的灰色 #c4b89e）。
        let date = EXIFTimeFormatter.displayDate(fromEXIF: "2026:10:02 20:15:12")
        #expect(date == "2026-10-02")
        #expect(date?.count == 10, "只应有 YYYY-MM-DD 十个字符")

        let pixels = try #require(IslandCardTests.rasterize(Self.makeCell(), scale: 2))
        #expect(Self.count(pixels, 0xC4B89E, tolerance: 8) > 0, "卡片上应有日期文字（描边同色系）")
    }
}

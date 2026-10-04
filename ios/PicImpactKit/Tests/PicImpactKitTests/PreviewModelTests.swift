import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing

@testable import PicImpactKit

/// 独立的图片桩：只服务真实 PNG 字节，让 `ImageLoader.image(for:)` 能解码成功。
/// 刻意**不复用** `ImageCacheTests` 里的计数桩 —— 那一个的全局状态用于断言请求次数，
/// 混用会互相污染。
final class PNGURLProtocolState: @unchecked Sendable {
    static let shared = PNGURLProtocolState()
    private let lock = NSLock()
    private var payload: Data

    init() {
        payload = Self.makePNG(red: 200, green: 120, blue: 80)
    }

    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return payload }
        set { lock.lock(); payload = newValue; lock.unlock() }
    }

    /// 生成纯色 PNG。用真实图片字节而不是随便一个 Data —— 否则解码环节直接失败，
    /// 测不到"加载成功后进入下一状态"的分支。
    static func makePNG(red: UInt8, green: UInt8, blue: UInt8, size: Int = 8) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = red
            pixels[index + 1] = green
            pixels[index + 2] = blue
            pixels[index + 3] = 255
        }
        let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cgImage = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}

final class PNGURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: PNGURLProtocolState.shared.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("T9/T10/T12 · 预览状态机 / EXIF / 下载")
@MainActor
struct PreviewModelTests {

    static func makeLoader() -> (ImageLoader, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicImpactPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PNGURLProtocol.self]
        config.urlCache = nil
        let cache = ImageCache(configuration: ImageCacheConfiguration(diskDirectory: directory))
        return (ImageLoader(cache: cache, session: URLSession(configuration: config)), directory)
    }

    static func makeImage(
        preview: String = "https://example.test/p.webp",
        original: String = "https://example.test/o.jpg",
        type: Int = 1,
        exifJSON: String = #"{"make":"Apple","model":"iPhone 17","lens_model":"back camera","focal_length":"5.96 mm","f_number":"f/1.6","exposure_time":"1/13","exposure_program":"Normal program","exposure_mode":"Auto exposure","white_balance":"Auto white balance","iso_speed_rating":640,"data_time":"2026:10:02 20:15:12","bits":"8"}"#,
        width: Int = 4032,
        height: Int = 3024,
        labels: String = "[]"
    ) -> ImageDTO {
        let json = """
        {"id":"preview-1","imageName":"IMG_0001.jpeg","url":"\(original)","previewUrl":"\(preview)",
         "videoUrl":"","blurhash":"","width":\(width),"height":\(height),"title":"标题","detail":"描述",
         "type":\(type),"labels":\(labels),"lon":"","lat":"","exif":\(exifJSON),
         "albumLicense":null,"createdAt":"2026-10-03T11:36:14.539Z"}
        """
        return try! APIDecoding.makeDecoder().decode(ImageDTO.self, from: Data(json.utf8))
    }

    // MARK: - T9 加载顺序

    @Test("先加载缩略图并立即可显示，再加载原图")
    func loadsPreviewBeforeOriginal() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PreviewModel(image: Self.makeImage(), loader: loader)

        #expect(model.showsPreview == false)
        #expect(model.phase == .idle)

        await model.load()

        #expect(model.showsPreview, "缩略图应已就绪（对应 Web 的底图淡入）")
        #expect(model.showsOriginal, "原图应已就绪（对应 HD 层淡入）")
        #expect(model.phase == .originalReady)
    }

    @Test("分析结果用原图计算，且影调/直方图都产出")
    func runsAnalysisAfterLoading() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PreviewModel(image: Self.makeImage(), loader: loader)

        await model.load()

        let tone = try #require(model.tone)
        let histogram = try #require(model.histogram)
        #expect(histogram.red.count == Histogram.binCount)
        // 桩图是纯色 (200,120,80)：亮度 = round(0.2126*200 + 0.7152*120 + 0.0722*80)
        //                              = round(42.52 + 85.82 + 5.78) = round(134.12) = 134
        // → brightness = round(134/255*100) = 53
        #expect(tone.brightness == 53, "纯色桩图的亮度应与手算一致，实际 \(tone.brightness)")
        #expect(tone.contrast == 0, "纯色图标准差为 0，对比度应为 0")
        #expect(tone.toneType == .normal)
    }

    @Test("没有独立原图时（只有一张图）也能到达 originalReady")
    func handlesSingleURLImage() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let same = "https://example.test/same.webp"
        let model = PreviewModel(image: Self.makeImage(preview: same, original: same), loader: loader)

        await model.load()

        #expect(model.phase == .originalReady)
        #expect(model.showsOriginal)
    }

    // MARK: - T10 详情页信息分区（对齐 Web `preview-image.tsx`）

    @Test("分区覆盖 Web 展示的全部字段，且顺序一致")
    func infoSectionsCoverWebFields()async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = PreviewModel(image: Self.makeImage(), loader: loader).infoData

        #expect(data.basicInfo.map(\.id) == ["dimensions", "pixels", "data_time"])
        #expect(data.captureParams.map(\.id) == ["focal_length", "f_number", "exposure_time", "iso"])
        #expect(data.deviceItems.map(\.id) == ["camera", "lens"])
        #expect(data.deviceFocalRow?.id == "device_focal")
        #expect(data.captureMode.map(\.id) == ["exposure_program", "exposure_mode", "white_balance"])
        #expect(data.technical.map(\.id) == ["bits"])
    }

    @Test("焦距用详情页格式 toFixed(2)+mm（与卡片的 toFixed(0) 不同）")
    func focalLengthUsesPreviewFormat() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 生产实测原始值是 "5.960000038146973 mm"；这里用 "5.96 mm" 验证取整逻辑
        let model = PreviewModel(image: Self.makeImage(), loader: loader)

        #expect(model.focalLengthText == "5.96 mm")
        #expect(model.captureParams.first { $0.id == "focal_length" }?.value == "5.96 mm")
        // 设备信息里也重复出现一次（Web 两处都显示）
        #expect(model.deviceFocalRow?.value == "5.96 mm")
    }

    @Test("拍摄参数的图标与 Web 一一对应（map/variant/miles/critterpedia）")
    func captureParamIconsMatchWeb() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let params = PreviewModel(image: Self.makeImage(), loader: loader).captureParams
        #expect(params.map(\.icon) == [.map, .variant, .miles, .critterpedia])
        #expect(params.first { $0.id == "iso" }?.value == "ISO 640")
    }

    @Test("设备信息要求 make 与 model 同时存在（与 Web 一致）")
    func deviceCameraNeedsBothMakeAndModel() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 只有 model 没有 make
        let onlyModel = #"{"model":"iPhone 17","lens_model":"back camera"}"#
        let data = PreviewModel(image: Self.makeImage(exifJSON: onlyModel), loader: loader).infoData
        #expect(data.deviceItems.contains { $0.id == "camera" } == false, "缺 make 时不该显示相机行")
        #expect(data.deviceItems.contains { $0.id == "lens" }, "镜头行不受影响")
    }

    @Test("分区标题与行标签取自与 Web 同一份 i18n 表")
    func labelsComeFromSharedCatalog() {
        // 取到裸 key 就说明回退表或本地化有问题
        #expect(IslandStrings.text("Exif.basicInfo") == "基本信息")
        #expect(IslandStrings.text("Exif.captureParams") == "拍摄参数")
        #expect(IslandStrings.text("Exif.deviceInfo") == "设备信息")
        #expect(IslandStrings.text("Exif.captureMode") == "拍摄模式")
        #expect(IslandStrings.text("Exif.technicalParams") == "技术参数")
        #expect(IslandStrings.text("Exif.toneAnalysis") == "影调分析")
        #expect(IslandStrings.text("Exif.histogram") == "直方图")
        #expect(IslandStrings.text("Exif.tags") == "标签")
        #expect(IslandStrings.text("Exif.captureTime") == "拍摄时间")
        #expect(IslandStrings.text("Exif.bitDepth") == "位深度")
        #expect(IslandStrings.text("Exif.whiteBalance") == "白平衡")
        #expect(IslandStrings.text("Exif.toneType") == "影调类型")
        #expect(IslandStrings.text("Exif.shadowRatio") == "阴影占比")
        #expect(IslandStrings.text("Exif.highlightRatio") == "高光占比")
    }

    @Test("影调类型文案与 Web 一致（正常/高对比度，而不是常规/高对比）")
    func toneLabelsMatchWeb() {
        // 这里曾经写错过：硬编码成"常规""高对比"，与 Web 的 i18n 值不符
        #expect(IslandStrings.text("Exif.toneNormal") == "正常")
        #expect(IslandStrings.text("Exif.toneHighContrast") == "高对比度")
        #expect(IslandStrings.text("Exif.toneLowKey") == "低调")
        #expect(IslandStrings.text("Exif.toneHighKey") == "高调")
    }

    @Test("EXIF 时间被归一化为可读格式（不是原始的冒号格式）")
    func exifTimeIsNormalized() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PreviewModel(image: Self.makeImage(), loader: loader)

        let row = try #require(model.basicInfoRows.first { $0.id == "data_time" })
        // 只保留日期（与 Web 的 formatExifDateTimeForDisplay 一致，它输出 YYYY-MM-DD）
        #expect(row.value == "2026-10-02")
        #expect(row.value.contains(" ") == false, "不应再带时分秒")
        #expect(row.value.contains("2026:10") == false, "不应保留 EXIF 的冒号格式")
    }

    @Test("缺失的 EXIF 字段不会产生空行")
    func missingFieldsProduceNoRows() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = PreviewModel(image: Self.makeImage(exifJSON: "null"), loader: loader).infoData

        // EXIF 为空，但尺寸来自图片本身，仍应展示
        #expect(data.basicInfo.map(\.id).contains("dimensions"))
        #expect(data.captureParams.isEmpty)
        #expect(data.deviceItems.isEmpty)
        #expect(data.captureMode.isEmpty)
        #expect(data.technical.isEmpty)
        let values = data.basicInfo.map(\.value)
        #expect(values.allSatisfy { !$0.isEmpty }, "不应有值为空的行")
    }

}

// MapGalleryView 是 View，其静态方法被 main-actor 隔离；而 MapCameraPosition 非 Sendable，
/// 所以这个套件必须跑在 MainActor 上。
@Suite("地图 · 坐标解析")
@MainActor
struct MapGalleryTests {

    static func makeImage(lon: String, lat: String, id: String = "m") -> ImageDTO {
        let json = """
        {"id":"\(id)","imageName":"","url":"https://x/a.jpg","previewUrl":"https://x/a.webp",
         "videoUrl":"","blurhash":"","width":100,"height":100,"title":"","detail":"","type":1,
         "labels":[],"lon":"\(lon)","lat":"\(lat)","exif":null,"albumLicense":null,"createdAt":null}
        """
        return try! APIDecoding.makeDecoder().decode(ImageDTO.self, from: Data(json.utf8))
    }

    @Test("有效坐标被保留，并按字符串解析（不是 Double 字段）")
    func validCoordinatesAreKept() {
        let images = [Self.makeImage(lon: "113.51680833333333", lat: "22.179469444444447")]
        let located = MapGalleryView.located(from: images)
        #expect(located.count == 1)
        #expect(abs(located[0].coordinate.latitude - 22.179469444444447) < 1e-12)
        #expect(abs(located[0].coordinate.longitude - 113.51680833333333) < 1e-12)
    }

    @Test("空串与 (0,0) 视为无效（与 Web 的 fetchMapImages 语义一致）")
    func invalidCoordinatesAreDropped() {
        let images = [
            Self.makeImage(lon: "", lat: "", id: "empty"),
            Self.makeImage(lon: "0", lat: "0", id: "origin"),
            Self.makeImage(lon: "113.5", lat: "22.1", id: "valid"),
        ]
        let located = MapGalleryView.located(from: images)
        #expect(located.count == 1)
        #expect(located[0].image.id == "valid")
    }

    @Test("超出经纬度范围的值被丢弃（防脏数据把地图拉到荒谬位置）")
    func outOfRangeCoordinatesAreDropped() {
        let images = [
            Self.makeImage(lon: "200", lat: "22", id: "lon-out"),
            Self.makeImage(lon: "113", lat: "95", id: "lat-out"),
            Self.makeImage(lon: "113", lat: "22", id: "ok"),
        ]
        let located = MapGalleryView.located(from: images)
        #expect(located.count == 1)
        #expect(located[0].image.id == "ok")
    }

    @Test("初始视野覆盖全部点并留出余量")
    func initialPositionCoversAllPoints() throws {
        let images = [
            Self.makeImage(lon: "113.0", lat: "22.0", id: "a"),
            Self.makeImage(lon: "114.0", lat: "23.0", id: "b"),
        ]
        let located = MapGalleryView.located(from: images)
        let position = MapGalleryView.initialPosition(for: located)
        let region = try #require(position.region)
        #expect(abs(region.center.latitude - 22.5) < 0.001)
        #expect(abs(region.center.longitude - 113.5) < 0.001)
        #expect(region.span.latitudeDelta > 1.0, "应留出余量覆盖两端")
    }

    @Test("没有点时给一个兜底视野而不是崩溃")
    func emptyItemsFallback() throws {
        let position = MapGalleryView.initialPosition(for: [])
        let region = try #require(position.region)
        #expect(region.span.latitudeDelta > 0)
    }
}

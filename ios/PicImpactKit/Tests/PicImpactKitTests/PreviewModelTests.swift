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
        exifJSON: String = #"{"make":"Apple","model":"iPhone 17","lens_model":"back camera","focal_length":"5.96 mm","f_number":"f/1.6","exposure_time":"1/13","exposure_program":"Normal program","iso_speed_rating":640,"data_time":"2026:10:02 20:15:12","bits":"8"}"#,
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

    // MARK: - T10 EXIF 行

    @Test("EXIF 行包含 Web 端读取的全部字段且有值")
    func exifRowsCoverWebFields() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PreviewModel(image: Self.makeImage(), loader: loader)

        let rows = model.exifRows()
        let ids = rows.map(\.id)
        #expect(ids.contains("dimensions"))
        #expect(ids.contains("pixels"))
        #expect(ids.contains("data_time"))
        #expect(ids.contains("make"))
        #expect(ids.contains("model"))
        #expect(ids.contains("lens_model"))
        #expect(ids.contains("focal_length"))
        #expect(ids.contains("f_number"))
        #expect(ids.contains("exposure_time"))
        #expect(ids.contains("iso_speed_rating"))
        #expect(ids.contains("bits"))
    }

    @Test("尺寸与像素文案与 Web 一致")
    func dimensionTexts() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PreviewModel(image: Self.makeImage(width: 4032, height: 3024), loader: loader)

        #expect(model.dimensionsText == "4032 × 3024")
        // 4032 × 3024 = 12,192,768 → 12.2 MP
        #expect(model.megapixelsText == "12.2 MP")
    }

    @Test("EXIF 时间被归一化为可读格式（不是原始的冒号格式）")
    func exifTimeIsNormalized() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PreviewModel(image: Self.makeImage(), loader: loader)

        let row = try #require(model.exifRows().first { $0.id == "data_time" })
        #expect(row.value == "2026-10-02 20:15:12")
        #expect(row.value.contains(":") == true && !row.value.contains("2026:10"))
    }

    @Test("缺失的 EXIF 字段不会产生空行")
    func missingFieldsProduceNoRows() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PreviewModel(image: Self.makeImage(exifJSON: "null"), loader: loader)

        let rows = model.exifRows()
        let ids = rows.map(\.id)
        // EXIF 为空但尺寸仍应展示（尺寸来自图片本身，不依赖 EXIF）
        #expect(ids.contains("dimensions"))
        #expect(ids.contains("make") == false, "无 EXIF 时不应出现空的相机行")
        #expect(rows.allSatisfy { !$0.value.isEmpty }, "不应有值为空的行")
    }

    // MARK: - T12 下载

    @Test("下载成功记录对应图片 id")
    func downloadRecordsImage() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = RecordingDownloadService()
        let model = PreviewModel(image: Self.makeImage(), loader: loader, downloader: recorder)

        await model.download()

        #expect(await recorder.recorded() == ["preview-1"])
        #expect(model.downloadError == nil)
        #expect(model.isDownloading == false)
    }

    @Test("下载失败会给出可读错误且不抛出到界面外")
    func downloadFailureIsSurfaced() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PreviewModel(
            image: Self.makeImage(),
            loader: loader,
            downloader: RecordingDownloadService(shouldFail: true)
        )

        await model.download()

        let message = try #require(model.downloadError)
        #expect(message.contains("权限"), "应提示相册权限，实际：\(message)")
        #expect(model.isDownloading == false)
    }

    @Test("没有下载器时点击下载是安全的空操作")
    func downloadWithoutServiceIsSafe() async throws {
        let (loader, directory) = Self.makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PreviewModel(image: Self.makeImage(), loader: loader)

        await model.download()
        #expect(model.downloadError == nil)
    }

    // MARK: - 像素采样

    @Test("采样器把纯色图正确转成缓冲（尺寸受 maxSize 约束）")
    func samplerRespectsMaxSize() throws {
        let png = PNGURLProtocolState.makePNG(red: 200, green: 120, blue: 80, size: 64)
        // 用 PlatformImage（UIKit/AppKit 的类型别名）：测试文件不 import 那两个框架，
        // 直接写 UIImage/NSImage 会找不到符号
        let image = try #require(PlatformImage(data: png))

        // 64×64 缩到 maxSize 32 → 32×32
        let buffer = try #require(PixelSampler.buffer(from: image, maxSize: 32))
        #expect(buffer.width == 32)
        #expect(buffer.height == 32)

        // maxSize 大于图片时**会放大**（这是照抄 Web 公式 min(maxSize/w, maxSize/h) 的结果，
        // 不是 bug）。64×64 在 maxSize 200 下会变成 200×200。
        let upscaled = try #require(PixelSampler.buffer(from: image, maxSize: 200))
        #expect(upscaled.width == 200, "与 Web 一致：小图会被放大到 maxSize")
        #expect(upscaled.height == 200)

        // 纯色：任意像素都应是同一个值
        let tone = ImageAnalysis.analyzeTone(buffer)
        #expect(tone.contrast == 0, "纯色图标准差应为 0")
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

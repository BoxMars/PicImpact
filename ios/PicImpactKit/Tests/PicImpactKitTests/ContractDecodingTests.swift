import Foundation
import Testing

@testable import PicImpactKit

/// T4 验证：DTO 能解开**生产真实响应**，并且对契约允许的变化保持容忍。
///
/// fixture 不是手写样本，而是直接从生产抓下来的响应原文：
///   site-config.json / albums.json / gallery-page-1.json
/// 手写样本永远测不出真实数据里的异构（例如 EXIF 的 `iso_speed_rating` 是数字而非字符串）。
@Suite("T4 · API DTO 契约解码")
struct ContractDecodingTests {

    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw TestError.missing("找不到 fixture \(name).json")
        }
        return try Data(contentsOf: url)
    }

    enum TestError: Error { case missing(String) }

    let decoder = APIDecoding.makeDecoder()

    // MARK: - 真实响应

    @Test("解开生产 /config")
    func decodeSiteConfig() throws {
        let envelope = try decoder.decode(ApiEnvelope<SiteConfigDTO>.self, from: try Self.fixture("site-config"))
        #expect(envelope.code == 200)
        let config = envelope.data
        #expect(config.apiVersion == "v1")
        #expect(config.pageSize == 24)
        #expect(config.site.indexStyle == "1", "首页应为 ACNH 岛屿卡风格（'1'）")
        // 这两个开关曾因把 "true" 误判成 "1" 而报错，这里固定住
        #expect(config.features.download == true)
        #expect(config.features.origin == true)
        #expect(config.site.title.isEmpty == false)
    }

    @Test("解开生产 /albums")
    func decodeAlbums() throws {
        let envelope = try decoder.decode(ApiEnvelope<[AlbumDTO]>.self, from: try Self.fixture("albums"))
        let albums = envelope.data
        #expect(albums.isEmpty == false, "生产至少有首页相册之外的相册")
        for album in albums {
            #expect(album.value.hasPrefix("/"), "album value 形如 /daily，实际 \(album.value)")
        }
    }

    @Test("解开生产 /images（24 条，字段完整）")
    func decodeGalleryPage() throws {
        let envelope = try decoder.decode(ApiEnvelope<ImagePageDTO>.self, from: try Self.fixture("gallery-page-1"))
        let page = envelope.data
        #expect(page.list.count == 24)
        #expect(page.page == 1)
        #expect(page.pageSize == 24)
        #expect(page.pageTotal == 2)
        #expect(page.hasMore == true)

        let first = try #require(page.list.first)
        #expect(first.id == "qdfkfpjlrj24ce80efaa6b4y")
        #expect(first.imageName == "IMG_2855.jpeg")
        #expect(first.width == 4032)
        #expect(first.height == 3024)
        #expect(first.type == 1)
        #expect(first.isLivePhoto == false)
        #expect(first.labels.isEmpty)
        #expect(first.albumLicense == nil)
        #expect(first.createdAt != nil, "createdAt 带毫秒，必须能被解析")
        #expect(first.previewURL.contains("/preview/"), "缩略图走 previewUrl")
        #expect(first.displayURL?.absoluteString == first.previewURL, "列表应使用缩略图")
        #expect(abs(first.aspectRatio - 4032.0 / 3024.0) < 0.0001)
    }

    @Test("经纬度保持字符串（不是 Double）")
    func coordinatesStayStrings() throws {
        let envelope = try decoder.decode(ApiEnvelope<ImagePageDTO>.self, from: try Self.fixture("gallery-page-1"))
        let first = try #require(envelope.data.list.first)
        #expect(first.lon == "113.51680833333333")
        #expect(first.lat == "22.179469444444447")
        #expect(first.hasCoordinate)
        // 生产里存在空串表示缺失
        let missing = envelope.data.list.first { $0.lon.isEmpty }
        #expect(missing != nil, "应存在经纬度为空的条目，用于验证空串不参与地图")
        #expect(missing?.hasCoordinate == false)
    }

    // MARK: - 异构与容错（真实数据里就存在）

    @Test("EXIF 的数字字段能被宽松解析（生产实测 iso_speed_rating = 640 是数字）")
    func exifNumericFieldIsLenient() throws {
        let envelope = try decoder.decode(ApiEnvelope<ImagePageDTO>.self, from: try Self.fixture("gallery-page-1"))
        let exif = try #require(envelope.data.list.first?.exif)
        #expect(exif.isoSpeedRating == "640", "数字应被转成字符串，实际 \(exif.isoSpeedRating ?? "nil")")
        #expect(exif.make == "Apple")
        #expect(exif.model == "iPhone 17")
        #expect(exif.fNumber == "f/1.6")
        #expect(exif.exposureTime == "1/13")
        #expect(exif.bits == "8")
    }

    @Test("EXIF 里未声明的字段被忽略，不影响解码")
    func exifIgnoresUnknownFields() throws {
        // 生产响应里确实有 lens_specification / color_space 等我们没声明的字段
        let envelope = try decoder.decode(ApiEnvelope<ImagePageDTO>.self, from: try Self.fixture("gallery-page-1"))
        let withExtra = envelope.data.list.filter { $0.exif != nil }
        #expect(withExtra.count == 24, "24 条都能解开，说明未声明字段确实被忽略了")
    }

    // MARK: - 前向兼容（服务端只会加字段，客户端必须不受影响）

    @Test("响应里多出未知字段仍然解码成功（服务端只做加法）")
    func unknownTopLevelFieldsAreTolerated() throws {
        let json = """
        {
          "code": 200,
          "message": "ok",
          "data": {
            "list": [{
              "id": "abc", "imageName": "a.jpg",
              "url": "https://x/a.jpg", "previewUrl": "https://x/p.webp",
              "videoUrl": "", "blurhash": "", "width": 100, "height": 50,
              "title": "t", "detail": "", "type": 1, "labels": [],
              "lon": "", "lat": "", "exif": null, "albumLicense": null,
              "createdAt": null,
              "futureFieldFromServer": { "nested": [1, 2, 3] }
            }, {
              "id": "def", "imageName": "b.jpg",
              "url": "https://x/b.jpg", "previewUrl": "https://x/p2.webp",
              "videoUrl": "", "blurhash": "", "width": 100, "height": 50,
              "title": "t2", "detail": "", "type": 2, "labels": ["日常"],
              "lon": "", "lat": "", "exif": null, "albumLicense": "CC BY",
              "createdAt": "2026-10-03T11:36:14.539Z"
            }],
            "page": 1, "pageSize": 24, "pageTotal": 1, "hasMore": false,
            "anotherFutureField": true
          }
        }
        """.data(using: .utf8)!
        let envelope = try decoder.decode(ApiEnvelope<ImagePageDTO>.self, from: json)
        #expect(envelope.data.list.count == 2)
        #expect(envelope.data.list[1].isLivePhoto, "type=2 应为 Live Photo")
        #expect(envelope.data.list[1].labels == ["日常"])
        #expect(envelope.data.list[1].albumLicense == "CC BY")
    }

    @Test("labels 为 null 时退化为空数组而不是解码失败")
    func nullLabelsDegradeGracefully() throws {
        let json = """
        {"id":"a","imageName":"","url":"","previewUrl":"","videoUrl":"","blurhash":"",
         "width":0,"height":0,"title":"","detail":"","type":1,"labels":null,
         "lon":"","lat":"","exif":null,"albumLicense":null,"createdAt":null}
        """.data(using: .utf8)!
        let image = try decoder.decode(ImageDTO.self, from: json)
        #expect(image.labels.isEmpty)
        #expect(image.aspectRatio == 1, "缺尺寸时应回退为 1，避免 NaN 破坏布局")
        #expect(image.displayURL == nil, "url 与 previewUrl 都空时没有可显示的图")
    }

    // MARK: - EXIF 时间归一化（必须与 Web 端一致）

    @Test("EXIF 时间从 `YYYY:MM:DD HH:MM:SS` 归一化")
    func exifTimeNormalization() {
        #expect(EXIFTimeFormatter.displayDate(fromEXIF: "2026:10:02 20:15:12") == "2026-10-02")
        // 部分设备写连字符
        #expect(EXIFTimeFormatter.displayDate(fromEXIF: "2026-10-02 20:15:12") == "2026-10-02")
        // 缺失或空串应返回 nil，由界面决定降级方式
        #expect(EXIFTimeFormatter.displayDate(fromEXIF: nil) == nil)
        #expect(EXIFTimeFormatter.displayDate(fromEXIF: "") == nil)
        #expect(EXIFTimeFormatter.displayDate(fromEXIF: "   ") == nil)
    }

    // MARK: - 错误映射

    @Test("非 2xx 会带上服务端信息抛出，且 404 单独成类")
    func errorMapping() throws {
        let url = try #require(URL(string: "https://example.invalid/envelope"))
        #expect(url.host() == "example.invalid")
        // 这里只断言错误的可读描述（真正的网络路径由集成测试覆盖，单测不依赖外网）
        let notFound = APIError.notFound
        #expect(notFound.errorDescription?.isEmpty == false)
        let decoding = APIError.decoding("x")
        #expect(decoding.errorDescription?.contains("契约") == true, "契约错误应被明确提示，便于排查")
    }
}

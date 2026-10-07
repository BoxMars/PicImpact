import Foundation
import Testing

@testable import PicImpactKit

/// 管理接口客户端的**请求构造**与错误映射。
///
/// 这些是"客户端契约"的唯一落点：字段名错一个（例如把 `albumValue` 写成 `album`）服务端会 400，
/// 而 400 在真机上只会表现为"上传失败"，很难看出是哪个字段。所以逐字段断言。
@Suite("管理接口 · 请求构造与错误映射")
struct AdminImageClientTests {

    private let origin = URL(string: "https://felina.boxz.dev")!
    private let cookie = "__Secure-pic-impact.session_token=abc.def"

    @Test("签发请求：POST /api/v1/admin/uploads/sign，体里只有四个约定字段")
    func signRequestShape() throws {
        let request = try AdminImageClient.signRequest(
            siteOrigin: origin,
            filename: "IMG_0001.HEIC",
            contentType: "image/heic",
            albumValue: "/daily",
            size: 3_560_000,
            cookie: cookie
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://felina.boxz.dev/api/v1/admin/uploads/sign")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cookie") == cookie)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "这个后端没有 bearer 插件")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json.count == 4, "实际字段：\(json.keys.sorted())")
        #expect(json["filename"] as? String == "IMG_0001.HEIC")
        #expect(json["contentType"] as? String == "image/heic")
        #expect(json["albumValue"] as? String == "/daily")
        #expect(json["size"] as? Int == 3_560_000)
    }

    @Test("登记请求：只发约定字段，**不含** preview_url / blurhash / show")
    func registerRequestBody() throws {
        let input = AdminRegisterInput(
            albumValue: "/daily",
            url: "https://felina-asset.boxz.dev/images/daily/abc.jpg",
            imageName: "photo-20261007-120000-ab12.jpg",
            title: "",
            detail: "",
            labels: [],
            exif: ["model": .string("iPhone 15"), "iso_speed_rating": .int(640)],
            lat: "",
            lon: "",
            width: 1600,
            height: 1200,
            type: 1
        )
        let request = try AdminImageClient.registerRequest(siteOrigin: origin, input: input, cookie: cookie)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://felina.boxz.dev/api/v1/admin/images")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["albumValue"] as? String == "/daily")
        #expect(json["url"] as? String == input.url)
        #expect(json["width"] as? Int == 1600)

        // 这三个字段由服务端负责（评审要点 4 的裁决），客户端**不能**发
        #expect(json["preview_url"] == nil)
        #expect(json["blurhash"] == nil)
        #expect(json["show"] == nil, "show/show_on_mainpage 由服务端写死 0，客户端无权设置")
        #expect(json["show_on_mainpage"] == nil)

        // EXIF 的类型要保真：字符串还是字符串，数字还是数字
        let exif = try #require(json["exif"] as? [String: Any])
        #expect(exif["model"] as? String == "iPhone 15")
        #expect(exif["iso_speed_rating"] as? Int == 640)
    }

    @Test("列表请求：GET 带 page/pageSize/album，album 为空时不带该参数")
    func listRequestQuery() throws {
        let withAlbum = try AdminImageClient.listRequest(
            siteOrigin: origin, page: 2, pageSize: 24, album: "/daily", cookie: cookie
        )
        #expect(withAlbum.httpMethod == "GET")
        // `/` 在 query 里是合法字符，URLComponents 不一定做百分号编码 —— 断言**解码后的值**才对
        let url = try #require(withAlbum.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["page"] == "2")
        #expect(items["pageSize"] == "24")
        #expect(items["album"] == "/daily")

        let withoutAlbum = try AdminImageClient.listRequest(
            siteOrigin: origin, page: 1, pageSize: 24, album: nil, cookie: cookie
        )
        #expect(withoutAlbum.url?.query?.contains("album=") == false)
    }

    @Test("删除请求：DELETE /api/v1/admin/images/<id>")
    func deleteRequestShape() {
        let request = AdminImageClient.deleteRequest(siteOrigin: origin, id: "clx123", cookie: cookie)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://felina.boxz.dev/api/v1/admin/images/clx123")
        #expect(request.value(forHTTPHeaderField: "Cookie") == cookie)
    }

    @Test("错误体只取服务端原话（不把状态码塞进界面文案）")
    func errorMapping() {
        let body = Data(#"{"code":401,"message":"authentication failed"}"#.utf8)
        let error = AdminImageClient.apiError(status: 401, body: body)
        #expect(error == .http(status: 401, code: nil, message: "authentication failed"))
        #expect(error.serverMessage == "authentication failed")

        // 非 JSON 正文（网关 HTML）时不给 message，界面会退回通用文案
        let html = AdminImageClient.apiError(status: 502, body: Data("<html>bad gateway</html>".utf8))
        #expect(html.serverMessage == nil)
    }

    @Test("响应解码：签发 / 登记 / 列表 / 删除的字段名与契约一致")
    func decodesResponses() throws {
        let decoder = APIDecoding.makeDecoder()

        let sign = try decoder.decode(
            SignedUpload.self,
            from: Data(#"{"key":"images/daily/a.jpg","uploadUrl":"https://r2.example.com/a?X=1","publicUrl":"https://felina-asset.boxz.dev/images/daily/a.jpg","contentType":"image/jpeg","expiresInSeconds":900}"#.utf8)
        )
        #expect(sign.key == "images/daily/a.jpg")
        #expect(sign.uploadURL?.host() == "r2.example.com")
        #expect(sign.expiresInSeconds == 900)

        let registered = try decoder.decode(
            RegisteredImage.self,
            from: Data(#"{"id":"clx1","url":"https://x/a.jpg","previewUrl":"https://x/preview/a.webp","width":1600,"height":1000,"blurhash":"abc","albumValue":"/daily","show":0,"showOnMainpage":0}"#.utf8)
        )
        #expect(registered.previewUrl.hasSuffix(".webp"))
        #expect(registered.show == 0)

        let page = try decoder.decode(
            AdminImagePage.self,
            from: Data(#"{"page":1,"pageSize":24,"total":58,"hasMore":true,"items":[{"id":"clx1","url":"https://x/a.jpg","previewUrl":"","title":"标题","detail":"","width":1600,"height":1000,"show":0,"showOnMainpage":0,"labels":["a"],"createdAt":"2026-10-07T09:12:43.471Z","albumValue":"/daily","albumName":"大福日常","exif":{"model":"iPhone 15","lensModel":"","dataTime":""}}]}"#.utf8)
        )
        #expect(page.items.count == 1)
        #expect(page.items[0].title == "标题")
        #expect(page.items[0].createdAt != nil, "ISO8601 带毫秒也要能解")
        // 预览图为空时退回原图：列表至少能显示东西
        #expect(page.items[0].thumbnailURL?.absoluteString == "https://x/a.jpg")
    }
}

/// `JSONValue` 的编码保真：`iso_speed_rating` 是数字、`model` 是字符串。
@Suite("JSONValue · 编解码")
struct JSONValueTests {

    @Test("数字与字符串分别保真（不能把 640 变成 \"640\"）")
    func roundTrip() throws {
        let original: [String: JSONValue] = [
            "model": .string("iPhone 15"),
            "iso_speed_rating": .int(640),
            "f_number": .string("f/1.6"),
            "exposure_time": .string("1/39"),
        ]
        let data = try JSONEncoder().encode(original)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "iPhone 15")
        #expect(json["iso_speed_rating"] as? Int == 640, "数字被写成了字符串")

        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(decoded == original)
    }

    @Test("整数值的 double 不留小数尾巴")
    func trimsTrailingZeros() {
        #expect(JSONValue.trim(640) == "640")
        #expect(JSONValue.trim(5.96) == "5.96")
        #expect(JSONValue.stringValue(for: .double(640)) == "640")
    }
}

private extension JSONValue {
    static func stringValue(for value: JSONValue) -> String? { value.stringValue }
}

/// 走**真实 URLSession** 的路径（本地 HTTP 服务）：请求构造对了但 URL 不能被 URLSession 接受时，
/// 症状是 `APIError.transport("unsupported URL")` —— 在真机上只会显示成一句看不懂的文案。
@Suite("管理接口 · 真实网络路径（本地服务）", .serialized)
struct AdminImageClientHTTPTests {

    @Test("列表请求真的发得出去，且带上了会话 Cookie 与查询参数")
    func listImagesOverHTTP() async throws {
        let server = try LocalHTTPServer(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"code":200,"data":{"page":1,"pageSize":24,"total":1,"hasMore":false,"items":[]}}"#
        ))
        defer { server.stop() }

        let client = AdminImageClient(
            configuration: .init(siteOrigin: server.origin, session: AdminImageClient.makeSession())
        )
        let page = try await client.listImages(page: 1, pageSize: 24, album: "/daily", cookie: "session=abc")

        #expect(page.total == 1)
        let request = try #require(server.receivedRequests.first)
        #expect(request.hasPrefix("GET /api/v1/admin/images?"))
        #expect(request.contains("album=/daily") || request.contains("album=%2Fdaily"))
        #expect(request.localizedCaseInsensitiveContains("Cookie: session=abc"))
    }

    @Test("签发请求真的发得出去（POST + JSON 体）")
    func signOverHTTP() async throws {
        let server = try LocalHTTPServer(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"code":200,"data":{"key":"images/daily/a.jpg","uploadUrl":"https://r2.example.com/a","publicUrl":"https://felina-asset.boxz.dev/images/daily/a.jpg","contentType":"image/jpeg","expiresInSeconds":900}}"#
        ))
        defer { server.stop() }

        let client = AdminImageClient(
            configuration: .init(siteOrigin: server.origin, session: AdminImageClient.makeSession())
        )
        let signed = try await client.signUpload(
            filename: "a.jpg", contentType: "image/jpeg", albumValue: "/daily", size: 12, cookie: "session=abc"
        )
        #expect(signed.key == "images/daily/a.jpg")
        let request = try #require(server.receivedRequests.first)
        #expect(request.hasPrefix("POST /api/v1/admin/uploads/sign"))
    }

    @Test("401 时把服务端原话带出来（界面要显示的就是它）")
    func unauthorizedOverHTTP() async throws {
        let server = try LocalHTTPServer(.init(
            status: 401,
            headers: ["Content-Type": "application/json"],
            body: #"{"code":401,"message":"authentication failed"}"#
        ))
        defer { server.stop() }

        let client = AdminImageClient(
            configuration: .init(siteOrigin: server.origin, session: AdminImageClient.makeSession())
        )
        do {
            _ = try await client.listImages(page: 1, pageSize: 24, album: nil, cookie: "session=expired")
            Issue.record("应当抛 401")
        } catch let error as APIError {
            #expect(error.serverMessage == "authentication failed")
        }
    }
}

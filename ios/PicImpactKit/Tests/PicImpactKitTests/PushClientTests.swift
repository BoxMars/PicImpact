import Foundation
import Testing

@testable import PicImpactKit

/// 推送接口客户端的**请求构造**。
///
/// 与 `AdminImageClientTests` 同一个理由：字段名或请求头错一个，服务端就是 400/401，
/// 而 App 侧只会表现为"注册失败、收不到通知"，从现象看不出是哪个字段。
@Suite("推送 · 请求构造")
struct PushClientTests {

    private let origin = URL(string: "https://felina.boxz.dev")!
    private let cookie = "__Secure-pic-impact.session_token=abc.def"

    private let registration = PushDeviceRegistration(
        token: "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
        environment: "sandbox",
        clientId: "3F2A1B4C-5D6E-7F80-9A0B-1C2D3E4F5A6B",
        deviceName: "iPhone 16 Pro",
        systemVersion: "18.0",
        appVersion: "1.2.0+42",
        locale: "zh-Hans-CN"
    )

    @Test("注册请求：POST /api/v1/push/devices，体里逐字段对齐服务端契约")
    func registerRequestShape() throws {
        let request = try PushClient.registerRequest(
            siteOrigin: origin, registration: registration
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://felina.boxz.dev/api/v1/push/devices")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil, "注册是公开接口，不该带会话")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "这个后端没有 bearer 插件")
        // 与 AdminImageClient 同一条既有约定：管理类接口一律绕开系统 HTTP 缓存
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["token"] as? String == registration.token)
        #expect(json["environment"] as? String == "sandbox")
        #expect(json["clientId"] as? String == registration.clientId)
        #expect(json["deviceName"] as? String == "iPhone 16 Pro")
        #expect(json["systemVersion"] as? String == "18.0")
        #expect(json["appVersion"] as? String == "1.2.0+42")
        #expect(json["locale"] as? String == "zh-Hans-CN")

        // 服务端**不接受**这两个字段：userId 只从会话取，bundleId 由服务端配置决定
        #expect(json["userId"] == nil, "永远不要相信客户端报的身份")
        #expect(json["bundleId"] == nil, "bundleId 由服务端的 APNS_BUNDLE_ID 填")
        #expect(json.count == 7, "实际字段：\(json.keys.sorted())")
    }

    @Test("注册请求：可选字段为 nil 时**整个键都不发**（服务端是 .optional()）")
    func registerRequestOmitsNilOptionals() throws {
        let minimal = PushDeviceRegistration(token: registration.token, environment: "production", clientId: "abcdefgh")
        let request = try PushClient.registerRequest(siteOrigin: origin, registration: minimal)

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json.count == 3, "只应有 token / environment / clientId，实际：\(json.keys.sorted())")
        #expect(json["deviceName"] == nil && json["systemVersion"] == nil)
        #expect(json["appVersion"] == nil && json["locale"] == nil)
    }

    @Test("停用请求：DELETE，clientId 是**查询参数**（不是路径段）")
    func unregisterRequestShape() throws {
        let request = try PushClient.unregisterRequest(
            siteOrigin: origin, clientId: "3F2A1B4C-5D6E"
        )

        #expect(request.httpMethod == "DELETE")
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://felina.boxz.dev/api/v1/push/devices?clientId=3F2A1B4C-5D6E")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first?.name == "clientId")
        #expect(components.queryItems?.first?.value == "3F2A1B4C-5D6E")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil, "注册是公开接口，不该带会话")
        #expect(request.httpBody == nil, "DELETE 用查询参数，没有请求体")
    }

    @Test("设备列表请求：GET，带会话 Cookie")
    func listRequestShape() {
        let request = PushClient.listRequest(siteOrigin: origin, cookie: cookie)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://felina.boxz.dev/api/v1/push/devices")
        #expect(request.value(forHTTPHeaderField: "Cookie") == cookie, "诊断接口要看真实注册状态，必须带会话")
    }

    @Test("错误体：原话进 message（invalid_token 等），不编本地文案")
    func errorBodyKeepsServerMessage() {
        let body = Data(#"{"code":400,"message":"invalid_token"}"#.utf8)
        let error = PushClient.apiError(status: 400, body: body)
        #expect(error == .http(status: 400, code: 400, message: "invalid_token"))
        #expect(error.serverMessage == "invalid_token")

        // 体不是 JSON 时也不能崩，只是没有原话
        let broken = PushClient.apiError(status: 500, body: Data("not json".utf8))
        #expect(broken == .http(status: 500, code: nil, message: nil))
    }

    @Test("响应解码：tokenSuffix / enabled / pushEnabled 逐字段")
    func decodesDeviceSummary() throws {
        let json = Data(#"""
        {"code":200,"message":"ok","data":{"id":"d1","deviceName":"iPhone 16 Pro","systemVersion":"18.0",
        "appVersion":"1.2.0+42","environment":"sandbox","enabled":1,"clientId":"abc12345",
        "lastSeenAt":"2026-10-13T12:00:00.000Z","tokenSuffix":"66778899"}}
        """#.utf8)
        struct Envelope: Decodable { let data: PushDeviceSummary }
        let summary = try APIDecoding.makeDecoder().decode(Envelope.self, from: json).data
        #expect(summary.id == "d1")
        #expect(summary.enabled == 1)
        #expect(summary.environment == "sandbox")
        #expect(summary.tokenSuffix == "66778899")
        #expect(summary.lastSeenAt == "2026-10-13T12:00:00.000Z")
    }
}

/// 上传登记要带 `X-Felina-Client-Id`（服务端据此跳过"自己传的不通知自己"，规格 §4.5）。
@Suite("推送 · 上传登记的自传排除头")
@MainActor
struct PushUploadHeaderTests {

    /// 只记录登记时拿到的 clientId，其余步骤给最小可用实现
    final class RecordingAdminAPI: AdminImageAPI, @unchecked Sendable {
        var clientIds: [String?] = []
        /// 2 参版本被调用说明装配漏了 clientId —— 单独记下来，断言里能一眼看出
        var twoArgCalls = 0

        static let signed = SignedUpload(
            key: "images/daily/key.jpg",
            uploadUrl: "https://r2.example.com/images/daily/key.jpg?X=1",
            publicUrl: "https://felina-asset.boxz.dev/images/daily/key.jpg",
            contentType: "image/jpeg",
            expiresInSeconds: 900
        )

        static let registered = RegisteredImage(
            id: "clx1",
            url: "https://felina-asset.boxz.dev/images/daily/key.jpg",
            previewUrl: "https://felina-asset.boxz.dev/images/daily/preview/key.webp",
            width: 1600,
            height: 1000,
            blurhash: "hash",
            albumValue: "/daily",
            show: 0,
            showOnMainpage: 0
        )

        func signUpload(filename: String, contentType: String, albumValue: String, size: Int, cookie: String) async throws -> SignedUpload {
            Self.signed
        }

        func registerImage(_ input: AdminRegisterInput, cookie: String) async throws -> RegisteredImage {
            twoArgCalls += 1
            clientIds.append(nil)
            return Self.registered
        }

        func registerImage(_ input: AdminRegisterInput, cookie: String, clientId: String?) async throws -> RegisteredImage {
            clientIds.append(clientId)
            return Self.registered
        }

        func listImages(page: Int, pageSize: Int, album: String?, cookie: String) async throws -> AdminImagePage {
            AdminImagePage(page: page, pageSize: pageSize, total: 0, hasMore: false, items: [])
        }

        func deleteImage(id: String, cookie: String) async throws {}
        func updateImage(_ update: AdminImageUpdate, cookie: String) async throws {}
        func updateImageShow(id: String, show: Int, cookie: String) async throws {}
        func updateImageAlbum(imageId: String, albumId: String, cookie: String) async throws {}
    }

    final class FakeUploader: FileUploading, @unchecked Sendable {
        func upload(_ data: Data, to url: URL, contentType: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
            onProgress(1)
        }
    }

    @Test("登记请求的 X-Felina-Client-Id 来自注入的 clientId（不是 nil、也不是另一条路径）")
    func passesClientIdToRegister() async throws {
        let api = RecordingAdminAPI()
        let coordinator = UploadCoordinator(
            api: api,
            uploader: FakeUploader(),
            cookie: { "session=abc" },
            clientId: { "3F2A1B4C-5D6E-7F80-9A0B-1C2D3E4F5A6B" }
        )
        coordinator.albumValue = "/daily"
        coordinator.enqueue([UploadCandidate(filename: "a.jpg", contentType: "image/jpeg", data: Data(repeating: 1, count: 64))])
        await coordinator.runPending()

        #expect(coordinator.items[0].isDone)
        #expect(api.twoArgCalls == 0, "走的必须是带 clientId 的那个重载")
        #expect(api.clientIds == ["3F2A1B4C-5D6E-7F80-9A0B-1C2D3E4F5A6B"])
    }

    @Test("真实客户端的登记请求：clientId 非空时才有这个头，为空时逐字节回到旧行为")
    func setsHeaderOnlyWhenPresent() throws {
        let origin = URL(string: "https://felina.boxz.dev")!
        let input = AdminRegisterInput(albumValue: "/daily", url: "https://x/y.jpg", imageName: "y.jpg")

        let withId = try AdminImageClient.registerRequest(
            siteOrigin: origin, input: input, cookie: "session=abc", clientId: "abc12345"
        )
        #expect(withId.value(forHTTPHeaderField: "X-Felina-Client-Id") == "abc12345")

        let without = try AdminImageClient.registerRequest(
            siteOrigin: origin, input: input, cookie: "session=abc", clientId: nil
        )
        #expect(without.value(forHTTPHeaderField: "X-Felina-Client-Id") == nil)

        let empty = try AdminImageClient.registerRequest(
            siteOrigin: origin, input: input, cookie: "session=abc", clientId: ""
        )
        #expect(empty.value(forHTTPHeaderField: "X-Felina-Client-Id") == nil, "空串不发头")
    }
}

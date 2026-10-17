import Foundation

/// 注册 / 更新一台设备（对应 `POST /api/v1/push/devices` 的 body）。
///
/// ⚠️ 字段与服务端 `registerDeviceSchema` 逐字对应，**刻意不含** `userId` 与 `bundleId`：
/// - `userId` 只从会话取 —— 服务端不接受客户端自报身份（单用户站点同样要守住这条，
///   否则鉴权形同虚设）；
/// - `bundleId` 由服务端从 `APNS_BUNDLE_ID` 填，它同时是 APNs 的 `apns-topic`，
///   让客户端指定等于让客户端决定往哪个 topic 推。
///
/// 可选字段为 `nil` 时合成的 `encode(to:)` 走 `encodeIfPresent`，也就是**不发这个键**，
/// 与服务端 `.optional()` 的语义一致。
public struct PushDeviceRegistration: Encodable, Sendable, Equatable {
    public var token: String
    public var environment: String
    public var clientId: String
    public var deviceName: String?
    public var systemVersion: String?
    public var appVersion: String?
    public var locale: String?

    public init(
        token: String,
        environment: String,
        clientId: String,
        deviceName: String? = nil,
        systemVersion: String? = nil,
        appVersion: String? = nil,
        locale: String? = nil
    ) {
        self.token = token
        self.environment = environment
        self.clientId = clientId
        self.deviceName = deviceName
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.locale = locale
    }
}

/// 一台已注册设备（`POST` / `GET /api/v1/push/devices` 返回的 data 里的一条）。
///
/// `tokenSuffix` 是服务端给的 token 后 8 位 —— 诊断够用，又不把"能往这台设备推"的能力
/// 摊在界面上（完整 token 只在库里）。
public struct PushDeviceSummary: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let deviceName: String?
    public let systemVersion: String?
    public let appVersion: String?
    public let environment: String
    public let enabled: Int
    public let clientId: String
    public let lastSeenAt: String?
    public let tokenSuffix: String
}

/// `GET /api/v1/push/devices` 的出参。
///
/// `pushEnabled` 是服务端的两道门（总开关 + APNs 凭据齐备）都过了才为 true ——
/// 用它能把"我这边注册了但服务端没开推送"与"推送发了但没收到"分开。
public struct PushDeviceList: Decodable, Sendable, Equatable {
    public let pushEnabled: Bool
    public let devices: [PushDeviceSummary]
}

/// `DELETE /api/v1/push/devices` 的出参（登出时受影响的行数）
public struct PushDisableResult: Decodable, Sendable, Equatable {
    public let disabled: Int
}

/// 推送设备接口的能力。抽成协议的理由与 `AdminImageAPI` 一样：
/// `PushRegistrar` 的节流/持久化逻辑必须能脱离网络测试。
///
/// 注册与停用**不需要会话**（设备与账号无关，装了 App 就该收到通知）；
/// 只有 `listDevices`（诊断入口）要带 Cookie。
public protocol PushAPI: Sendable {
    func registerDevice(_ registration: PushDeviceRegistration) async throws -> PushDeviceSummary
    /// 停用指定 `clientId` 的设备。返回受影响行数。
    func unregisterDevice(clientId: String) async throws -> Int
    func listDevices(cookie: String) async throws -> PushDeviceList
}

/// `/api/v1/push/*` 客户端。
///
/// 复用 `APIClient.siteOrigin()`（域名只有一处来源）与 `APIError`（错误形状只有一处），
/// 会话走显式 `Cookie` 头 —— 与 `AdminImageClient` / `AuthClient` 完全一致：
/// 这个后端没有 bearer 插件，而且**不能让 URLSession 自己管 Cookie**
/// （三个客户端都显式 `httpCookieStorage = nil` / `httpShouldSetCookies = false`）。
public struct PushClient: PushAPI {

    public struct Configuration: Sendable {
        public var siteOrigin: URL
        public var session: URLSession

        public init(siteOrigin: URL = APIClient.siteOrigin(), session: URLSession = PushClient.makeSession()) {
            self.siteOrigin = siteOrigin
            self.session = session
        }
    }

    public enum Endpoint {
        public static let devices = "/api/v1/push/devices"
    }

    private let configuration: Configuration
    private let decoder: JSONDecoder

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.decoder = APIDecoding.makeDecoder()
    }

    // MARK: - PushAPI

    public func registerDevice(_ registration: PushDeviceRegistration) async throws -> PushDeviceSummary {
        let request = try Self.registerRequest(
            siteOrigin: configuration.siteOrigin, registration: registration
        )
        return try await perform(request, as: PushDeviceSummary.self)
    }

    public func unregisterDevice(clientId: String) async throws -> Int {
        let request = try Self.unregisterRequest(
            siteOrigin: configuration.siteOrigin, clientId: clientId
        )
        return try await perform(request, as: PushDisableResult.self).disabled
    }

    public func listDevices(cookie: String) async throws -> PushDeviceList {
        let request = Self.listRequest(siteOrigin: configuration.siteOrigin, cookie: cookie)
        return try await perform(request, as: PushDeviceList.self)
    }

    // MARK: - 请求构造（纯函数，单测直接断言）

    static func registerRequest(
        siteOrigin: URL,
        registration: PushDeviceRegistration
    ) throws -> URLRequest {
        var request = try jsonRequest(url: url(base: siteOrigin, path: Endpoint.devices), method: "POST")
        request.httpBody = try encode(registration)
        return request
    }

    /// `DELETE /api/v1/push/devices?clientId=<id>` —— `clientId` 是**查询参数**，不是路径段。
    static func unregisterRequest(siteOrigin: URL, clientId: String) throws -> URLRequest {
        guard var components = URLComponents(
            url: url(base: siteOrigin, path: Endpoint.devices),
            resolvingAgainstBaseURL: false
        ) else { throw APIError.invalidURL }

        components.queryItems = [URLQueryItem(name: "clientId", value: clientId)]
        guard let url = components.url else { throw APIError.invalidURL }

        return plainRequest(url: url, method: "DELETE")
    }

    static func listRequest(siteOrigin: URL, cookie: String) -> URLRequest {
        plainRequest(url: url(base: siteOrigin, path: Endpoint.devices), method: "GET", cookie: cookie)
    }

    static func url(base: URL, path: String) -> URL {
        // 与 AdminImageClient 同一条教训：必须 `.absoluteURL`，否则经过 URLComponents 后
        // base 会被丢掉、得到相对 URL，URLSession 直接报 "unsupported URL"
        (URL(string: path, relativeTo: base) ?? base).absoluteURL
    }

    static func encode(_ body: some Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw APIError.decoding("请求体编码失败：\(error)")
        }
    }

    private static func jsonRequest(url: URL, method: String, cookie: String? = nil) throws -> URLRequest {
        var request = plainRequest(url: url, method: method, cookie: cookie)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func plainRequest(url: URL, method: String, cookie: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // 推送接口的响应**不能**走系统 HTTP 缓存：`GET /push/devices` 是诊断接口
        // （"到底注册上了没有"），拿缓存答案等于自欺欺人；POST/DELETE 更不该被缓存。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(APIEnvironment.appVersion, forHTTPHeaderField: "X-App-Version")
        request.setValue(APIEnvironment.platform, forHTTPHeaderField: "X-App-Platform")
        // 会话显式放 Cookie 头（只有诊断用的 `listDevices` 需要；注册/停用是公开接口）
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    // MARK: - 响应

    private struct Envelope<Payload: Decodable & Sendable>: Decodable, Sendable {
        let code: Int
        let data: Payload
    }

    private struct ErrorBody: Decodable, Sendable {
        let code: Int?
        let message: String?
    }

    private func perform<Payload: Decodable & Sendable>(_ request: URLRequest, as: Payload.Type) async throws -> Payload {
        let data = try await performRaw(request)
        do {
            return try decoder.decode(Envelope<Payload>.self, from: data).data
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    @discardableResult
    private func performRaw(_ request: URLRequest) async throws -> Data {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "(nil)"
        // 只记"有没有带 cookie"，绝不记 cookie 的值（见 APILog 的说明）
        let attached = !(request.value(forHTTPHeaderField: "Cookie") ?? "").isEmpty

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await configuration.session.data(for: request)
        } catch {
            APILog.transportError(method, url, error.localizedDescription)
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            APILog.transportError(method, url, "响应不是 HTTP 响应")
            throw APIError.transport("响应不是 HTTP 响应")
        }
        APILog.request(method, url, status: http.statusCode, attachedSession: attached)
        guard (200..<300).contains(http.statusCode) else {
            throw Self.apiError(status: http.statusCode, body: data)
        }
        return data
    }

    /// 错误体是 `{"code":400,"message":"invalid_token"}`。
    /// 只取服务端原话，不带状态码前缀（界面上要显示的是服务端说的话）。
    static func apiError(status: Int, body: Data) -> APIError {
        if let parsed = try? JSONDecoder().decode(ErrorBody.self, from: body),
           let message = parsed.message, !message.isEmpty {
            return .http(status: status, code: parsed.code, message: message)
        }
        return .http(status: status, code: nil, message: nil)
    }

    /// 推送接口专用会话。与 `AdminImageClient.makeSession()` 一致：Cookie 完全由我们显式管理。
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

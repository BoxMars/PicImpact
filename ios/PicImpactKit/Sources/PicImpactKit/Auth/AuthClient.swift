import Foundation

/// 当前登录的账号。
///
/// 只解出界面真正要用的字段：better-auth 还会返回 `emailVerified` / `createdAt` /
/// `updatedAt` 等，`Decodable` 默认会忽略未知字段（与 API 契约里"只做加法"的约定一致），
/// 所以服务端加字段不需要改这里。
public struct AuthUser: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let email: String
    public let name: String?
    public let image: String?

    public init(id: String, email: String, name: String? = nil, image: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.image = image
    }

    /// 界面上展示的名字。昵称为空时退回邮箱 —— 不要显示成空白。
    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return email
    }
}

/// 登录成功的结果：账号 + 服务端下发的会话 Cookie。
public struct AuthSession: Sendable, Equatable {
    public let user: AuthUser
    public let cookies: SessionCookies

    public init(user: AuthUser, cookies: SessionCookies) {
        self.user = user
        self.cookies = cookies
    }
}

/// 认证后端的能力。
///
/// 抽成协议是为了让 `AuthStore` 的状态机可以脱离网络测试：
/// "登录成功写 Keychain / 登出清 Keychain / 恢复会话"这些都是纯状态迁移，
/// 不该因为测试环境连不上 felina.boxz.dev 而无法验证。
public protocol AuthAPI: Sendable {

    /// 邮箱 + 密码登录。
    ///
    /// ⚠️ 这个账号**没有开两步验证**，所以一步就能拿到会话；若将来开了 2FA，
    /// 这里会多一个"需要 TOTP"的分支，届时 `AuthSession` 要能表达"未完成"。
    func signIn(email: String, password: String) async throws -> AuthSession

    /// 用会话 Cookie 查询当前账号。**会话失效时返回 nil**（服务端对未登录请求返回字面量 `null`）。
    func user(sessionCookie: String) async throws -> AuthUser?

    /// 登出（让服务端吊销会话）。本地会话的清理由调用方负责 —— 网络失败也必须能登出。
    func signOut(sessionCookie: String) async throws
}

/// better-auth 的客户端。
///
/// ## 与 `APIClient` 的关系
/// 认证接口挂在站点根的 `/api/auth/*` 下，而 `APIClient` 的 baseURL 是
/// `/api/public/v1` —— 两者**不同源**，不能拿同一个 baseURL 拼。但域名不应该有第二份：
/// 这里用 `APIClient.siteOrigin()` 从公开 API 的 baseURL 反推站点根，
/// 并且复用同一个 `APIError` 枚举，保证界面上的错误呈现只有一种。
public struct AuthClient: AuthAPI {

    public struct Configuration: Sendable {
        /// 站点根，例如 `https://felina.boxz.dev`（**不带** `/api/...` 前缀）
        public var siteOrigin: URL
        public var session: URLSession

        public init(siteOrigin: URL = APIClient.siteOrigin(), session: URLSession = AuthClient.makeSession()) {
            self.siteOrigin = siteOrigin
            self.session = session
        }
    }

    enum Endpoint {
        static let signIn = "/api/auth/sign-in/email"
        static let session = "/api/auth/get-session"
        static let signOut = "/api/auth/sign-out"
    }

    private let configuration: Configuration
    private let decoder: JSONDecoder

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.decoder = APIDecoding.makeDecoder()
    }

    // MARK: - AuthAPI

    public func signIn(email: String, password: String) async throws -> AuthSession {
        let request = try Self.signInRequest(siteOrigin: configuration.siteOrigin, email: email, password: password)
        let (data, response) = try await perform(request)

        let payload: SignInResponse
        do {
            payload = try decoder.decode(SignInResponse.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }

        let cookies = Self.sessionCookies(from: response, fallbackDomain: configuration.siteOrigin.host)
        // 没有 Cookie 就说明"登录成功"是假的：后续所有管理请求都会是未登录。
        // 宁可在这里明确报错，也不要进入一个点了什么都提示未登录的管理页。
        guard !cookies.isEmpty else {
            throw APIError.decoding("登录成功但服务端没有下发会话 Cookie")
        }
        return AuthSession(user: payload.user, cookies: cookies)
    }

    public func user(sessionCookie: String) async throws -> AuthUser? {
        let request = Self.sessionRequest(siteOrigin: configuration.siteOrigin, cookieHeader: sessionCookie)
        let (data, _) = try await perform(request)
        // 未登录时服务端返回字面量 `null`，解不出 `SessionEnvelope` 就当作"没有会话"。
        // 这里刻意不用 `try` + 抛错：契约变化时"当作未登录"比"整个 App 起不来"更合适。
        guard let envelope = try? decoder.decode(SessionEnvelope.self, from: data) else { return nil }
        return envelope.user
    }

    public func signOut(sessionCookie: String) async throws {
        let request = Self.signOutRequest(siteOrigin: configuration.siteOrigin, cookieHeader: sessionCookie)
        _ = try await perform(request)
    }

    // MARK: - 请求构造（纯函数，单元测试直接断言）

    static func signInRequest(siteOrigin: URL, email: String, password: String) throws -> URLRequest {
        var request = URLRequest(url: url(base: siteOrigin, path: Endpoint.signIn))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try fillHeaders(request, body: SignInBody(email: email, password: password))
    }

    /// 会话查询。
    ///
    /// ⚠️ **必须是 GET**：better-auth 的 `/get-session` 不接受 POST，
    /// 用 POST 会得到 404/405，表现为"本地有 Cookie 却总被判定为未登录"。
    static func sessionRequest(siteOrigin: URL, cookieHeader: String) -> URLRequest {
        var request = URLRequest(url: url(base: siteOrigin, path: Endpoint.session))
        request.httpMethod = "GET"
        return fillCommonHeaders(request, cookieHeader: cookieHeader)
    }

    static func signOutRequest(siteOrigin: URL, cookieHeader: String) -> URLRequest {
        var request = URLRequest(url: url(base: siteOrigin, path: Endpoint.signOut))
        request.httpMethod = "POST"
        return fillCommonHeaders(request, cookieHeader: cookieHeader)
    }

    /// 站点根 + 路径拼成 URL。
    ///
    /// 不用 `appendingPathComponent`：它会把 `"/api/auth/..."` 整体当成一个路径段做百分号转义
    /// （斜杠变成 `%2F`），拼出来是个 404。用 `relativeTo` 才是"相对站点根"的正确语义。
    static func url(base: URL, path: String) -> URL {
        URL(string: path, relativeTo: base) ?? base
    }

    // MARK: - 错误与 Cookie

    /// 把 better-auth 的错误体翻成统一的 `APIError`。
    ///
    /// 服务端实测（错误密码）：`401 {"message":"Invalid email or password","code":"INVALID_EMAIL_OR_PASSWORD"}`。
    ///
    /// ## 为什么只留 `message`，丢掉 `code`
    /// 1. `APIError.http` 的 `code` 是 `Int?`（公开 API 的信封用数字 code），而 better-auth
    ///    给的是**字符串** code，塞不进去。
    /// 2. 就算塞得进去也不该塞：`INVALID_EMAIL_OR_PASSWORD` 是内部标识，
    ///    界面上要显示的是服务端的原话（"Invalid email or password"），
    ///    带上 `服务端返回 401：` 与括号里的 code 只会让页面看起来像调试面板。
    ///    需要技术细节时看 `APIError.errorDescription`（日志/测试用），而不是界面。
    static func apiError(status: Int, body: Data) -> APIError {
        if let parsed = try? JSONDecoder().decode(AuthErrorBody.self, from: body),
           let message = parsed.message, !message.isEmpty {
            return .http(status: status, code: nil, message: message)
        }
        // 解不出 JSON（例如网关直接返回 HTML 错误页）时也要能区分出"是 HTTP 层失败"，
        // 但**不把正文塞进 message**：那多半是一整页 HTML，不该出现在界面上。
        return .http(status: status, code: nil, message: nil)
    }

    /// 从登录响应里取出会话 Cookie。
    ///
    /// ## 为什么读响应头，而不是读 `HTTPCookieStorage`
    /// 原本的做法依赖 URLSession 把 `Set-Cookie` 收进 `httpCookieStorage`。实测
    /// （`AuthClientHTTPTests` 里的本地 HTTP 服务）**那个存储在 macOS 的测试进程里始终为空**，
    /// 连 `URLSession.shared` 也一样 —— 也就是说这条路径根本无法验证。
    /// 而它一旦不生效，症状是"登录成功但马上又像没登录"，不报任何错。
    ///
    /// 所以改成直接解析响应头：确定、可测，且不依赖 URLSession 内部的 Cookie 行为。
    /// 多个 `Set-Cookie` 会被 Foundation 用 ", " 拼成一个字符串，拆解见
    /// `SessionCookies.splitSetCookieHeader`。
    static func sessionCookies(from response: HTTPURLResponse, fallbackDomain: String?) -> SessionCookies {
        let header = response.value(forHTTPHeaderField: "Set-Cookie")
            ?? (response.allHeaderFields["Set-Cookie"] as? String)
            ?? ""
        let domain = response.url?.host ?? fallbackDomain ?? ""
        return SessionCookies(responseHeader: header, domain: domain)
    }

    /// 认证专用会话。
    ///
    /// ## 为什么把 Cookie 交给 URLSession 管理反而关掉
    /// 会话 Cookie 由我们自己存（Keychain）与带（显式 `Cookie` 头），
    /// 所以这里把 `httpCookieStorage` 置空、`httpShouldSetCookies` 关掉，
    /// 让"请求带了哪些 Cookie"完全由 `AuthStore` 决定 —— 不掺入 URLSession 的隐式行为。
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    // MARK: - 内部

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await configuration.session.data(for: request)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("响应不是 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.apiError(status: http.statusCode, body: data)
        }
        return (data, http)
    }

    private static func fillHeaders(_ request: URLRequest, body: some Encodable) throws -> URLRequest {
        var request = fillCommonHeaders(request, cookieHeader: nil)
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw APIError.decoding("请求体编码失败：\(error)")
        }
        return request
    }

    private static func fillCommonHeaders(_ request: URLRequest, cookieHeader: String?) -> URLRequest {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 便于服务端统计仍在使用的旧版本（与 APIClient 一致）
        request.setValue(APIEnvironment.appVersion, forHTTPHeaderField: "X-App-Version")
        request.setValue(APIEnvironment.platform, forHTTPHeaderField: "X-App-Platform")
        // 会话走 Cookie 头：这个后端**没有** bearer 插件，Bearer token 那条路是不通的
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        return request
    }
}

/// 登录请求体。字段名与服务端契约一一对应（缺字段时服务端会以 `[body.email]` 报 400）。
struct SignInBody: Encodable, Sendable {
    let email: String
    let password: String
}

/// 登录成功响应：`{ "token": "...", "user": { ... } }`（token 我们不用，走 Cookie 会话）
private struct SignInResponse: Decodable, Sendable {
    let user: AuthUser
}

/// `GET /get-session` 的响应：`{ "session": { ... }, "user": { ... } }`
private struct SessionEnvelope: Decodable, Sendable {
    let user: AuthUser
}

/// better-auth 的错误体。
///
/// ⚠️ `code` 故意**不解出来**：它是内部标识（`INVALID_EMAIL_OR_PASSWORD`），
/// 界面上要显示的是服务端的原话，不需要它。`Decodable` 会忽略未知字段，所以
/// 服务端继续带这个字段没有任何影响。
struct AuthErrorBody: Decodable, Sendable {
    let message: String?
}

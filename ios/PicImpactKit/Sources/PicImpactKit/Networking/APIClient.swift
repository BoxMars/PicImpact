import Foundation

/// 公开 API v1 的错误。
///
/// 刻意把 `http` 与 `decoding` 分开：前者通常意味着服务端/网络问题，
/// 后者意味着**契约被破坏**（服务端改了字段而 App 没跟上）——
/// 这两种情况在排查时应被区别对待，混成一个 error 会浪费大量时间。
public enum APIError: Error, Sendable, Equatable {
    case invalidURL
    case http(status: Int, code: Int?, message: String?)
    case transport(String)
    case decoding(String)
    case notFound
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请求地址无效"
        case let .http(status, code, message):
            return "服务端返回 \(status)" + (message.map { "：\($0)" } ?? "") + (code.map { "（code \($0)）" } ?? "")
        case let .transport(detail):
            return "网络错误：\(detail)"
        case let .decoding(detail):
            return "响应解析失败（可能服务端契约已变更）：\(detail)"
        case .notFound:
            return "图片不存在或未公开"
        }
    }
}

/// 公开 API v1 客户端。
///
/// 契约见 `docs/superpowers/api/public-api-v1.md`。
/// 服务端对该版本承诺**只做加法**，因此这里解码时容忍未知字段（`Decodable` 默认行为）。
public struct APIClient: Sendable {

    public struct Configuration: Sendable {
        public var baseURL: URL
        public var session: URLSession

        public init(baseURL: URL, session: URLSession = .shared) {
            self.baseURL = baseURL
            self.session = session
        }
    }

    public static let productionBaseURL = URL(string: "https://felina.boxz.dev/api/public/v1")!

    private let configuration: Configuration
    private let decoder: JSONDecoder

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.decoder = APIDecoding.makeDecoder()
    }

    public init(baseURL: URL = APIClient.productionBaseURL, session: URLSession = .shared) {
        self.init(configuration: Configuration(baseURL: baseURL, session: session))
    }

    // MARK: - 端点

    /// 站点配置 + 能力协商。**必须先调用它**。
    public func siteConfig() async throws -> SiteConfigDTO {
        try await get("/config")
    }

    public func albums() async throws -> [AlbumDTO] {
        try await get("/albums")
    }

    public func tags() async throws -> [String] {
        try await get("/tags")
    }

    public func filters(album: String? = nil) async throws -> FiltersDTO {
        var query: [String: String] = [:]
        if let album, !album.isEmpty { query["album"] = album }
        return try await get("/filters", query: query)
    }

    /// 图片列表。
    /// - Parameters:
    ///   - album: 相册 value（形如 `/daily`）。传 nil 即首页
    ///   - tag: 标签。**优先级高于 album**（与 Web 端一致）
    ///   - page: 页码，从 1 开始
    public func images(
        album: String? = nil,
        tag: String? = nil,
        camera: String? = nil,
        lens: String? = nil,
        page: Int = 1
    ) async throws -> ImagePageDTO {
        var query: [String: String] = ["page": String(max(1, page))]
        if let tag, !tag.isEmpty {
            query["tag"] = tag
        } else if let album, !album.isEmpty {
            query["album"] = album
        }
        if let camera, !camera.isEmpty { query["camera"] = camera }
        if let lens, !lens.isEmpty { query["lens"] = lens }
        return try await get("/images", query: query)
    }

    /// 单张图片（深链接场景：不必先拉列表）
    public func image(id: String) async throws -> ImageDTO {
        try await get("/images/\(id)")
    }

    // MARK: - 通用请求

    private func get<Payload: Decodable & Sendable>(
        _ path: String,
        query: [String: String] = [:]
    ) async throws -> Payload {
        guard var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 便于服务端统计仍在使用的旧版本（API 文档 §4 的弃用流程需要它）
        request.setValue(APIEnvironment.appVersion, forHTTPHeaderField: "X-App-Version")
        request.setValue(APIEnvironment.platform, forHTTPHeaderField: "X-App-Platform")

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
            // 尽力从信封里取出服务端的错误信息，取不到也不影响抛错
            let envelope = try? decoder.decode(ApiEnvelope<EmptyPayload>.self, from: data)
            if http.statusCode == 404 { throw APIError.notFound }
            throw APIError.http(
                status: http.statusCode,
                code: envelope?.code,
                message: envelope?.message
            )
        }

        do {
            let envelope = try decoder.decode(ApiEnvelope<Payload>.self, from: data)
            return envelope.data
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}

/// 错误响应里的 `data` 可能是 null
struct EmptyPayload: Decodable, Sendable {}

enum APIEnvironment {
    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version)+\(build)"
    }

    static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }
}

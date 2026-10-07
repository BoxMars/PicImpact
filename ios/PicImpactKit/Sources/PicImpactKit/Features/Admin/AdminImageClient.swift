import Foundation

/// 预签名上传的签发结果（对应 `POST /api/v1/admin/uploads/sign` 的 data）
public struct SignedUpload: Decodable, Sendable, Equatable {
    public let key: String
    public let uploadUrl: String
    public let publicUrl: String
    public let contentType: String
    public let expiresInSeconds: Int

    public var uploadURL: URL? { URL(string: uploadUrl) }
}

/// 登记成功后的行（对应 `POST /api/v1/admin/images` 的 data）
public struct RegisteredImage: Decodable, Sendable, Equatable {
    public let id: String
    public let url: String
    public let previewUrl: String
    public let width: Int
    public let height: Int
    public let blurhash: String
    public let albumValue: String
    public let show: Int
    public let showOnMainpage: Int
}

/// 管理列表里的一条（对应 `GET /api/v1/admin/images` 的 items）
public struct AdminImageSummary: Decodable, Sendable, Equatable, Identifiable {
    public struct EXIFSummary: Decodable, Sendable, Equatable {
        public let model: String
        public let lensModel: String
        public let dataTime: String
    }

    public let id: String
    public let url: String
    public let previewUrl: String
    public let title: String
    public let detail: String
    public let width: Int
    public let height: Int
    public let show: Int
    public let showOnMainpage: Int
    public let labels: [String]
    public let createdAt: Date?
    public let albumValue: String
    public let albumName: String
    public let exif: EXIFSummary

    /// 列表一律用预览图（Web 也是这个策略：`components/admin/list/list-image.tsx`）
    public var thumbnailURL: URL? { URL(string: previewUrl.isEmpty ? url : previewUrl) }
}

/// 管理列表的一页
public struct AdminImagePage: Decodable, Sendable, Equatable {
    public let page: Int
    public let pageSize: Int
    public let total: Int
    public let hasMore: Bool
    public let items: [AdminImageSummary]
}

/// 登记请求体。字段与契约一一对应；**不含** `preview_url` / `blurhash` / `show`（服务端自己算/写死）。
public struct AdminRegisterInput: Encodable, Sendable, Equatable {
    public var albumValue: String
    public var url: String
    public var imageName: String
    public var title: String
    public var detail: String
    public var labels: [String]
    public var exif: [String: JSONValue]
    public var lat: String
    public var lon: String
    public var width: Int
    public var height: Int
    public var type: Int

    public init(
        albumValue: String,
        url: String,
        imageName: String,
        title: String = "",
        detail: String = "",
        labels: [String] = [],
        exif: [String: JSONValue] = [:],
        lat: String = "",
        lon: String = "",
        width: Int = 0,
        height: Int = 0,
        type: Int = 1
    ) {
        self.albumValue = albumValue
        self.url = url
        self.imageName = imageName
        self.title = title
        self.detail = detail
        self.labels = labels
        // 空字典也要发：服务端 `exif` 是可选字段，发 `{}` 与不发等价，但显式一点更好排查
        self.exif = exif
        self.lat = lat
        self.lon = lon
        self.width = width
        self.height = height
        self.type = type
    }
}

/// 编辑请求体（对应 `PUT /api/v1/images/update`）。
///
/// ⚠️ 三个字段（`url` / `width` / `height`）是服务端的**硬校验**，必须回传；
/// 其余字段只发要改的那几个即可 —— 服务端的 `updateImage()` 走 Prisma，
/// 没出现的键是 `undefined`，等于"不改这一列"。
///
/// ⚠️ **刻意不发 `sort`**：服务端 `updateImage()` 里有 `if (!image.sort || image.sort < 0) image.sort = 0`，
/// 也就是说不发就等于把它写成 0。生产库里现在**全部**是 0，所以无影响；如果以后启用网页后台的
/// 排序功能，需要让管理列表接口多返回一个 `sort` 字段，再由 App 原样回传（见计划文档）。
public struct AdminImageUpdate: Encodable, Sendable, Equatable {
    public var id: String
    public var url: String
    public var width: Int
    public var height: Int
    public var title: String?
    public var detail: String?
    public var labels: [String]?

    public init(
        id: String,
        url: String,
        width: Int,
        height: Int,
        title: String? = nil,
        detail: String? = nil,
        labels: [String]? = nil
    ) {
        self.id = id
        self.url = url
        self.width = width
        self.height = height
        self.title = title
        self.detail = detail
        self.labels = labels
    }
}

/// 管理端接口的能力。抽成协议是为了让上传状态机可以脱离网络测试。
public protocol AdminImageAPI: Sendable {
    func signUpload(
        filename: String,
        contentType: String,
        albumValue: String,
        size: Int,
        cookie: String
    ) async throws -> SignedUpload

    func registerImage(_ input: AdminRegisterInput, cookie: String) async throws -> RegisteredImage

    func listImages(page: Int, pageSize: Int, album: String?, cookie: String) async throws -> AdminImagePage

    func deleteImage(id: String, cookie: String) async throws

    /// 改标题 / 详情 / 标签（`PUT /api/v1/images/update`）
    func updateImage(_ update: AdminImageUpdate, cookie: String) async throws
    /// 显示 / 隐藏（`PUT /api/v1/images/update-show`，0＝显示，1＝隐藏）
    func updateImageShow(id: String, show: Int, cookie: String) async throws
    /// 换相册（`PUT /api/v1/images/update-Album`，服务端收的是相册 **id**）
    func updateImageAlbum(imageId: String, albumId: String, cookie: String) async throws
}

/// `/api/v1/admin/*` 客户端。
///
/// 复用 `APIClient.siteOrigin()`（域名只有一处来源）与 `APIError`（错误形状只有一处），
/// 会话走显式 `Cookie` 头（与 `AuthClient` 一致：这个后端没有 bearer 插件）。
public struct AdminImageClient: AdminImageAPI {

    public struct Configuration: Sendable {
        public var siteOrigin: URL
        public var session: URLSession

        public init(siteOrigin: URL = APIClient.siteOrigin(), session: URLSession = AdminImageClient.makeSession()) {
            self.siteOrigin = siteOrigin
            self.session = session
        }
    }

    public enum Endpoint {
        public static let sign = "/api/v1/admin/uploads/sign"
        public static let images = "/api/v1/admin/images"
        /// 编辑类接口在 `/api/v1/images/*`（与网页后台同一个 app），不在 `/admin` 下
        public static let update = "/api/v1/images/update"
        public static let updateShow = "/api/v1/images/update-show"
        public static let updateAlbum = "/api/v1/images/update-Album"
    }

    private let configuration: Configuration
    private let decoder: JSONDecoder

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.decoder = APIDecoding.makeDecoder()
    }

    /// 默认每页条数（与服务端默认一致，客户端显式传以免两边默认值漂移）
    public static let defaultPageSize = 24

    // MARK: - AdminImageAPI

    public func signUpload(
        filename: String,
        contentType: String,
        albumValue: String,
        size: Int,
        cookie: String
    ) async throws -> SignedUpload {
        let request = try Self.signRequest(
            siteOrigin: configuration.siteOrigin,
            filename: filename,
            contentType: contentType,
            albumValue: albumValue,
            size: size,
            cookie: cookie
        )
        return try await perform(request, as: SignedUpload.self)
    }

    public func registerImage(_ input: AdminRegisterInput, cookie: String) async throws -> RegisteredImage {
        let request = try Self.registerRequest(siteOrigin: configuration.siteOrigin, input: input, cookie: cookie)
        return try await perform(request, as: RegisteredImage.self)
    }

    public func listImages(
        page: Int,
        pageSize: Int = AdminImageClient.defaultPageSize,
        album: String?,
        cookie: String
    ) async throws -> AdminImagePage {
        let request = try Self.listRequest(
            siteOrigin: configuration.siteOrigin,
            page: page,
            pageSize: pageSize,
            album: album,
            cookie: cookie
        )
        return try await perform(request, as: AdminImagePage.self)
    }

    public func deleteImage(id: String, cookie: String) async throws {
        let request = Self.deleteRequest(siteOrigin: configuration.siteOrigin, id: id, cookie: cookie)
        _ = try await performRaw(request)
    }

    public func updateImage(_ update: AdminImageUpdate, cookie: String) async throws {
        let request = try Self.updateRequest(siteOrigin: configuration.siteOrigin, update: update, cookie: cookie)
        _ = try await performRaw(request)
    }

    public func updateImageShow(id: String, show: Int, cookie: String) async throws {
        let request = try Self.updateShowRequest(siteOrigin: configuration.siteOrigin, id: id, show: show, cookie: cookie)
        _ = try await performRaw(request)
    }

    public func updateImageAlbum(imageId: String, albumId: String, cookie: String) async throws {
        let request = try Self.updateAlbumRequest(
            siteOrigin: configuration.siteOrigin, imageId: imageId, albumId: albumId, cookie: cookie
        )
        _ = try await performRaw(request)
    }

    // MARK: - 请求构造（纯函数，单测直接断言）

    static func signRequest(
        siteOrigin: URL,
        filename: String,
        contentType: String,
        albumValue: String,
        size: Int,
        cookie: String
    ) throws -> URLRequest {
        var request = try jsonRequest(url: url(base: siteOrigin, path: Endpoint.sign), method: "POST", cookie: cookie)
        request.httpBody = try encode(SignBody(filename: filename, contentType: contentType, albumValue: albumValue, size: size))
        return request
    }

    static func registerRequest(siteOrigin: URL, input: AdminRegisterInput, cookie: String) throws -> URLRequest {
        var request = try jsonRequest(url: url(base: siteOrigin, path: Endpoint.images), method: "POST", cookie: cookie)
        request.httpBody = try encode(input)
        return request
    }

    static func listRequest(
        siteOrigin: URL,
        page: Int,
        pageSize: Int,
        album: String?,
        cookie: String
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: url(base: siteOrigin, path: Endpoint.images),
            resolvingAgainstBaseURL: false
        ) else { throw APIError.invalidURL }

        var query = [
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "pageSize", value: String(max(1, pageSize))),
        ]
        if let album, !album.isEmpty {
            query.append(URLQueryItem(name: "album", value: album))
        }
        components.queryItems = query
        guard let url = components.url else { throw APIError.invalidURL }

        return plainRequest(url: url, method: "GET", cookie: cookie)
    }

    static func deleteRequest(siteOrigin: URL, id: String, cookie: String) -> URLRequest {
        plainRequest(
            url: url(base: siteOrigin, path: "\(Endpoint.images)/\(id)"),
            method: "DELETE",
            cookie: cookie
        )
    }

    static func updateRequest(siteOrigin: URL, update: AdminImageUpdate, cookie: String) throws -> URLRequest {
        var request = try jsonRequest(url: url(base: siteOrigin, path: Endpoint.update), method: "PUT", cookie: cookie)
        request.httpBody = try encode(update)
        return request
    }

    static func updateShowRequest(siteOrigin: URL, id: String, show: Int, cookie: String) throws -> URLRequest {
        var request = try jsonRequest(url: url(base: siteOrigin, path: Endpoint.updateShow), method: "PUT", cookie: cookie)
        request.httpBody = try encode(ShowBody(id: id, show: show))
        return request
    }

    static func updateAlbumRequest(siteOrigin: URL, imageId: String, albumId: String, cookie: String) throws -> URLRequest {
        var request = try jsonRequest(url: url(base: siteOrigin, path: Endpoint.updateAlbum), method: "PUT", cookie: cookie)
        request.httpBody = try encode(AlbumBody(imageId: imageId, albumId: albumId))
        return request
    }

    static func url(base: URL, path: String) -> URL {
        // ⚠️ 必须 `.absoluteURL`：`URL(string:relativeTo:)` 出来的 URL **带着 baseURL**，
        // 一旦再经过 `URLComponents(url:resolvingAgainstBaseURL: false)` 取 `.url`，
        // base 会被丢掉、得到一个**相对** URL，URLSession 直接报 "unsupported URL"
        // （实测：后台列表整个拉不出来，界面只显示一句看不懂的 "unsupported URL"）。
        (URL(string: path, relativeTo: base) ?? base).absoluteURL
    }

    static func encode(_ body: some Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw APIError.decoding("请求体编码失败：\(error)")
        }
    }

    private static func jsonRequest(url: URL, method: String, cookie: String) throws -> URLRequest {
        var request = plainRequest(url: url, method: method, cookie: cookie)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func plainRequest(url: URL, method: String, cookie: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // 管理接口一律不走系统 HTTP 缓存。实测线上 `/api/v1/admin/images` 的 GET 响应
        // 会被 URLCache 存下来（在模拟器的 Cache.db 里能看到），于是"刚传完照片、
        // 重新打开后台还是旧列表"。这里由客户端自己保证每次请求都打到服务端。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(APIEnvironment.appVersion, forHTTPHeaderField: "X-App-Version")
        request.setValue(APIEnvironment.platform, forHTTPHeaderField: "X-App-Platform")
        // 会话显式放 Cookie 头（这个后端没有 bearer 插件）
        if !cookie.isEmpty {
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
        return data
    }

    /// 管理接口的错误体是 `{"code":401,"message":"authentication failed"}`。
    /// 只取服务端原话，不带状态码前缀（界面上要显示的是服务端说的话）。
    static func apiError(status: Int, body: Data) -> APIError {
        if let parsed = try? JSONDecoder().decode(ErrorBody.self, from: body),
           let message = parsed.message, !message.isEmpty {
            return .http(status: status, code: nil, message: message)
        }
        return .http(status: status, code: nil, message: nil)
    }

    /// 管理接口专用会话。与 `AuthClient.makeSession()` 一致：Cookie 完全由我们显式管理。
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

/// `PUT /images/update-show` 的请求体
struct ShowBody: Encodable, Sendable {
    let id: String
    let show: Int
}

/// `PUT /images/update-Album` 的请求体（注意是相册的 **id**，不是 `album_value`）
struct AlbumBody: Encodable, Sendable {
    let imageId: String
    let albumId: String
}

/// 签发请求体（字段名与服务端 `signRequestSchema` 一一对应）
struct SignBody: Encodable, Sendable {
    let filename: String
    let contentType: String
    let albumValue: String
    let size: Int
}

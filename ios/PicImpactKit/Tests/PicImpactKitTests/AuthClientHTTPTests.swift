import Foundation
import Testing

@testable import PicImpactKit

#if canImport(Darwin)
import Darwin
#endif

/// 一个只按固定脚本应答的极小 HTTP 服务（真实 socket，不是打桩）。
///
/// ## 为什么要真起一个服务，而不是用 `URLProtocol` 打桩
/// 本批次最容易出错、也最难发现的一步是"登录响应里的 `Set-Cookie` 有没有真的进入
/// `URLSession` 的 Cookie 存储"，错了的表现是**登录成功但马上又像没登录**，没有任何报错。
/// 而 `URLProtocol` 只是协议栈里的一层，它的响应不保证会被上层的 Cookie 处理接管 ——
/// 用它测出来的"取到 Cookie"可能是假的。所以这里用真实 socket 起一个 HTTP 服务，
/// 让 URLSession 完整走一遍它自己的 Cookie 逻辑。
final class LocalHTTPServer: @unchecked Sendable {

    struct Response {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: String = "{}"

        init(status: Int = 200, headers: [String: String] = [:], body: String = "{}") {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    let port: UInt16

    private let listenFD: Int32
    private let response: Response
    private let lock = NSLock()
    private var captured: [String] = []

    /// 收到的原始请求（请求行 + 头 + 体），用来断言"App 真的这样发了请求"
    var receivedRequests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    init(_ response: Response) throws {
        self.response = response

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // 让内核分配一个空闲端口，避免测试之间抢端口
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }

        self.port = UInt16(bigEndian: actual.sin_port)
        self.listenFD = fd
        Thread.detachNewThread { [self] in serveForever() }
    }

    var origin: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func stop() {
        close(listenFD)
    }

    deinit { close(listenFD) }

    // MARK: - 内部

    private func serveForever() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return } // stop() 关掉监听 fd 之后 accept 会失败

            lock.lock()
            captured.append(readRequest(client))
            lock.unlock()

            writeResponse(to: client)
            close(client)
        }
    }

    private func readRequest(_ client: Int32) -> String {
        // 头部与请求体都要收：测试要断言的不只是"方法/路径对不对"，
        // 还有"登录请求体里确实带了 email 与 password"。
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        var collected = Data()
        var expectedLength = Int.max

        while collected.count < expectedLength, collected.count < 64 * 1024 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            collected.append(contentsOf: buffer[0..<count])

            guard let headerEnd = collected.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: collected[..<headerEnd.lowerBound], as: UTF8.self)
            let contentLength = head
                .split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                } ?? 0
            expectedLength = headerEnd.upperBound + contentLength
        }

        return String(decoding: collected, as: UTF8.self)
    }

    private func writeResponse(to client: Int32) {
        let body = Data(response.body.utf8)
        var head = "HTTP/1.1 \(response.status) \(Self.reason(for: response.status))\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(body)

        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = send(client, base.advanced(by: sent), raw.count - sent, 0)
                guard count > 0 else { return }
                sent += count
            }
        }
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 401: return "Unauthorized"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

/// 登录成功的 HTTP 路径：请求真的发出去、`Set-Cookie` 真的被 URLSession 收下、
/// 错误真的被翻成统一的 `APIError`。
///
/// 这一组补上了"纯逻辑单测"够不到的那一段 —— 也是**用真实密码登录**之外
/// 唯一能覆盖"登录成功"路径的手段（我们没有密码，也不该去找）。
@Suite("认证 · 登录成功的 HTTP 路径（本地服务）", .serialized)
struct AuthClientHTTPTests {

    /// 用 `AuthClient.makeSession()`：独立 Cookie 存储，与生产走的是同一条路径
    private func makeClient(_ server: LocalHTTPServer) -> AuthClient {
        AuthClient(configuration: .init(siteOrigin: server.origin, session: AuthClient.makeSession()))
    }

    @Test("登录成功：会话 Cookie 从响应头里被解析出来（含被拼在一起的多条 Set-Cookie）")
    func signInCapturesSessionCookie() async throws {
        let server = try LocalHTTPServer(.init(
            status: 200,
            headers: [
                "Content-Type": "application/json",
                // 刻意按**实测形态**给：多条 Set-Cookie 会被 URLSession 拼成一条，
                // 且第一条的 Expires 自身带逗号 —— 拆分逻辑错了这里就会露出来
                "Set-Cookie": "better-auth.session_token=tok123; Path=/; HttpOnly; Secure; SameSite=Lax; "
                    + "Expires=Wed, 14 Oct 2030 08:23:11 GMT, "
                    + "better-auth.session_data=data456; Path=/; HttpOnly; Secure; Max-Age=300, "
                    + "__better-auth-cookie-store=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
            ],
            body: #"{"token":"ignored","user":{"id":"u_1","email":"someone@example.com","name":"大福"}}"#
        ))
        defer { server.stop() }

        let session = try await makeClient(server).signIn(email: "someone@example.com", password: "pw")

        #expect(session.user.email == "someone@example.com")
        #expect(session.user.displayName == "大福")
        // 两条会话 Cookie 都要在；清除用的那条（不含 session、且已过期）不能混进来
        #expect(
            session.cookies.headerValue() == "better-auth.session_token=tok123; better-auth.session_data=data456"
        )
        #expect(session.cookies.cookies.allSatisfy { !$0.isExpired(at: Date()) })

        // 请求确实打到了 sign-in 路径，且带上了凭据
        let request = try #require(server.receivedRequests.first)
        #expect(request.hasPrefix("POST /api/auth/sign-in/email HTTP/1.1"))
        #expect(request.contains("someone@example.com"))
        #expect(request.contains("pw"))
    }

    @Test("会话查询：GET 到 /api/auth/get-session，并把 Cookie 放进请求头")
    func sessionQueryUsesGetWithCookie() async throws {
        let server = try LocalHTTPServer(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"session":{"id":"s_1"},"user":{"id":"u_1","email":"someone@example.com"}}"#
        ))
        defer { server.stop() }

        let user = try await makeClient(server).user(sessionCookie: "better-auth.session_token=abc123")

        #expect(user?.email == "someone@example.com")
        let request = try #require(server.receivedRequests.first)
        #expect(request.hasPrefix("GET /api/auth/get-session HTTP/1.1"))
        #expect(request.localizedCaseInsensitiveContains("Cookie: better-auth.session_token=abc123"))
    }

    @Test("服务端返回 null（会话已失效）时判定为没有登录")
    func nullSessionMeansSignedOut() async throws {
        let server = try LocalHTTPServer(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: "null"
        ))
        defer { server.stop() }

        let user = try await makeClient(server).user(sessionCookie: "better-auth.session_token=stale")
        #expect(user == nil)
    }

    @Test("401：错误被翻成统一的 APIError，且保留服务端原文")
    func serverErrorBecomesAPIError() async throws {
        let server = try LocalHTTPServer(.init(
            status: 401,
            headers: ["Content-Type": "application/json"],
            body: #"{"message":"Invalid email or password","code":"INVALID_EMAIL_OR_PASSWORD"}"#
        ))
        defer { server.stop() }

        await #expect(throws: APIError.self) {
            _ = try await makeClient(server).signIn(email: "someone@example.com", password: "wrong")
        }
    }

    @Test("登录响应里没有会话 Cookie 时必须报错，而不是假装登录成功")
    func missingCookieIsAnError() async throws {
        let server = try LocalHTTPServer(.init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"user":{"id":"u_1","email":"someone@example.com"}}"#
        ))
        defer { server.stop() }

        await #expect(throws: APIError.self) {
            _ = try await makeClient(server).signIn(email: "someone@example.com", password: "pw")
        }
    }
}

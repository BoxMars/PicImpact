import Foundation

/// 一条会话 Cookie 的纯值表示。
///
/// ## 为什么不直接用 `HTTPCookie`
/// 1. `HTTPCookie` 是 `NSObject` 子类，**不满足 `Sendable`** —— 在 Swift 6 严格并发下
///    不能跨 actor 传递，也没法安全地存进 `@Observable` 状态里。
/// 2. 它不能直接 `Codable`，而会话必须**持久化到 Keychain** 才能在下次启动时恢复登录态。
///
/// 于是这里定义一个纯值类型做中转：`HTTPCookie` → `AuthCookie` → JSON → Keychain。
/// 解析和拼装都能在单元测试里直接断言，不必真的发一次请求。
public struct AuthCookie: Codable, Sendable, Equatable, Identifiable {

    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expiresAt: Date?
    public let isSecure: Bool
    public let isHTTPOnly: Bool

    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expiresAt: Date? = nil,
        isSecure: Bool = false,
        isHTTPOnly: Bool = false
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }

    /// 唯一标识。同一 domain + path + name 在 Cookie 语义里就是同一条。
    public var id: String { "\(domain)\(path)\(name)" }

    /// 放进 `Cookie` 请求头的那一段（`name=value`）
    public var headerField: String { "\(name)=\(value)" }

    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    // MARK: - 解析

    /// 解析一条 `Set-Cookie` 头的原文。
    ///
    /// 为什么不用 `HTTPCookie(properties:)`：那个初始化器要的是**已经拆好**的属性字典，
    /// 而 URLSession 给到我们手上的（以及手工测试时用的）正是原始头文本 ——
    /// 拆解这一步无论如何都得自己做，那就把它做成可测的纯函数。
    ///
    /// 按 `;` 切分是安全的：`Expires=Thu, 01 Jan 1970 ...` 里虽然有逗号，但不会有分号。
    ///
    /// - Parameters:
    ///   - now: 计算 `Max-Age` 的基准时间。测试里传固定值，避免断言随真实时间漂移。
    public init?(setCookieHeader raw: String, defaultDomain: String, now: Date = Date()) {
        let segments = raw.split(separator: ";", omittingEmptySubsequences: false)
        guard let first = segments.first, let separator = first.firstIndex(of: "=") else { return nil }

        let name = String(first[first.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(first[first.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        var domain = defaultDomain
        var path = "/"
        var expires: Date?
        var secure = false
        var httpOnly = false

        for segment in segments.dropFirst() {
            let pair = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let attribute = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let attributeValue = pair.count > 1
                ? String(pair[1]).trimmingCharacters(in: .whitespaces)
                : ""
            switch attribute {
            case "domain" where !attributeValue.isEmpty:
                // 前导点是"包含子域"的写法，浏览器/URLSession 内部都按去掉点的形式比较
                domain = attributeValue.hasPrefix(".") ? String(attributeValue.dropFirst()) : attributeValue
            case "path" where !attributeValue.isEmpty:
                path = attributeValue
            case "expires":
                expires = Self.parseHTTPDate(attributeValue)
            case "max-age":
                if let seconds = Int(attributeValue) {
                    expires = now.addingTimeInterval(TimeInterval(seconds))
                }
            case "secure":
                secure = true
            case "httponly":
                httpOnly = true
            default:
                break
            }
        }

        self.init(
            name: name,
            value: value,
            domain: domain,
            path: path,
            expiresAt: expires,
            isSecure: secure,
            isHTTPOnly: httpOnly
        )
    }

    /// HTTP 日期固定是 GMT 的 RFC 1123 格式。
    ///
    /// 每次新建 `DateFormatter` 而不是共享静态实例：它不是 `Sendable`，
    /// 在 Swift 6 严格并发下作为全局可变状态会直接编译不过（与 `APIDecoding` 的处理一致）。
    private static func parseHTTPDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }
}

/// 一次会话涉及的全部 Cookie（better-auth 会同时下发 `...session_token` 与 `...session_data`）。
public struct SessionCookies: Codable, Sendable, Equatable {

    public var cookies: [AuthCookie]

    public init(cookies: [AuthCookie] = []) {
        self.cookies = cookies
    }

    /// 从响应头 `Set-Cookie` 解析出这次会话要保存的 Cookie。
    ///
    /// ## 为什么自己解析，而不是读 `HTTPCookieStorage`
    /// 原本的实现是让 URLSession 把 `Set-Cookie` 收进 `httpCookieStorage`，再从里面读。
    /// 但**实测发现在 macOS 的测试进程里这个存储始终是空的**（`URLSession.shared` 也一样），
    /// 也就是说"Cookie 到底有没有被收下"完全不可验证 —— 一旦它在 iOS 上也不生效，
    /// 表现就是"登录成功但马上又像没登录"，而且不报任何错。
    /// 改成自己解析响应头之后，这一步是**确定的**，也能被本地 HTTP 服务的测试覆盖。
    ///
    /// 只保留名字里含 "session" 的 Cookie，并丢掉已过期的：
    /// - 名字：better-auth 会下发 `better-auth.session_token` / `__Secure-better-auth.session_token`
    ///   / `better-auth.session_data`，都含 "session"；同时会下发一条 `__better-auth-cookie-store`
    ///   之类的**非会话** Cookie，不该混进来。按子串收拢而不是写死全名，
    ///   是为了不在服务端加 `__Secure-` 前缀时**静默**漏掉会话。
    /// - 过期：better-auth 清除会话的方式就是"下发一条同名但已过期的 Cookie"，
    ///   把它当成新会话存下来会导致下次请求带着一个无效会话。
    public init(responseHeader raw: String, domain: String, now: Date = Date()) {
        self.cookies = Self.splitSetCookieHeader(raw)
            .compactMap { AuthCookie(setCookieHeader: $0, defaultDomain: domain, now: now) }
            .filter { $0.name.lowercased().contains("session") && !$0.isExpired(at: now) }
    }

    /// 把 `Set-Cookie` 头的原文拆成一条条 Cookie。
    ///
    /// ## 为什么不能直接按逗号切
    /// `HTTPURLResponse` 会把**多个** `Set-Cookie` 用 ", " 拼成一个字符串，
    /// 而 `Expires` 的值自身就含逗号：
    /// ```
    /// better-auth.session_token=x; Expires=Wed, 14 Oct 2026 08:23:11 GMT, better-auth.session_data=y; Max-Age=300
    /// ```
    /// 无脑按逗号切会把第一条 Cookie 的过期时间切成一个独立的"Cookie"。
    ///
    /// 判据：**只有当逗号后面紧跟一个新的 `名字=` 时才切**。
    /// 日期里的逗号后面是 `14 Oct 2026 ...`（数字后有空格），不会命中这个形状。
    public static func splitSetCookieHeader(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let characters = Array(raw)
        var index = 0

        while index < characters.count {
            if characters[index] == "," {
                var lookahead = index + 1
                while lookahead < characters.count, characters[lookahead] == " " { lookahead += 1 }
                var nameEnd = lookahead
                while nameEnd < characters.count, isCookieNameCharacter(characters[nameEnd]) { nameEnd += 1 }
                if nameEnd > lookahead, nameEnd < characters.count, characters[nameEnd] == "=" {
                    parts.append(current)
                    current = ""
                    index = lookahead
                    continue
                }
            }
            current.append(characters[index])
            index += 1
        }

        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(current)
        }
        return parts
    }

    /// RFC 6265 的 token 字符集里我们实际会遇到的那些；会话 Cookie 名用不到其它符号。
    private static func isCookieNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
    }

    public var isEmpty: Bool { cookies.isEmpty }

    /// 拼出 `Cookie` 请求头。
    ///
    /// **过期的一律不带**：better-auth 清除会话的方式就是"下发一条同名但已过期的 Cookie"，
    /// 如果我们把这种 Cookie 原样带上去，等于每次都主动告诉服务端"这个会话无效"。
    public func headerValue(at now: Date = Date()) -> String {
        cookies
            .filter { !$0.isExpired(at: now) }
            .map(\.headerField)
            .joined(separator: "; ")
    }

    // MARK: - 持久化

    /// 编码成 JSON 存进 Keychain。
    ///
    /// 编解码器在这里现建现用（而不是当静态属性）：`JSONEncoder` / `JSONDecoder`
    /// 不是 `Sendable`，做成全局共享状态在严格并发下编译不过。
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) throws -> SessionCookies {
        try JSONDecoder().decode(SessionCookies.self, from: data)
    }
}

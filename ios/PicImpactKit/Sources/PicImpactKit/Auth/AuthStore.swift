import Foundation
import Observation

/// 登录状态与本地会话。
///
/// ## 为什么要有这一层
/// 会话有两份形态：**内存里的状态**（界面据此决定显示登录表单还是管理页）与
/// **Keychain 里的凭证**（跨启动保留登录态）。把两者放在同一个对象里，
/// 就不会出现"界面说已登录、但凭证没存下来"或反过来的不一致。
///
/// 所有方法都在主 actor 上：状态直接驱动 SwiftUI，跨 actor 传状态只会引入
/// 不必要的同步点。真正耗时的网络请求是 `await` 出去的，不会阻塞主线程。
@Observable
@MainActor
public final class AuthStore {

    public enum State: Equatable, Sendable {
        case signedOut
        case signingIn
        case signedIn(AuthUser)
    }

    /// Keychain 里的账号名。改成别的名字等于让所有老用户的登录态失效，不要随便动。
    ///
    /// `nonisolated`：它只是常量，非隔离的代码（例如启动前的日志、测试替身）也要能读到。
    nonisolated public static let defaultStorageKey = "session-cookies"

    public private(set) var state: State = .signedOut

    /// 内存里的会话。
    ///
    /// ⚠️ 为什么不能每次都去 Keychain 读：`SecItem*` 是同步调用，真机上可能阻塞；
    /// 而管理接口**每个请求**都要这个 header。登录成功后先放这里，请求路径就永不碰钥匙串。
    /// （真机事故：登录看着成功，但每请求的钥匙串读取拿不到会话 → 全部 401 → 管理页空白。）
    private var cachedCookies: SessionCookies?

    /// 凭证持久化失败时给用户看的告警（本次会话仍可用，重启后需要重新登录）
    public private(set) var storageWarning: String?

    /// 最近一次失败的原因。**优先展示服务端返回的原文**
    /// （例如错误密码时 better-auth 的 "Invalid email or password"）——
    /// 本地再编一套"邮箱或密码不正确"只会让排查"到底哪一步错了"变得更难。
    public private(set) var errorMessage: String?

    private let api: any AuthAPI
    private let keychain: any KeychainStoring
    private let storageKey: String

    public init(
        api: any AuthAPI,
        keychain: any KeychainStoring = KeychainStore(),
        storageKey: String = AuthStore.defaultStorageKey
    ) {
        self.api = api
        self.keychain = keychain
        self.storageKey = storageKey
    }

    // MARK: - 派生状态

    /// 当前账号。未登录（含正在登录）时为 nil。
    public var currentUser: AuthUser? {
        if case let .signedIn(user) = state { return user }
        return nil
    }

    public var isSignedIn: Bool { currentUser != nil }
    public var isWorking: Bool { state == .signingIn }

    /// 当前会话的 `Cookie` 请求头（没有会话、或全部 Cookie 都已过期时为 nil）。
    ///
    /// 管理接口（上传签发 / 登记 / 列表 / 删除）都要把它显式放进请求头 ——
    /// 这个后端没有 bearer 插件，会话只走 Cookie（与 `AuthClient` 一致）。
    public var sessionCookieHeader: String? {
        guard let cookies = cachedCookies else { return nil }
        let header = cookies.headerValue()
        return header.isEmpty ? nil : header
    }

    /// 会话已过期的方法化表达：服务端明确返回 401 时，管理接口那侧调用它，
    /// 界面就会退回到登录表单（而不是停在"空列表、也不说为什么"）。
    public func sessionRejected() {
        cachedCookies = nil
        storageWarning = nil
        state = .signedOut
        errorMessage = "登录状态已失效，请重新登录"
        Task { _ = await keychain.remove(storageKey) }
    }

    // MARK: - 动作

    public func clearError() {
        errorMessage = nil
    }

    public func signIn(email: String, password: String) async {
        guard !isWorking else { return }
        errorMessage = nil
        storageWarning = nil
        state = .signingIn
        // 任何路径（提前 return / 抛错 / 未来新增的分支）都不允许把界面留在"登录中…"。
        // 真机上曾经卡在这里：没有 defer 时，一条异常路径就能让登录按钮永久转圈。
        defer {
            if case .signingIn = state { state = .signedOut }
        }

        do {
            let session = try await api.signIn(email: email, password: password)

            // ⚠️ 必须**先确认凭证真的存下来了**，再进入"已登录"。
            // 真机事故：写钥匙串失败（返回值被忽略）却照样进了管理页，
            // 而每个请求都读不到会话 → 全 401 → 用户看到的是"登录了，但没有图片"。
            let stored = await persist(session.cookies)
            guard stored else {
                state = .signedOut
                errorMessage = "登录凭证无法保存到本机钥匙串，登录未完成，请重试"
                return
            }

            cachedCookies = session.cookies
            state = .signedIn(session.user)
        } catch {
            state = .signedOut
            errorMessage = Self.message(for: error)
        }
    }

    public func signOut() async {
        let header = sessionCookieHeader
        if let header {
            // 尽力而为：服务端吊销失败（断网）也必须能登出，所以这里不把错误往上抛
            try? await api.signOut(sessionCookie: header)
        }
        // 无论服务端怎么说，本地凭证一定清掉 —— 否则用户点了登出、重启后又"自己登录上了"
        cachedCookies = nil
        storageWarning = nil
        _ = await keychain.remove(storageKey)
        state = .signedOut
        errorMessage = nil
    }

    /// 启动时恢复登录态。
    ///
    /// 本地有 Cookie **不等于**服务端还认它（会话可能已过期或被吊销），
    /// 所以还要问一次 `get-session`：只有服务端确认了才进入已登录状态。
    public func restoreSession() async {
        guard case .signedOut = state else { return }
        guard let cookies = await loadStoredCookies(), !cookies.isEmpty else {
            state = .signedOut
            return
        }
        let header = cookies.headerValue()
        guard !header.isEmpty else {
            state = .signedOut
            return
        }
        do {
            if let user = try await api.user(sessionCookie: header) {
                cachedCookies = cookies
                state = .signedIn(user)
            } else {
                // 服务端明确说"没有会话"，本地这份就是垃圾，清掉避免每次启动都白问一次
                _ = await keychain.remove(storageKey)
                cachedCookies = nil
                state = .signedOut
            }
        } catch {
            // 网络不通时**保留**本地 Cookie（可能只是暂时连不上），但界面按未登录处理，
            // 等下次启动或用户手动登录再校验。绝不因为一次网络失败就删掉凭证。
            state = .signedOut
        }
    }

    // MARK: - 持久化

    /// - Returns: 是否真的写进了钥匙串。**调用方必须处理 false**（见 signIn）。
    private func persist(_ cookies: SessionCookies) async -> Bool {
        guard let data = try? cookies.encoded() else {
            APILog.credentials("session.persist 编码失败")
            return false
        }
        let started = Date()
        let ok = await keychain.set(data, for: storageKey)
        APILog.credentials(
            "session.persist ok=\(ok) cookies=\(cookies.cookies.count) bytes=\(data.count) ms=\(String(format: "%.1f", Date().timeIntervalSince(started) * 1000))"
        )
        if !ok {
            // 写不进去＝重启后必须重新登录。本次会话还能用（内存里有），所以只告警、不阻断。
            storageWarning = "登录凭证未能保存到本机，App 重启后需要重新登录"
        }
        return ok
    }

    private func loadStoredCookies() async -> SessionCookies? {
        guard let data = await keychain.data(for: storageKey) else { return nil }
        return try? SessionCookies.decoded(from: data)
    }

    /// 把任意错误翻成界面上显示的一句话。
    ///
    /// 优先级：
    /// 1. **服务端自己说的话** —— 错误密码时 better-auth 返回的是
    ///    `Invalid email or password`，这既是最有用的信息，也是端到端链路的证据；
    /// 2. 网络层给的可读文案（系统已本地化，例如"似乎已断开与互联网的连接"）；
    /// 3. 兜底一句产品文案。
    ///
    /// 刻意**不用** `APIError.errorDescription`：那是给日志的技术描述
    /// （带状态码与内部 code），放到界面上像调试面板。
    private static func message(for error: Error) -> String {
        guard let apiError = error as? APIError else { return error.localizedDescription }
        if let serverMessage = apiError.serverMessage, !serverMessage.isEmpty {
            return serverMessage
        }
        if case let .transport(detail) = apiError, !detail.isEmpty {
            return detail
        }
        return "登录失败，请稍后重试"
    }
}

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

    // MARK: - 动作

    public func clearError() {
        errorMessage = nil
    }

    public func signIn(email: String, password: String) async {
        guard !isWorking else { return }
        errorMessage = nil
        state = .signingIn
        do {
            let session = try await api.signIn(email: email, password: password)
            // 先落 Keychain 再改状态：反过来的话界面已经显示"已登录"，而凭证还没持久化，
            // 此刻进程被杀就会白白丢掉这次登录。
            persist(session.cookies)
            state = .signedIn(session.user)
        } catch {
            state = .signedOut
            errorMessage = Self.message(for: error)
        }
    }

    public func signOut() async {
        let header = storedCookieHeader()
        if let header {
            // 尽力而为：服务端吊销失败（断网）也必须能登出，所以这里不把错误往上抛
            try? await api.signOut(sessionCookie: header)
        }
        // 无论服务端怎么说，本地凭证一定清掉 —— 否则用户点了登出、重启后又"自己登录上了"
        clearStoredCookies()
        state = .signedOut
        errorMessage = nil
    }

    /// 启动时恢复登录态。
    ///
    /// 本地有 Cookie **不等于**服务端还认它（会话可能已过期或被吊销），
    /// 所以还要问一次 `get-session`：只有服务端确认了才进入已登录状态。
    public func restoreSession() async {
        guard case .signedOut = state else { return }
        guard let header = storedCookieHeader() else {
            state = .signedOut
            return
        }
        do {
            if let user = try await api.user(sessionCookie: header) {
                state = .signedIn(user)
            } else {
                // 服务端明确说"没有会话"，本地这份就是垃圾，清掉避免每次启动都白问一次
                clearStoredCookies()
                state = .signedOut
            }
        } catch {
            // 网络不通时**保留**本地 Cookie（可能只是暂时连不上），但界面按未登录处理，
            // 等下次启动或用户手动登录再校验。绝不因为一次网络失败就删掉凭证。
            state = .signedOut
        }
    }

    // MARK: - 持久化

    private func persist(_ cookies: SessionCookies) {
        guard let data = try? cookies.encoded() else { return }
        // 写失败不打断登录流程：本次会话仍可用（内存里有 Cookie），
        // 代价只是"重启后需要重新登录"。为此弹一个错误提示反而更让人困惑。
        _ = keychain.set(data, for: storageKey)
    }

    private func clearStoredCookies() {
        _ = keychain.remove(storageKey)
    }

    private func storedCookieHeader() -> String? {
        guard let data = keychain.data(for: storageKey),
              let cookies = try? SessionCookies.decoded(from: data)
        else { return nil }
        let header = cookies.headerValue()
        return header.isEmpty ? nil : header
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

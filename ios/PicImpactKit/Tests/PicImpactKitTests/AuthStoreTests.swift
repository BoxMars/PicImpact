import Foundation
import Testing

@testable import PicImpactKit

/// 测试夹具。放在 `@MainActor` 的 suite 之外，非隔离的代码（例如测试替身）也能用。
private enum Fixtures {

    static let user = AuthUser(id: "u_1", email: "someone@example.com", name: "大福")

    static func session(cookieValue: String = "abc") -> AuthSession {
        AuthSession(
            user: user,
            cookies: SessionCookies(cookies: [
                AuthCookie(
                    name: "better-auth.session_token",
                    value: cookieValue,
                    domain: "felina.boxz.dev",
                    isSecure: true
                ),
            ])
        )
    }

    /// 按 `AuthStore` 的方式把一份会话写进 Keychain，用来模拟"上次登录过"
    static func seed(_ keychain: KeychainStoring, cookies: SessionCookies) {
        guard let data = try? cookies.encoded() else { return }
        _ = keychain.set(data, for: AuthStore.defaultStorageKey)
    }
}

/// 可编排的假后端。`signOutCookie` 用来确认"请求确实发出去了"。
private final class FakeAPI: AuthAPI, @unchecked Sendable {
    var signInResult: Result<AuthSession, APIError>
    var userResult: Result<AuthUser?, APIError>
    private(set) var signOutCookie: String?

    init(
        signIn: Result<AuthSession, APIError> = .failure(.transport("未设置")),
        user: Result<AuthUser?, APIError> = .success(nil)
    ) {
        self.signInResult = signIn
        self.userResult = user
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        try signInResult.get()
    }

    func user(sessionCookie: String) async throws -> AuthUser? {
        try userResult.get()
    }

    func signOut(sessionCookie: String) async throws {
        signOutCookie = sessionCookie
    }
}

/// 服务端吊销总是失败的后端（模拟断网）
private struct FailingSignOutAPI: AuthAPI {
    func signIn(email: String, password: String) async throws -> AuthSession { Fixtures.session() }
    func user(sessionCookie: String) async throws -> AuthUser? { Fixtures.user }
    func signOut(sessionCookie: String) async throws { throw APIError.transport("断网") }
}

/// 登录状态机：登录成功写凭证、失败展示服务端原文、登出清凭证、启动恢复。
///
/// 这些路径**没法**用真密码在模拟器上走通（我们不知道密码），所以它们只能靠这组测试钉住。
/// 后端与 Keychain 都换成可注入的实现：状态迁移的正确性与网络、与系统钥匙串都无关。
@Suite("认证 · 登录状态机")
@MainActor
struct AuthStoreTests {

    // MARK: - 登录

    @Test("登录成功：凭证写进 Keychain，状态变为已登录")
    func signInPersistsSession() async throws {
        let keychain = InMemoryKeychain()
        let store = AuthStore(api: FakeAPI(signIn: .success(Fixtures.session())), keychain: keychain)

        await store.signIn(email: "someone@example.com", password: "pw")

        #expect(store.isSignedIn)
        #expect(store.currentUser == Fixtures.user)
        #expect(store.errorMessage == nil)

        // 关键：Cookie 必须真的落到存储层（而不是只留在内存里）
        let data = try #require(keychain.data(for: AuthStore.defaultStorageKey))
        let stored = try SessionCookies.decoded(from: data)
        #expect(stored.headerValue() == "better-auth.session_token=abc")
    }

    @Test("登录失败：状态回到未登录，并原样展示服务端返回的那句话")
    func signInFailureShowsServerMessage() async {
        let keychain = InMemoryKeychain()
        // 这句就是服务端在密码错误时返回的原文（见 AuthRequestTests）
        let serverError = APIError.http(status: 401, code: nil, message: "Invalid email or password")
        let store = AuthStore(api: FakeAPI(signIn: .failure(serverError)), keychain: keychain)

        await store.signIn(email: "someone@example.com", password: "wrong")

        #expect(store.isSignedIn == false)
        // 界面上显示的就是服务端那句话本身：不带"服务端返回 401："前缀，也不带内部 code
        #expect(store.errorMessage == "Invalid email or password")
        #expect(keychain.data(for: AuthStore.defaultStorageKey) == nil, "登录失败不该写入任何凭证")
    }

    @Test("网络错误：用网络层给的可读文案，而不是技术描述")
    func signInNetworkFailureShowsReadableText() async {
        let store = AuthStore(
            api: FakeAPI(signIn: .failure(.transport("似乎已断开与互联网的连接"))),
            keychain: InMemoryKeychain()
        )

        await store.signIn(email: "someone@example.com", password: "pw")

        #expect(store.errorMessage == "似乎已断开与互联网的连接")
        #expect(store.errorMessage?.contains("网络错误：") == false, "不该带上技术前缀")
    }

    @Test("其它失败（例如响应解不开）只给一句产品文案，不把技术细节摆到界面上")
    func signInUnknownFailureShowsGenericText() async {
        let store = AuthStore(
            api: FakeAPI(signIn: .failure(.decoding("keyNotFound(CodingKeys(stringValue: \"user\")"))),
            keychain: InMemoryKeychain()
        )

        await store.signIn(email: "someone@example.com", password: "pw")

        #expect(store.errorMessage == "登录失败，请稍后重试")
    }

    // MARK: - 登出

    @Test("登出：清掉 Keychain 里的会话，并通知服务端吊销")
    func signOutClearsKeychain() async {
        let keychain = InMemoryKeychain()
        let api = FakeAPI(signIn: .success(Fixtures.session()), user: .success(Fixtures.user))
        let store = AuthStore(api: api, keychain: keychain)
        await store.signIn(email: "someone@example.com", password: "pw")
        #expect(keychain.data(for: AuthStore.defaultStorageKey) != nil)

        await store.signOut()

        #expect(store.isSignedIn == false)
        #expect(keychain.data(for: AuthStore.defaultStorageKey) == nil, "登出必须清掉凭证")
        #expect(api.signOutCookie == "better-auth.session_token=abc")
    }

    @Test("服务端吊销失败也必须能登出（断网时不能把用户锁在登录态里）")
    func signOutClearsKeychainEvenIfServerFails() async {
        let keychain = InMemoryKeychain()
        let store = AuthStore(api: FailingSignOutAPI(), keychain: keychain)
        await store.signIn(email: "someone@example.com", password: "pw")

        await store.signOut()

        #expect(store.isSignedIn == false)
        #expect(keychain.data(for: AuthStore.defaultStorageKey) == nil)
    }

    // MARK: - 启动恢复

    @Test("启动恢复：本地会话仍被服务端认可 → 直接进入已登录")
    func restoreWithValidSession() async {
        let keychain = InMemoryKeychain()
        Fixtures.seed(keychain, cookies: Fixtures.session().cookies)
        let store = AuthStore(api: FakeAPI(user: .success(Fixtures.user)), keychain: keychain)

        await store.restoreSession()

        #expect(store.currentUser == Fixtures.user)
        #expect(keychain.data(for: AuthStore.defaultStorageKey) != nil, "有效的会话要保留")
    }

    @Test("启动恢复：服务端已不认这个会话 → 清掉本地 Cookie")
    func restoreWithStaleSessionClearsStorage() async {
        let keychain = InMemoryKeychain()
        Fixtures.seed(keychain, cookies: Fixtures.session().cookies)
        // get-session 返回 null（服务端说没有会话）
        let store = AuthStore(api: FakeAPI(user: .success(nil)), keychain: keychain)

        await store.restoreSession()

        #expect(store.isSignedIn == false)
        #expect(keychain.data(for: AuthStore.defaultStorageKey) == nil, "失效的会话不该一直留在本地")
    }

    @Test("启动恢复：网络不通时保留凭证（不能因为一次失败就删掉会话）")
    func restoreKeepsCredentialsWhenOffline() async {
        let keychain = InMemoryKeychain()
        Fixtures.seed(keychain, cookies: Fixtures.session().cookies)
        let store = AuthStore(api: FakeAPI(user: .failure(.transport("断网"))), keychain: keychain)

        await store.restoreSession()

        #expect(store.isSignedIn == false, "没确认之前不显示已登录")
        #expect(keychain.data(for: AuthStore.defaultStorageKey) != nil, "凭证必须留着，下次再校验")
    }

    @Test("启动恢复：本地没有会话时什么都不做")
    func restoreWithoutSession() async {
        let store = AuthStore(api: FakeAPI(user: .success(Fixtures.user)), keychain: InMemoryKeychain())

        await store.restoreSession()

        #expect(store.isSignedIn == false)
    }

    @Test("过期的本地会话不会被拿去请求（直接当作未登录）")
    func restoreIgnoresExpiredCookies() async {
        let keychain = InMemoryKeychain()
        Fixtures.seed(keychain, cookies: SessionCookies(cookies: [
            AuthCookie(
                name: "better-auth.session_token",
                value: "abc",
                domain: "felina.boxz.dev",
                expiresAt: Date(timeIntervalSince1970: 0)
            ),
        ]))
        let store = AuthStore(api: FakeAPI(user: .success(Fixtures.user)), keychain: keychain)

        await store.restoreSession()

        #expect(store.isSignedIn == false)
    }
}

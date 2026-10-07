import Foundation
import Testing

@testable import PicImpactKit

/// Keychain wrapper 的读写。
///
/// ⚠️ 这组测试**真的**操作系统钥匙串（不是一个 mock）：
/// 会话 Cookie 的持久化是"登录态能不能跨启动保留"的唯一依赖，
/// 用假实现测它等于什么都没测。每条测试用**独立的 service**，
/// 结束时不依赖清理顺序，也不会污染 App 自己的条目。
@Suite("认证 · Keychain 读写", .serialized)
struct KeychainStoreTests {

    /// 每次用新的 service，避免并发或残留互相干扰
    private func makeStore() -> KeychainStore {
        KeychainStore(service: "dev.boxz.felina.tests.\(UUID().uuidString)")
    }

    @Test("写入 → 读出 → 覆盖 → 删除")
    func roundTrip() async {
        let store = makeStore()
        let key = "session-cookies"

        #expect(await store.data(for: key) == nil, "新 service 里不该有数据")

        #expect(await store.set(Data("v1".utf8), for: key))
        #expect(await store.data(for: key) == Data("v1".utf8))

        // 覆盖走的是 SecItemUpdate 分支 —— 它和首次写入（SecItemAdd）是两条不同的代码路径
        #expect(await store.set(Data("v2".utf8), for: key))
        #expect(await store.data(for: key) == Data("v2".utf8))

        #expect(await store.remove(key))
        #expect(await store.data(for: key) == nil)
    }

    @Test("删除是幂等的：删不存在的键也算成功")
    func removeIsIdempotent() async {
        let store = makeStore()
        #expect(await store.remove("never-written"))
        #expect(await store.remove("never-written"))
    }

    @Test("不同的 key 互不覆盖")
    func keysAreIsolated() async {
        let store = makeStore()
        #expect(await store.set(Data("a".utf8), for: "k1"))
        #expect(await store.set(Data("b".utf8), for: "k2"))
        #expect(await store.data(for: "k1") == Data("a".utf8))
        #expect(await store.data(for: "k2") == Data("b".utf8))
        #expect(await store.remove("k1"))
        #expect(await store.data(for: "k2") == Data("b".utf8), "删掉 k1 不该动到 k2")
    }

    @Test("会话 JSON 存得进、取得出（真正会被写进钥匙串的那份数据）")
    func storesSessionCookiesJSON() async throws {
        let store = makeStore()
        let cookies = SessionCookies(cookies: [
            AuthCookie(name: "better-auth.session_token", value: "abc", domain: "felina.boxz.dev", isSecure: true),
        ])

        #expect(await store.set(try cookies.encoded(), for: AuthStore.defaultStorageKey))
        let data = try #require(await store.data(for: AuthStore.defaultStorageKey))
        let restored = try SessionCookies.decoded(from: data)

        #expect(restored == cookies)
        #expect(restored.headerValue() == "better-auth.session_token=abc")
    }

    @Test("内存实现与真实实现语义一致（供 AuthStore 测试注入）")
    func inMemoryMatchesContract() async {
        let store = InMemoryKeychain()
        #expect(await store.data(for: "k") == nil)
        #expect(await store.set(Data("v".utf8), for: "k"))
        #expect(await store.data(for: "k") == Data("v".utf8))
        #expect(await store.remove("k"))
        #expect(await store.data(for: "k") == nil)
        #expect(await store.remove("k"), "删除同样应当是幂等的")
    }
}

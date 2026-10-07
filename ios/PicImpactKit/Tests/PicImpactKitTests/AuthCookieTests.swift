import Foundation
import Testing

@testable import PicImpactKit

/// 会话 Cookie 的解析与拼装。
///
/// 这些逻辑全部是纯函数，但**必须**测：会话丢失的表现是"登录成功后仍显示未登录"，
/// 没有任何报错，只能靠这些断言把"解析对不对"钉住。
@Suite("认证 · 会话 Cookie")
struct AuthCookieTests {

    // MARK: - Set-Cookie 解析

    @Test("解析 Set-Cookie 的各个属性")
    func parsesSetCookieAttributes() throws {
        let raw = "better-auth.session_token=abc123; Max-Age=604800; Path=/; Domain=.boxz.dev; Secure; HttpOnly; SameSite=Lax"
        let cookie = try #require(
            AuthCookie(setCookieHeader: raw, defaultDomain: "felina.boxz.dev", now: Date(timeIntervalSince1970: 1_000_000))
        )

        #expect(cookie.name == "better-auth.session_token")
        #expect(cookie.value == "abc123")
        // Domain 的前导点要去掉：那是"包含子域"的写法，不是域名的一部分
        #expect(cookie.domain == "boxz.dev")
        #expect(cookie.path == "/")
        #expect(cookie.isSecure)
        #expect(cookie.isHTTPOnly)
        // Max-Age=604800 → now + 7 天
        #expect(cookie.expiresAt == Date(timeIntervalSince1970: 1_000_000 + 604_800))
    }

    @Test("没有 Domain 属性时落在请求域名上（会话 Cookie 就是这种）")
    func defaultsDomainWhenAttributeMissing() throws {
        let cookie = try #require(
            AuthCookie(setCookieHeader: "better-auth.session_token=xyz; Path=/", defaultDomain: "felina.boxz.dev")
        )
        #expect(cookie.domain == "felina.boxz.dev")
        #expect(cookie.expiresAt == nil, "会话 Cookie 不该有过期时间")
        #expect(!cookie.isSecure)
    }

    @Test("解析 Expires（HTTP 日期里带逗号，不能按逗号切分）")
    func parsesExpiresAttribute() throws {
        let raw = "a=b; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/"
        let cookie = try #require(AuthCookie(setCookieHeader: raw, defaultDomain: "felina.boxz.dev"))
        #expect(cookie.expiresAt == Date(timeIntervalSince1970: 0))
    }

    @Test("无效输入返回 nil 而不是伪造一条 Cookie")
    func rejectsMalformedHeaders() {
        #expect(AuthCookie(setCookieHeader: "没有等号", defaultDomain: "d") == nil)
        #expect(AuthCookie(setCookieHeader: "=只有值", defaultDomain: "d") == nil)
    }

    // MARK: - 拼 Cookie 头

    @Test("Cookie 头按 name=value 拼接，用分号+空格分隔")
    func buildsCookieHeader() {
        let cookies = SessionCookies(cookies: [
            AuthCookie(name: "better-auth.session_token", value: "abc", domain: "felina.boxz.dev"),
            AuthCookie(name: "better-auth.session_data", value: "def", domain: "felina.boxz.dev"),
        ])
        #expect(cookies.headerValue() == "better-auth.session_token=abc; better-auth.session_data=def")
    }

    @Test("过期的 Cookie 不进 Cookie 头（登出就是靠下发过期 Cookie 生效的）")
    func dropsExpiredCookies() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let live = AuthCookie(name: "a", value: "1", domain: "d", expiresAt: now.addingTimeInterval(60))
        let dead = AuthCookie(name: "b", value: "2", domain: "d", expiresAt: now.addingTimeInterval(-1))
        // 没有过期时间的会话 Cookie 永远有效
        let session = AuthCookie(name: "c", value: "3", domain: "d", expiresAt: nil)

        #expect(SessionCookies(cookies: [live, dead, session]).headerValue(at: now) == "a=1; c=3")
    }

    @Test("全过期时拼出空串（调用方据此判定\"没有可用会话\"）")
    func emptyHeaderWhenAllExpired() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let dead = AuthCookie(name: "a", value: "1", domain: "d", expiresAt: now.addingTimeInterval(-1))
        #expect(SessionCookies(cookies: [dead]).headerValue(at: now).isEmpty)
    }

    // MARK: - 多条 Set-Cookie 的拆分

    @Test("拆分被 Foundation 拼成一条的多个 Set-Cookie（Expires 里的逗号不能当分隔符）")
    func splitsJoinedSetCookieHeader() {
        // 这是实测的形态：HTTPURLResponse 把两个 Set-Cookie 用 ", " 拼在一起，
        // 而第一条的 Expires 值自身就带逗号
        let raw = "better-auth.session_token=tok123; Path=/; HttpOnly; Secure; SameSite=Lax; "
            + "Expires=Wed, 14 Oct 2026 08:23:11 GMT, better-auth.session_data=data456; Path=/; HttpOnly; Max-Age=300"

        let parts = SessionCookies.splitSetCookieHeader(raw)
        #expect(parts.count == 2, "应拆成两条，实际 \(parts.count)：\(parts)")
        #expect(parts[0].contains("Expires=Wed, 14 Oct 2026 08:23:11 GMT"), "日期被切断了：\(parts[0])")
        #expect(parts[1].hasPrefix("better-auth.session_data=data456"))
    }

    @Test("单条 Set-Cookie 原样返回")
    func singleCookieIsNotSplit() {
        let raw = "a=1; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
        #expect(SessionCookies.splitSetCookieHeader(raw) == [raw])
    }

    // MARK: - 从响应头解析会话

    @Test("从响应头解析：只留会话 Cookie，且丢掉已过期的")
    func parsesSessionCookiesFromResponseHeader() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let raw = "better-auth.session_token=tok123; Path=/; HttpOnly; Expires=Wed, 14 Oct 2026 08:23:11 GMT, "
            + "better-auth.session_data=data456; Path=/; Max-Age=300, "
            + "__better-auth-cookie-store=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"

        let cookies = SessionCookies(responseHeader: raw, domain: "felina.boxz.dev", now: now)

        // 非会话 Cookie（名字里没有 session）与已过期的都不该留下
        #expect(cookies.cookies.map(\.name) == ["better-auth.session_token", "better-auth.session_data"])
        #expect(cookies.headerValue(at: now) == "better-auth.session_token=tok123; better-auth.session_data=data456")
    }

    @Test("响应头里没有会话 Cookie 时是空的（调用方据此判定登录失败）")
    func emptyWhenNoSessionCookieInResponse() {
        let raw = "__better-auth-cookie-store=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
        #expect(SessionCookies(responseHeader: raw, domain: "felina.boxz.dev").isEmpty)
        #expect(SessionCookies(responseHeader: "", domain: "felina.boxz.dev").isEmpty)
    }

    // MARK: - 持久化编码

    @Test("编码成 JSON 再解回来完全一致（Keychain 里存的就是这份）")
    func codableRoundTrip() throws {
        let original = SessionCookies(cookies: [
            AuthCookie(
                name: "better-auth.session_token",
                value: "abc",
                domain: "felina.boxz.dev",
                path: "/",
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
                isSecure: true,
                isHTTPOnly: true
            ),
        ])
        let restored = try SessionCookies.decoded(from: try original.encoded())
        #expect(restored == original)
    }
}

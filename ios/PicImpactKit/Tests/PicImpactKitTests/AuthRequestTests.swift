import Foundation
import Testing

@testable import PicImpactKit

/// 请求构造与错误翻译。
///
/// 这两件事决定了"端到端联不通"时到底卡在哪：
/// 请求体字段名错了服务端会 400，方法错了会 404，而错误体解不出来界面就只会显示一个状态码。
/// 全部是纯函数，直接对 `URLRequest` 与 `Data` 断言即可，不需要真的发请求。
@Suite("认证 · 请求与错误")
struct AuthRequestTests {

    private let origin = URL(string: "https://felina.boxz.dev")!

    // MARK: - 站点根

    @Test("站点根从公开 API 的 baseURL 反推（域名只有一处来源）")
    func derivesSiteOrigin() {
        #expect(
            APIClient.siteOrigin(from: URL(string: "https://felina.boxz.dev/api/public/v1")!).absoluteString
                == "https://felina.boxz.dev"
        )
        // 生产默认值也必须推出同一个结果
        #expect(APIClient.siteOrigin().absoluteString == "https://felina.boxz.dev")
    }

    // MARK: - 登录请求

    @Test("登录请求：POST /api/auth/sign-in/email，体里只有 email 与 password")
    func signInRequestShape() throws {
        let request = try AuthClient.signInRequest(
            siteOrigin: origin,
            email: "someone@example.com",
            password: "not-the-password"
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://felina.boxz.dev/api/auth/sign-in/email")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // 服务端对缺字段的报错里点名的就是 body.email / body.password，字段名不能改
        #expect(json.count == 2, "请求体只应有 email 与 password，实际：\(json.keys.sorted())")
        #expect(json["email"] as? String == "someone@example.com")
        #expect(json["password"] as? String == "not-the-password")
    }

    @Test("邮箱或密码里的特殊字符不会把 JSON 弄坏")
    func signInRequestBodyEscapesSpecialCharacters() throws {
        let request = try AuthClient.signInRequest(
            siteOrigin: origin,
            email: #"a"b\c@example.com"#,
            password: "p\"a\\ss\n"
        )
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["email"] as? String == #"a"b\c@example.com"#)
        #expect(json["password"] as? String == "p\"a\\ss\n")
    }

    // MARK: - 会话查询 / 登出

    @Test("会话查询必须是 GET（better-auth 的 get-session 不接受 POST）")
    func sessionRequestUsesGet() {
        let request = AuthClient.sessionRequest(siteOrigin: origin, cookieHeader: "better-auth.session_token=abc")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://felina.boxz.dev/api/auth/get-session")
    }

    @Test("会话请求把会话放在 Cookie 头里（这个后端没有 bearer 插件）")
    func sessionRequestCarriesCookie() {
        let request = AuthClient.sessionRequest(
            siteOrigin: origin,
            cookieHeader: "better-auth.session_token=abc; better-auth.session_data=def"
        )
        #expect(request.value(forHTTPHeaderField: "Cookie") == "better-auth.session_token=abc; better-auth.session_data=def")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "不该走 Bearer")
    }

    @Test("空 Cookie 时不发 Cookie 头（避免发出一个空会话）")
    func sessionRequestOmitsEmptyCookie() {
        let request = AuthClient.sessionRequest(siteOrigin: origin, cookieHeader: "")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test("登出：POST /api/auth/sign-out 并带上会话")
    func signOutRequestShape() {
        let request = AuthClient.signOutRequest(siteOrigin: origin, cookieHeader: "better-auth.session_token=abc")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://felina.boxz.dev/api/auth/sign-out")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "better-auth.session_token=abc")
    }

    // MARK: - 错误翻译

    @Test("better-auth 的错误体只取服务端原话（内部 code 不进 message，免得出现在界面上）")
    func translatesServerError() {
        // 这段是**实测**抓下来的原文（错误密码时的 401 响应体）
        let body = Data(#"{"message":"Invalid email or password","code":"INVALID_EMAIL_OR_PASSWORD"}"#.utf8)
        let error = AuthClient.apiError(status: 401, body: body)

        #expect(error == .http(status: 401, code: nil, message: "Invalid email or password"))
        // 界面上要显示的正是服务端这句话，且**不含**内部 code
        #expect(error.serverMessage == "Invalid email or password")
        #expect(error.serverMessage?.contains("INVALID_EMAIL_OR_PASSWORD") == false)
        #expect(error.errorDescription?.contains("Invalid email or password") == true)
    }

    @Test("错误体不是 JSON 时不把正文（可能是一整页 HTML）丢到界面上")
    func nonJSONErrorBodyKeepsOnlyStatus() {
        let error = AuthClient.apiError(status: 502, body: Data("<html>bad gateway</html>".utf8))
        #expect(error == .http(status: 502, code: nil, message: nil))
        #expect(error.serverMessage == nil)
        // 技术描述里仍然保留状态码，供日志/排查
        #expect(error.errorDescription?.contains("502") == true)
    }

    @Test("空错误体只留状态码")
    func handlesEmptyErrorBody() {
        let error = AuthClient.apiError(status: 500, body: Data())
        #expect(error == .http(status: 500, code: nil, message: nil))
    }

    // MARK: - 响应解码

    @Test("解开 better-auth 的 user 对象（未知字段必须被忽略）")
    func decodesAuthUser() throws {
        // 字段取自 better-auth 的实际返回：除了我们用的四个，还有 emailVerified / createdAt 等
        let json = Data(#"""
        {
          "id": "u_123",
          "name": "大福",
          "email": "someone@example.com",
          "emailVerified": true,
          "image": null,
          "createdAt": "2026-01-01T00:00:00.000Z",
          "updatedAt": "2026-01-02T00:00:00.000Z"
        }
        """#.utf8)

        let user = try JSONDecoder().decode(AuthUser.self, from: json)
        #expect(user.id == "u_123")
        #expect(user.email == "someone@example.com")
        #expect(user.displayName == "大福")
    }

    @Test("昵称为空时退回邮箱显示，而不是显示空白")
    func displayNameFallsBackToEmail() throws {
        let json = Data(#"{"id":"u_1","email":"someone@example.com","name":"  "}"#.utf8)
        let user = try JSONDecoder().decode(AuthUser.self, from: json)
        #expect(user.displayName == "someone@example.com")
    }
}

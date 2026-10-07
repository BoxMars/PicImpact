import CoreGraphics
import SwiftUI
import Testing

@testable import PicImpactKit

/// 管理入口两个界面的渲染验证。
///
/// ## 为什么需要它（这两页在真机上"看不到"）
/// 登录成功后的占位管理页只有在**真的登录成功**时才会出现，而实施者没有管理员密码，
/// 所以它在模拟器上永远不会被渲染出来。这里用 `ImageRenderer` 把它画一遍并断言像素：
/// 至少能保证"这一页不是一片空白、纸卡与登出按钮的令牌色真的画出来了"。
///
/// 方法沿用 `IslandCardTests`：栅格化 → 数颜色。视图渲染出错时不会崩溃，
/// 只会**静默**变成一块空白，所以这类断言是必要的。
@Suite("管理入口 · 界面渲染")
@MainActor
struct AdminViewsTests {

    typealias Pixels = IslandCardTests.Pixels

    static func count(_ pixels: Pixels, _ hex: UInt32, tolerance: Int = 3) -> Int {
        var hit = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.matches(x, y, hex, tolerance: tolerance) {
                hit += 1
            }
        }
        return hit
    }

    @Test("占位管理页：纸卡、描边、以及登出按钮的危险色都画出来了")
    func adminHomeDrawsCardAndSignOut() throws {
        let view = AdminAccountContent(
            user: AuthUser(id: "u_1", email: "someone@example.com", name: "大福"),
            isBusy: false,
            onSignOut: {},
            onClose: {}
        )
        .frame(width: 393, height: 520)

        let pixels = try #require(IslandCardTests.rasterize(view))
        #expect(Self.count(pixels, 0xF7F3DF) > 1000, "纸卡底色没画出来")
        #expect(Self.count(pixels, 0xC4B89E) > 100, "纸卡描边没画出来")
        #expect(Self.count(pixels, 0xE05A5A) > 500, "登出按钮（错误色）没画出来")
        #expect(Self.count(pixels, 0x19C8B9) > 30, "页面标题下的青色短横没画出来")
    }

    @Test("登录表单：没有错误时不画错误框，有错误时画出错误色")
    func loginFormDrawsErrorOnlyWhenPresent() throws {
        func pixels(error: String?) throws -> Pixels {
            let view = AdminLoginContent(
                email: .constant("someone@example.com"),
                password: .constant("pw"),
                isBusy: false,
                errorMessage: error,
                onCancel: {},
                onSubmit: { _, _ in }
            )
            .frame(width: 393, height: 560)
            return try #require(IslandCardTests.rasterize(view))
        }

        // 默认状态：主色按钮 + 纸卡，没有任何错误色
        let clean = try pixels(error: nil)
        #expect(Self.count(clean, 0x19C8B9) > 500, "登录按钮的主色没画出来")
        #expect(Self.count(clean, 0xE05A5A) == 0, "没有错误时不该出现错误色")

        // 服务端返回错误后：错误色出现（文字 + 描边）
        let failed = try pixels(error: "Invalid email or password")
        #expect(Self.count(failed, 0xE05A5A) > 100, "错误信息区没有画出来")
    }
}

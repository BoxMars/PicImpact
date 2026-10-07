import CoreGraphics
import SwiftUI
import Testing

@testable import PicImpactKit

/// 管理入口几个界面的渲染验证。
///
/// ## 为什么需要它
/// `ImageRenderer` 渲染出错时不会崩，只会**静默**变成一块空白 —— 所以"看起来对不对"
/// 必须落成像素断言。这里只渲染**不依赖滚动容器**的那几块（`ImageRenderer` 渲染不出
/// `ScrollView` 里的内容，实测得到全透明的图），以及纯值的行视图。
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

        let clean = try pixels(error: nil)
        #expect(Self.count(clean, 0x19C8B9) > 500, "登录按钮的主色没画出来")
        #expect(Self.count(clean, 0xE05A5A) == 0, "没有错误时不该出现错误色")

        let failed = try pixels(error: "Invalid email or password")
        #expect(Self.count(failed, 0xE05A5A) > 100, "错误信息区没有画出来")
    }

    @Test("动作按钮外观：主色按钮画主色，危险色按钮画错误色")
    func actionLabelTones() throws {
        let primary = try #require(IslandCardTests.rasterize(
            IslandActionLabel("选择照片", icon: .camera).frame(width: 300, height: 60)
        ))
        #expect(Self.count(primary, 0x19C8B9) > 500)

        let danger = try #require(IslandCardTests.rasterize(
            IslandActionLabel("登出", tone: .danger).frame(width: 300, height: 60)
        ))
        #expect(Self.count(danger, 0xE05A5A) > 500)
    }

    @Test("上传状态行：失败用错误色、完成用成功色")
    func uploadStatusRowColors() throws {
        let failed = try #require(IslandCardTests.rasterize(
            AdminUploadStatusRow(item: UploadItem(
                filename: "photo-1.jpg",
                byteCount: 12 * 1024 * 1024,
                state: .failed(.register, message: "register_failed（原图已上传到存储，但未登记；对象 key：images/daily/x.jpg）")
            ))
            .frame(width: 340, height: 120)
        ))
        #expect(Self.count(failed, 0xE05A5A) > 30, "失败状态没有用错误色")
        #expect(Self.count(failed, 0x6FBA2C) == 0, "失败时不该出现成功色")

        let done = try #require(IslandCardTests.rasterize(
            AdminUploadStatusRow(item: UploadItem(
                filename: "photo-2.jpg",
                byteCount: 1024,
                state: .done(imageID: "clx1", url: "https://x/a.jpg")
            ))
            .frame(width: 340, height: 80)
        ))
        #expect(Self.count(done, 0x6FBA2C) > 10, "完成状态没有用成功色")
    }

    @Test("列表行：缩略图描边 + 删除按钮用错误色")
    func imageRowRenders() throws {
        let summary = AdminImageSummary(
            id: "clx1",
            url: "",
            previewUrl: "",
            title: "标题",
            detail: "",
            width: 1600,
            height: 1000,
            show: 0,
            showOnMainpage: 0,
            labels: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            albumValue: "/daily",
            albumName: "大福日常",
            exif: .init(model: "iPhone 15", lensModel: "", dataTime: "")
        )
        // url 为空 → 缩略图 URL 为 nil → 不会发起任何网络请求
        let view = AdminImageRow(image: summary, loader: ImageLoader(), isDeleting: false, onDelete: {})
            .padding(12)
            .frame(width: 360, height: 80)
        let pixels = try #require(IslandCardTests.rasterize(view))
        #expect(Self.count(pixels, 0xC4B89E) > 50, "缩略图描边没画出来")
        #expect(Self.count(pixels, 0xE05A5A) > 20, "删除按钮没有用错误色")
    }
}

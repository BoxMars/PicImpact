import Foundation
import Testing

@testable import PicImpactKit

/// 通知 `userInfo` → 待跳转目标。
///
/// 载荷是外部输入（Apple 控制台、任何拿到 .p8 的人都能构造），而这些负例在真机上
/// 只会表现为"点了通知没反应" —— 完全无法调试。所以规则放在 Kit 里逐条钉住。
@Suite("推送 · 通知跳转解析")
struct PushRouteTests {

    @Test("正常载荷：取到 imageId（其余字段一律忽略）")
    func parsesStandardPayload() {
        // 与服务端 §4.2 的载荷同形：aps + v + imageId + albumValue + previewUrl
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "大福映画"]],
            "v": 1,
            "imageId": "clx1234567890",
            "albumValue": "/daily",
            "previewUrl": "https://felina-asset.boxz.dev/images/daily/preview/clx.webp",
        ]
        let route = PushRoute(userInfo: userInfo)
        #expect(route?.imageId == "clx1234567890")
    }

    @Test("前后空白会被去掉（载荷是手写 JSON 时最容易多一个空格）")
    func trimsWhitespace() {
        let route = PushRoute(userInfo: ["imageId": "  clx1234567890\n"])
        #expect(route?.imageId == "clx1234567890")
    }

    @Test("负例：缺字段 / 类型不对 / 空串 / 非法字符一律 nil")
    func rejectsInvalidPayloads() {
        #expect(PushRoute(userInfo: [:]) == nil, "完全没有 imageId")
        #expect(PushRoute(userInfo: ["albumValue": "/daily"]) == nil, "有别的字段但没 imageId")
        #expect(PushRoute(userInfo: ["imageId": 123]) == nil, "类型不对（数字）")
        #expect(PushRoute(userInfo: ["imageId": NSNull()]) == nil, "类型不对（null）")
        #expect(PushRoute(userInfo: ["imageId": ""]) == nil, "空串")
        #expect(PushRoute(userInfo: ["imageId": "   "]) == nil, "只有空白")
        #expect(PushRoute(userInfo: ["imageId": "../admin/images"]) == nil, "路径段注入")
        #expect(PushRoute(userInfo: ["imageId": "clx/../../etc"]) == nil, "斜杠一律不收")
        #expect(PushRoute(userInfo: ["imageId": String(repeating: "a", count: 65)]) == nil, "超长")
        #expect(PushRoute(userInfo: ["imageId": "clx-1_2"]) != nil, "cuid 之外只多收 - 与 _")
    }

    @Test("冷启动的待跳转持有者：取走即清空，不会重复跳转")
    @MainActor
    func inboxTakeConsumesOnce() {
        let inbox = PushRouteInbox()
        #expect(inbox.pending == nil)

        inbox.put(PushRoute(imageId: "clx1"))
        #expect(inbox.pending?.imageId == "clx1")

        #expect(inbox.take()?.imageId == "clx1")
        #expect(inbox.pending == nil, "取走后必须清空 —— 否则视图重建会重复跳转")
        #expect(inbox.take() == nil)
    }

    @Test("后到的通知覆盖先到的（用户点了两次，跳最后一张）")
    @MainActor
    func inboxKeepsLatest() {
        let inbox = PushRouteInbox()
        inbox.put(PushRoute(imageId: "clx1"))
        inbox.put(PushRoute(imageId: "clx2"))
        #expect(inbox.take()?.imageId == "clx2")
    }
}

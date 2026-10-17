import Foundation
import Observation

/// 通知载荷里我们唯一关心的东西：**点开要跳到哪张图**。
///
/// ## 为什么解析逻辑放 Kit
/// `userInfo` 是服务端载荷（`{"imageId": "clx…"}`）与 Apple 保留键混在一起的字典：
/// 缺字段、类型不对、旧版本载荷都可能出现。这类"逐字段校验"的错误只会表现为
/// "点了通知没反应"，在真机上无法调试 —— 放进 Kit 才能用 `swift test` 钉住负例。
///
/// ## 为什么限制字符集
/// `imageId` 会被拼进 `GET /api/public/v1/images/:id` 的路径。载荷是外部输入
/// （Push Console 或任何拿到 .p8 的人都能构造），限制成服务端 cuid 实际使用的字符集，
/// 就不会出现 `../` 之类的路径段。服务端图片 id 是 `@default(cuid())`（字母数字），
/// 这个集合只多允许 `-` / `_`，不会误伤。
public struct PushRoute: Equatable, Sendable {
    public let imageId: String

    public init(imageId: String) {
        self.imageId = imageId
    }

    /// 从通知的 `userInfo` 解析。缺字段 / 类型不对 / 空串 / 非法字符一律返回 nil。
    public init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["imageId"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidImageId(trimmed) else { return nil }
        self.init(imageId: trimmed)
    }

    static func isValidImageId(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }
}

/// 冷启动时的"待跳转"持有者。
///
/// ## 为什么需要它（而不是把 imageId 直接丢给界面）
/// 点通知拉起 App 时，`UNUserNotificationCenterDelegate` 的 `didReceive` 可能早于
/// SwiftUI 场景出现 —— 那一刻还没有 `previewTarget` 可以赋。先存住、等视图就绪再消费，
/// 才不会出现"点了通知只到首页"。
///
/// `take()` 是"取走即清空"：同一次跳转只消费一次，否则视图重建会重复跳转。
@Observable
@MainActor
public final class PushRouteInbox {

    public private(set) var pending: PushRoute?

    public init() {}

    public func put(_ route: PushRoute) {
        pending = route
    }

    public func take() -> PushRoute? {
        defer { pending = nil }
        return pending
    }
}

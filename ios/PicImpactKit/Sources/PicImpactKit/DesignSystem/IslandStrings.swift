import Foundation

/// 文案查表。
///
/// 优先走系统本地化（iOS 上 `.xcstrings` 会被 Xcode 编译进 bundle）；
/// 取不到时回退到 `fallback` —— 那张表由 `scripts/ios-strings-swift.mjs`
/// 从 `messages/zh.json` 生成（与 Web 端同一份文案，365 条），因此不会漂移。
///
/// 为什么需要回退：macOS 的 `swift build`（单元测试的环境）**不编译** `.xcstrings`，
/// 没有回退表的话界面与测试里都会显示成 `Exif.basicInfo` 这种裸 key。
/// 这与图标那次的结论是同一条：**不要依赖 macOS 上不执行的构建步骤**。
public enum IslandStrings {

    public static func text(_ key: String) -> String {
        let localized = String(localized: String.LocalizationValue(key), bundle: .picImpactKit)
        if localized != key { return localized }
        return fallback[key] ?? key
    }

    /// 便于在断言里确认"确实取到了文案而不是裸 key"
    public static func hasValue(_ key: String) -> Bool {
        text(key) != key
    }
}

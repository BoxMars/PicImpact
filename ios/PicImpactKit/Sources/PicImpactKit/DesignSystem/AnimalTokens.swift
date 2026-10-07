import SwiftUI

/// ACNH 设计令牌。
///
/// **唯一真源是 `animal-island-ui` 编译产物里的 CSS 变量**（48 个 `--animal-*`）。
/// 这里把 CSS 原始值原样存下来（`rawCSS`），类型化的值全部从它**解析**得到 ——
/// 而不是再手抄一份。这样 `AnimalTokensTests` 里"逐条与编译产物对照"才有意义：
/// 两边不可能各自漂移。
///
/// 改令牌的唯一正确姿势：改 `rawCSS`，然后跑测试。测试会拿
/// `Tests/PicImpactKitTests/Fixtures/animal-tokens.json`（由
/// `node_modules/animal-island-ui/dist/index.css` 直接生成）逐条比对。
public enum AnimalTokens {

    /// 48 个 `--animal-*` 变量的原始 CSS 值。
    /// 键名与 CSS 变量一致（去掉前导 `--`）。
    public static let rawCSS: [String: String] = [
        "animal-bg-color": "#f8f8f0",
        "animal-bg-color-disabled": "#f0ece2",
        "animal-bg-color-secondary": "#f0e8d8",
        "animal-border-color": "#aaa69d",
        "animal-border-color-hover": "#827157",
        "animal-border-color-light": "#e8e2d6",
        "animal-border-radius-base": "18px",
        "animal-border-radius-lg": "24px",
        "animal-border-radius-sm": "16px",
        "animal-border-width": "2px",
        "animal-error-color": "#e05a5a",
        "animal-error-color-active": "#c94444",
        "animal-error-color-hover": "#e87878",
        "animal-font-family": #"Nunito, "Noto Sans SC", -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif !important"#,
        "animal-font-size-base": "14px",
        "animal-font-size-lg": "16px",
        "animal-font-size-sm": "12px",
        "animal-height-base": "40px",
        "animal-height-lg": "48px",
        "animal-height-sm": "32px",
        "animal-line-height-base": "1.5715",
        "animal-mask-bg": "rgba(0, 0, 0, .35)",
        "animal-motion-duration-base": ".25s",
        "animal-motion-duration-fast": ".15s",
        "animal-motion-duration-slow": ".35s",
        "animal-motion-ease": "cubic-bezier(.4, 0, .2, 1)",
        "animal-primary-color": "#19c8b9",
        "animal-primary-color-active": "#50b9ab",
        "animal-primary-color-bg": "#e6f9f6",
        "animal-primary-color-hover": "#3dd4c6",
        "animal-shadow-base": "0 3px 10px 0 rgba(61, 52, 40, .1)",
        "animal-shadow-lg": "0 8px 24px 0 rgba(61, 52, 40, .14)",
        "animal-shadow-sm": "0 2px 4px 0 rgba(61, 52, 40, .06)",
        "animal-spacing-lg": "16px",
        "animal-spacing-md": "12px",
        "animal-spacing-sm": "8px",
        "animal-spacing-xl": "24px",
        "animal-spacing-xs": "4px",
        "animal-success-color": "#6fba2c",
        "animal-success-color-active": "#5a9e1e",
        "animal-success-color-hover": "#85cc45",
        "animal-text-color": "#794f27",
        "animal-text-color-disabled": "#c4b89e",
        "animal-text-color-muted": "#794f27",
        "animal-text-color-secondary": "#9f927d",
        "animal-warning-color": "#f5c31c",
        "animal-warning-color-active": "#dba90e",
        "animal-warning-color-hover": "#f7d04a",
    ]

    // MARK: - 原始值

    public static func raw(_ key: String) -> String? { rawCSS[key] }

    // MARK: - 解析（可空版本供测试断言"每个键都能解析"）

    /// 解析 `#rgb` / `#rrggbb` / `#rrggbbaa` / `rgb(...)` / `rgba(...)`
    public static func parseColor(_ key: String) -> Color? {
        guard let raw = rawCSS[key] else { return nil }
        return CSSColor.parse(raw)
    }

    /// 解析 `18px` / `2px` 这类长度
    public static func parseLength(_ key: String) -> CGFloat? {
        guard let raw = rawCSS[key] else { return nil }
        let digits = raw.replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(digits) else { return nil }
        return CGFloat(value)
    }

    /// 解析 `.25s` / `0.25s` 这类时长
    public static func parseSeconds(_ key: String) -> Double? {
        guard let raw = rawCSS[key] else { return nil }
        let digits = raw.replacingOccurrences(of: "s", with: "").trimmingCharacters(in: .whitespaces)
        return Double(digits)
    }

    public static func parseDouble(_ key: String) -> Double? {
        guard let raw = rawCSS[key] else { return nil }
        return Double(raw)
    }

    // MARK: - 类型化访问器（视图里用这些，不要散写 hex）

    public static var bg: Color { parseColor("animal-bg-color") ?? .clear }
    public static var bgSecondary: Color { parseColor("animal-bg-color-secondary") ?? .clear }
    public static var bgDisabled: Color { parseColor("animal-bg-color-disabled") ?? .clear }

    public static var primary: Color { parseColor("animal-primary-color") ?? .clear }
    public static var primaryHover: Color { parseColor("animal-primary-color-hover") ?? .clear }
    public static var primaryActive: Color { parseColor("animal-primary-color-active") ?? .clear }
    public static var primaryBG: Color { parseColor("animal-primary-color-bg") ?? .clear }

    public static var success: Color { parseColor("animal-success-color") ?? .clear }
    public static var warning: Color { parseColor("animal-warning-color") ?? .clear }
    public static var error: Color { parseColor("animal-error-color") ?? .clear }
    /// 错误色的"厚度色"（按下/描边用），与 `primaryActive` 同属组件层签名值
    public static var errorActive: Color { parseColor("animal-error-color-active") ?? .clear }

    /// 主文字色。**注意是深棕 `#794f27`，不是黑。**
    public static var text: Color { parseColor("animal-text-color") ?? .clear }
    /// 次级文字（label）
    public static var textSecondary: Color { parseColor("animal-text-color-secondary") ?? .clear }
    public static var textDisabled: Color { parseColor("animal-text-color-disabled") ?? .clear }

    public static var border: Color { parseColor("animal-border-color") ?? .clear }
    public static var borderLight: Color { parseColor("animal-border-color-light") ?? .clear }
    public static var mask: Color { parseColor("animal-mask-bg") ?? .clear }

    public static var radiusSM: CGFloat { parseLength("animal-border-radius-sm") ?? 0 }
    public static var radius: CGFloat { parseLength("animal-border-radius-base") ?? 0 }
    public static var radiusLG: CGFloat { parseLength("animal-border-radius-lg") ?? 0 }
    public static var borderWidth: CGFloat { parseLength("animal-border-width") ?? 0 }

    public static var fontSM: CGFloat { parseLength("animal-font-size-sm") ?? 0 }
    public static var fontSize: CGFloat { parseLength("animal-font-size-base") ?? 0 }
    public static var fontLG: CGFloat { parseLength("animal-font-size-lg") ?? 0 }
    public static var lineHeight: CGFloat { CGFloat(parseDouble("animal-line-height-base") ?? 0) }

    public static var heightSM: CGFloat { parseLength("animal-height-sm") ?? 0 }
    public static var height: CGFloat { parseLength("animal-height-base") ?? 0 }
    public static var heightLG: CGFloat { parseLength("animal-height-lg") ?? 0 }

    public static var spacingXS: CGFloat { parseLength("animal-spacing-xs") ?? 0 }
    public static var spacingSM: CGFloat { parseLength("animal-spacing-sm") ?? 0 }
    public static var spacingMD: CGFloat { parseLength("animal-spacing-md") ?? 0 }
    public static var spacingLG: CGFloat { parseLength("animal-spacing-lg") ?? 0 }
    public static var spacingXL: CGFloat { parseLength("animal-spacing-xl") ?? 0 }

    public static var motionFast: Double { parseSeconds("animal-motion-duration-fast") ?? 0 }
    public static var motionBase: Double { parseSeconds("animal-motion-duration-base") ?? 0 }
    public static var motionSlow: Double { parseSeconds("animal-motion-duration-slow") ?? 0 }

    /// 测试用来遍历断言"每个键都能解析"的分组
    public static let colorKeys: [String] = rawCSS.keys.filter { $0.contains("color") || $0.contains("bg") || $0.contains("mask") }.sorted()
    public static let lengthKeys: [String] = rawCSS.keys.filter { rawCSS[$0]?.hasSuffix("px") == true }.sorted()
    public static let durationKeys: [String] = ["animal-motion-duration-fast", "animal-motion-duration-base", "animal-motion-duration-slow"]
}

/// ACNH 的**视觉签名值**。
///
/// 这些**不在** 48 个 `--animal-*` 变量里 —— 它们是组件层硬编码在
/// `animal-island-ui` 的 CSS 与项目代码里的值。单独放一处，避免散落。
public enum AnimalSignatures {

    /// 纸卡背景（`CardColor.default` = `rgb(247,243,223)`，见 AI_USAGE.md §1.5）
    public static let cardPaper = Color(red: 247 / 255, green: 243 / 255, blue: 223 / 255)

    /// 纸卡文字色
    public static let cardText = Color(red: 0x72 / 255, green: 0x5D / 255, blue: 0x42 / 255)

    /// 纸卡描边 —— 全库最高频的颜色（编译 CSS 中出现 64 次）
    public static let cardBorder = Color(red: 0xC4 / 255, green: 0xB8 / 255, blue: 0x9E / 255)

    /// 纸卡的"厚度色"，比描边略深，叠出立体感
    public static let cardShadowHard = Color(red: 0xBD / 255, green: 0xAE / 255, blue: 0xA0 / 255)

    /// 纸卡的柔阴影
    public static let cardShadowSoft = Color(red: 121 / 255, green: 79 / 255, blue: 39 / 255).opacity(0.08)

    /// 立体阴影的偏移量。**radius 必须为 0** —— 这是实心偏移（"厚度"），不是模糊投影。
    public static let cardShadowOffsetY: CGFloat = 3
    public static let cardShadowSoftRadius: CGFloat = 16
    public static let cardShadowSoftOffsetY: CGFloat = 4

    public static let cardCornerRadius: CGFloat = 18
    public static let cardBorderWidth: CGFloat = 2
}

// MARK: - CSS 颜色解析

enum CSSColor {
    static func parse(_ raw: String) -> Color? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { return parseHex(value) }
        if value.hasPrefix("rgb") { return parseRGB(value) }
        return nil
    }

    private static func parseHex(_ value: String) -> Color? {
        var hex = String(value.dropFirst())
        // #abc → #aabbcc
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let number = UInt64(hex, radix: 16) else { return nil }
        switch hex.count {
        case 6:
            return Color(
                red: Double((number >> 16) & 0xFF) / 255,
                green: Double((number >> 8) & 0xFF) / 255,
                blue: Double(number & 0xFF) / 255
            )
        case 8:
            return Color(
                red: Double((number >> 24) & 0xFF) / 255,
                green: Double((number >> 16) & 0xFF) / 255,
                blue: Double((number >> 8) & 0xFF) / 255,
                opacity: Double(number & 0xFF) / 255
            )
        default:
            return nil
        }
    }

    /// 支持 `rgb(1,2,3)` 与 `rgba(0, 0, 0, .35)`（注意 alpha 可能是 `.35` 省略前导 0）
    private static func parseRGB(_ value: String) -> Color? {
        guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") else { return nil }
        let inner = value[value.index(after: open)..<close]
        let parts = inner
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { Double($0) }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        return Color(
            red: parts[0] / 255,
            green: parts[1] / 255,
            blue: parts[2] / 255,
            opacity: parts.count == 4 ? parts[3] : 1
        )
    }
}

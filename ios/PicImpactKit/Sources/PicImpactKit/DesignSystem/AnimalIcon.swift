import SwiftUI

public extension Bundle {
    /// PicImpactKit 的资源 bundle（含 ACNH 图标 SVG）。
    ///
    /// 为什么需要显式暴露：`Bundle.module` 只在**本包内部**解析为包资源 bundle；
    /// 在测试 target 里写 `.module` 拿到的是**测试自己的** bundle（只有 Fixtures），
    /// 于是断言会以"文件不存在"的形式失败，看起来像是资源没打包。
    static var picImpactKit: Bundle { .module }
}

/// ACNH 图标名。对应 `animal-island-ui` 的 `Icon` 组件在卡片里用到的那些。
///
/// 素材由 `scripts/ios-icons.mjs` 从 `animal-island-ui/dist/files/*.svg` 提取，
/// 以**普通资源文件**（不是 asset catalog）随包分发 —— 原因见 `SVGIcon` 的注释。
public enum AnimalIconName: String, CaseIterable, Sendable {
    case camera = "icon-camera"
    case variant = "icon-variant"
    case miles = "icon-miles"
    case map = "icon-map"
    case critterpedia = "icon-critterpedia"
    case diy = "icon-diy"
    case helicopter = "icon-helicopter"
    case shopping = "icon-shopping"
}

/// 图标尺寸。两个值都取自 Web 端：EXIF 芯片里 14，操作行里 18。
public enum AnimalIconSize {
    public static let chip: CGFloat = 14
    public static let action: CGFloat = 18
}

/// 解析结果缓存。图标只有 8 个，解析一次即可；用锁保证只解析一次。
final class AnimalIconCache: @unchecked Sendable {
    static let shared = AnimalIconCache()
    private let lock = NSLock()
    private var storage: [String: SVGIcon.Icon?] = [:]

    func icon(named name: String) -> SVGIcon.Icon? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = storage[name] { return cached }
        let parsed = load(named: name)
        storage[name] = parsed
        return parsed
    }

    private func load(named name: String) -> SVGIcon.Icon? {
        let url = Bundle.picImpactKit.url(forResource: "Icons/\(name)", withExtension: "svg")
            ?? Bundle.picImpactKit.url(forResource: name, withExtension: "svg")
        guard let url, let source = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return SVGIcon.parse(source)
    }
}

/// ACNH 图标。
///
/// ## 为什么自己渲染而不是 `Image(name:)` + asset catalog
/// 见 `SVGIcon` 的注释：macOS 的 `swift build` 不跑 actool，资源不会编译成 `Assets.car`，
/// 于是那个方案在本地无法验证，而图标缺失又是**静默**的（界面上只是少一块）。
/// 自己渲染矢量路径则两端行为一致，且能在 macOS 上直接断言渲染结果。
///
/// ## 为什么不能像 SF Symbols 那样当单色模板用
/// 这些是**彩色素材**：`icon-camera` 里同时有 `#FF66AD` 粉、`#9364DE` 紫、`#4C3C33` 棕。
/// 染色会把它压成一个纯色剪影，形状与配色就都不是 ACNH 了。
public struct AnimalIcon: View {
    private let name: AnimalIconName
    private let size: CGFloat

    public init(_ name: AnimalIconName, size: CGFloat) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        // 复用通用 SVG 资源视图：缩放/居中/evenodd 的逻辑只写一份
        SVGAsset(name.rawValue)
            .frame(width: size, height: size)
    }
}

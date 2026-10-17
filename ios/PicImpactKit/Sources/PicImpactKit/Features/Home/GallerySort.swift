import Foundation

/// 画廊的排序选项。
///
/// ## 为什么需要它
/// 首页默认按 **EXIF 拍摄时间从新到旧** 排（服务端 `HOME_IMAGE_SORTING_ORDER`）。于是
/// 「刚刚上传了一张十年前拍的老照片」时，推送告诉你有了新照片，点进去也看得到，
/// 但**一返回列表它就埋在后面** —— 通知与可见性是错位的。这个选项就是给那种照片用的。
///
/// ## 取值与契约
/// rawValue 就是公开 API `GET /images?sort=` 的取值（见 `docs/superpowers/api/public-api-v1.md`）。
/// 术语与 Web 后台一致（`messages/zh.json` 的 `Album.uploadTimeNewToOld` 等四条）：
///
/// - **上传时间** = 入库时间（`images.created_at`）
/// - **拍摄时间** = EXIF 的 `data_time`
public enum GallerySort: String, CaseIterable, Sendable {
    /// 不带 `sort` 参数 = 服务端默认（首页即「拍摄时间从新到旧」）。
    ///
    /// ⚠️ 空串这个 rawValue 是**故意的**：默认档必须**完全不发** `sort` 参数，
    /// 这样请求 URL 与老版本逐字节相同 —— 服务端的 `unstable_cache` 与边缘缓存都继续命中，
    /// 不会因为"多了个空参数"而把缓存劈成两份。
    case serverDefault = ""

    /// 上传时间从新到旧（`sort=uploaded_desc`）
    case uploadedDesc = "uploaded_desc"

    /// 界面上暴露的两项。契约支持四个取值，另外两个（旧→新）等有人要再加，不必改服务端。
    public static var selectable: [GallerySort] { [.serverDefault, .uploadedDesc] }

    /// 拼进 query 的值；`nil` = **不要带这个参数**
    public var queryValue: String? {
        self == .serverDefault ? nil : rawValue
    }

    /// 界面文案的 key（四语言已在 `messages/*.json` 与生成表里，**不需要新增文案**）
    public var labelKey: String {
        switch self {
        case .serverDefault: "Album.shootTimeNewToOld"
        case .uploadedDesc: "Album.uploadTimeNewToOld"
        }
    }
}

/// 排序偏好的持久化。
///
/// 为什么不是 `@AppStorage`：那个属性包装器在 Kit（`swift test` 跑的是 macOS 目标）里没法注入替身，
/// 测不了。这里照 `Cache/SeedInstaller.swift` 的既有写法，把 `UserDefaults` 作为参数传进来，
/// 测试用独立 suite 隔离（见 `SeedInstallerTests`）。
///
/// `@unchecked Sendable` 的理由：`UserDefaults` 是**文档明确线程安全**的，只是 Foundation 还没给它
/// 标 `Sendable`。这里只存一个引用、不做任何跨线程的可变共享，所以这个标记是安全的
/// —— 不加它就没法把偏好传进 `persistSort` 那个 `@Sendable` 闭包。
public struct GallerySortPreference: @unchecked Sendable {
    public static let storageKey = "gallery.sort"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读偏好。**认不出来的值一律回落到默认档** —— 旧版本写的键、被手工改坏的值都不该让界面打不开。
    public func load() -> GallerySort {
        guard let raw = defaults.string(forKey: Self.storageKey),
              let sort = GallerySort(rawValue: raw)
        else { return .serverDefault }
        return sort
    }

    public func save(_ sort: GallerySort) {
        defaults.set(sort.rawValue, forKey: Self.storageKey)
    }
}

import Foundation

/// 相册 DTO（对应公开 API v1 的 `AlbumDTO`）
public struct AlbumDTO: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// 形如 `/daily`。请求图片列表时作为 `album` 参数回传
    public let value: String
    public let detail: String?
    /// Web 端的画廊主题 `'0' | '1' | '2'`。
    ///
    /// **iOS 刻意忽略它** —— 产品只做 ACNH 岛屿卡一种呈现（见设计文档 §2.2）。
    /// 保留解码是为了契约完整性，避免将来要支持时又得加字段。
    public let theme: String
    public let license: String?
}

/// 站点配置 DTO（对应 `GET /config` 的 data）。
///
/// 客户端**必须先请求它**：`features` 承担能力协商职责 ——
/// App 依据开关决定显示哪些功能，而不是靠硬编码版本号去猜。
public struct SiteConfigDTO: Decodable, Sendable, Equatable {
    public let apiVersion: String
    /// 分页大小。**不要硬编码**，从这里读
    public let pageSize: Int
    public let site: Site
    public let features: Features

    public struct Site: Decodable, Sendable, Equatable {
        public let title: String
        public let author: String
        public let logoUrl: String
        public let faviconUrl: String
        /// 首页画廊风格。`'1'` = ACNH 岛屿卡
        public let indexStyle: String
    }

    public struct Features: Decodable, Sendable, Equatable {
        /// 是否允许下载原图
        public let download: Bool
        /// 是否提供查看原图入口
        public let origin: Bool
        /// 影调分析（客户端本地计算）
        public let toneAnalysis: Bool
        /// Live Photo
        public let livePhoto: Bool
        /// 地图页
        public let map: Bool
    }
}

/// 供预览页/测试使用的空配置，避免视图层到处写 `!`
public extension SiteConfigDTO.Features {
    static let none = SiteConfigDTO.Features(
        download: false, origin: false, toneAnalysis: false, livePhoto: false, map: false
    )
}

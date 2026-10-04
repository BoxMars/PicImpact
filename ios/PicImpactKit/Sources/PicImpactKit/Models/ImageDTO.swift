import CoreGraphics
import Foundation

/// 图片 DTO（对应公开 API v1 的 `ImageDTO`，契约见 docs/superpowers/api/public-api-v1.md）
///
/// 解码策略上有意做了一点防御（`labels` 容忍 null、字符串字段容忍缺失），
/// 但**不做无差别兜底** —— 字段整体消失属于破坏性变更，应由 Web 侧的
/// `pnpm api:verify-contract` 拦在服务端，而不是在这里被静默吞掉。
public struct ImageDTO: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    /// 原始文件名，保存到相册时用作文件名
    public let imageName: String
    /// 原图
    public let url: String
    /// 800px 缩略图。**列表一律用它**
    public let previewURL: String
    /// Live Photo 的视频
    public let videoURL: String
    public let blurhash: String
    public let width: Int
    public let height: Int
    public let title: String
    public let detail: String
    /// 1 = 普通图片，2 = Live Photo
    public let type: Int
    public let labels: [String]
    /// 经纬度。**保持字符串**（服务端列类型就是 String），缺失时是空串
    public let lon: String
    public let lat: String
    public let exif: EXIF?
    /// 相册许可协议，卡片下载/分享提示文案会用到
    public let albumLicense: String?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case imageName
        case url
        case previewURL = "previewUrl"
        case videoURL = "videoUrl"
        case blurhash
        case width
        case height
        case title
        case detail
        case type
        case labels
        case lon
        case lat
        case exif
        case albumLicense
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        imageName = (try? c.decode(String.self, forKey: .imageName)) ?? ""
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        previewURL = (try? c.decode(String.self, forKey: .previewURL)) ?? ""
        videoURL = (try? c.decode(String.self, forKey: .videoURL)) ?? ""
        blurhash = (try? c.decode(String.self, forKey: .blurhash)) ?? ""
        width = (try? c.decode(Int.self, forKey: .width)) ?? 0
        height = (try? c.decode(Int.self, forKey: .height)) ?? 0
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
        type = (try? c.decode(Int.self, forKey: .type)) ?? 1
        // 服务端已把 labels 归一化为 array，这里再兜一层 null
        // （`try?` 会把 decodeIfPresent 的双层可选压成单层）
        labels = (try? c.decodeIfPresent([String].self, forKey: .labels)) ?? []
        lon = (try? c.decode(String.self, forKey: .lon)) ?? ""
        lat = (try? c.decode(String.self, forKey: .lat)) ?? ""
        exif = try? c.decodeIfPresent(EXIF.self, forKey: .exif)
        albumLicense = try? c.decodeIfPresent(String.self, forKey: .albumLicense)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

public extension ImageDTO {
    /// 非 1 即 Live Photo（与 Web 端 `preview-image.tsx` 的判定一致）
    var isLivePhoto: Bool { type != 1 }

    /// 列表与卡片一律取缩略图；为空时回退原图 —— 复刻 Web 的 `preview_url || url`
    var displayURL: URL? {
        let candidate = previewURL.isEmpty ? url : previewURL
        return candidate.isEmpty ? nil : URL(string: candidate)
    }

    var originalURL: URL? { url.isEmpty ? nil : URL(string: url) }

    var videoResourceURL: URL? { videoURL.isEmpty ? nil : URL(string: videoURL) }

    /// 宽高比。缺尺寸时返回 1（正方形），避免出现 NaN / 0 导致布局崩坏
    var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    /// 地图页只展示有经纬度的图片（与 Web 的 `fetchMapImages` 语义一致）
    var hasCoordinate: Bool {
        guard let lat = Double(lat), let lon = Double(lon) else { return false }
        return lat != 0 || lon != 0
    }
}

/// 单页图片列表（对应 `GET /images` 的 data）
public struct ImagePageDTO: Decodable, Sendable, Equatable {
    public let list: [ImageDTO]
    public let page: Int
    /// 页大小由服务端决定（固定 24）。**不要硬编码**，从响应里读。
    public let pageSize: Int
    /// 总**页数**（不是总条数）
    public let pageTotal: Int
    /// 判断是否还有下一页请用它，不要自己拿 page 和 pageTotal 算
    public let hasMore: Bool
    /// 仅在 album 模式返回
    public let album: String?
}

/// 相机 / 镜头筛选值（对应 `GET /filters`）
public struct FiltersDTO: Decodable, Sendable, Equatable {
    public let cameras: [String]
    public let lenses: [String]
}

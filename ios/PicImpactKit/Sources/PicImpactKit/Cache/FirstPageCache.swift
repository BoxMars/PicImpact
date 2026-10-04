import Foundation

/// 首屏数据的磁盘缓存，用来实现"**先加载缓存数据，再后台检查是否更新**"。
///
/// ## 为什么不直接用系统的 `URLCache`
/// 线上 `/api/public/v1/*` 的响应头是 `cache-control: public`，但**既没有 max-age、
/// 也没有 ETag**（实测）。系统缓存无法判断新鲜度，只能重新请求，给不了"立刻出旧数据"的效果。
/// 所以在 App 层自己存一份**解析后**的结果。
///
/// ## 只缓存第一页
/// 第一页是"打开就有内容"的关键，也是请求量最大的一次（实测 1.5–3.4s）。
/// 翻页数据不缓存 —— 它只在用户滚动时用，缓存收益小、失效复杂度高。
///
/// 缓存位置在 Caches 目录：系统空间紧张时可以回收，符合"可重新下载"的语义。
public actor FirstPageCache {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = APIDecoding.makeDecoder()

    /// 用 Caches 目录下的默认位置。拿不到目录时返回 nil（缓存不可用，但不影响功能）。
    ///
    /// `key` 用于区分不同的查询条件（相册 / 标签），避免互相覆盖。
    public init?(namespace: String = "PicImpactMetadata", key: String) {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        self.init(directory: base.appendingPathComponent(namespace, isDirectory: true), key: key)
    }

    /// 指定目录（测试用临时目录）。
    public init(directory: URL, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("\(key).json")
    }

    /// 读缓存。没有、读不出来、或格式变了都返回 nil —— 调用方据此走正常加载。
    public func load() -> ImagePageDTO? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(ImagePageDTO.self, from: data)
    }

    public func save(_ page: ImagePageDTO) {
        guard let data = try? encoder.encode(page) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

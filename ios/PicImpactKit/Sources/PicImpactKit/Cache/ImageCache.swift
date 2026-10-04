import Foundation

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

/// 图片缓存的容量与落盘位置。
public struct ImageCacheConfiguration: Sendable {
    /// 内存缓存上限。画廊是重度用图的场景，但要防止大图把内存吃满
    public var memoryLimitBytes: Int
    /// 磁盘缓存上限
    public var diskLimitBytes: Int
    /// 磁盘缓存目录
    public var diskDirectory: URL

    public init(
        memoryLimitBytes: Int = 96 * 1024 * 1024,
        diskLimitBytes: Int = 512 * 1024 * 1024,
        diskDirectory: URL
    ) {
        self.memoryLimitBytes = memoryLimitBytes
        self.diskLimitBytes = diskLimitBytes
        self.diskDirectory = diskDirectory
    }

    /// 默认落在 Caches 目录（系统可在空间紧张时回收，符合"可重新下载"的语义）
    public static func `default`(namespace: String = "PicImpactImages") -> ImageCacheConfiguration {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return ImageCacheConfiguration(diskDirectory: base.appendingPathComponent(namespace, isDirectory: true))
    }
}

/// 磁盘缓存。
///
/// 关键设计：**按"最后访问时间"做 LRU 淘汰**，而不是按写入时间。
/// 资产域返回 `Cache-Control: immutable` 且文件名是内容哈希，所以条目永不过期 ——
/// 唯一需要管的就是容量。若按写入时间淘汰，会反复丢掉最常看的那几张。
public actor DiskCacheStore {
    private let configuration: ImageCacheConfiguration
    private let fileManager = FileManager.default

    public init(configuration: ImageCacheConfiguration) {
        self.configuration = configuration
        try? fileManager.createDirectory(
            at: configuration.diskDirectory,
            withIntermediateDirectories: true
        )
    }

    /// URL → 文件名。用哈希是因为 URL 含 `/` 与 `?`，不能直接当文件名
    private func fileURL(for url: URL) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Data(url.absoluteString.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return configuration.diskDirectory.appendingPathComponent(String(hash, radix: 16))
    }

    public func data(for url: URL) -> Data? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file) else { return nil }
        // 触碰访问时间，供 LRU 使用
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    public func store(_ data: Data, for url: URL) {
        let file = fileURL(for: url)
        try? data.write(to: file, options: .atomic)
        evictIfNeeded()
    }

    public func removeAll() {
        try? fileManager.removeItem(at: configuration.diskDirectory)
        try? fileManager.createDirectory(
            at: configuration.diskDirectory,
            withIntermediateDirectories: true
        )
    }

    /// 当前磁盘占用（测试用）
    public func currentSizeBytes() -> Int {
        guard let files = try? fileManager.contentsOfDirectory(
            at: configuration.diskDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { sum, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + size
        }
    }

    /// 超出上限时，按访问时间从旧到新删，直到回到上限以内
    private func evictIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: configuration.diskDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        let entries: [(url: URL, size: Int, accessed: Date)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                return nil
            }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }

        var total = entries.reduce(0) { $0 + $1.size }
        guard total > configuration.diskLimitBytes else { return }

        for entry in entries.sorted(by: { $0.accessed < $1.accessed }) {
            guard total > configuration.diskLimitBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

/// 图片缓存：内存 → 磁盘 → 网络（三级）。
///
/// 列表一律取 800px 缩略图（`previewUrl`）；进入预览页再后台拉原图。
/// 这是 Web 端的行为（交叉淡入），也是体感的关键。
public actor ImageCache {
    private let configuration: ImageCacheConfiguration

    /// 内存缓存。`NSCache` 自带按 cost 淘汰与内存压力响应，比手写 LRU 更稳。
    private let memory: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        return cache
    }()

    private let disk: DiskCacheStore

    public init(configuration: ImageCacheConfiguration = .default()) {
        self.configuration = configuration
        self.disk = DiskCacheStore(configuration: configuration)
        let limit = configuration.memoryLimitBytes
        memory.totalCostLimit = limit
        memory.countLimit = 256
    }

    /// 取数据。命中内存或磁盘直接返回，都未命中返回 nil（由上层决定是否下载）
    public func cachedData(for url: URL) async -> Data? {
        let key = url.absoluteString as NSString
        if let data = memory.object(forKey: key) {
            return data as Data
        }
        guard let data = await disk.data(for: url) else { return nil }
        // 回填内存
        memory.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    public func store(_ data: Data, for url: URL) async {
        let key = url.absoluteString as NSString
        memory.setObject(data as NSData, forKey: key, cost: data.count)
        await disk.store(data, for: url)
    }

    public func clearMemory() {
        memory.removeAllObjects()
    }

    public func clearAll() async {
        memory.removeAllObjects()
        await disk.removeAll()
    }

    public func diskSizeBytes() async -> Int {
        await disk.currentSizeBytes()
    }
}

/// 图片加载：请求合并 + 三级缓存。
///
/// **请求合并**很重要：画廊滚动的同一时刻，多个视图可能请求同一张图
/// （例如缩略图与预览图同时要），没有它就会重复下载。
public actor ImageLoader {
    public enum LoadError: Error, Sendable {
        case badStatus(Int)
        case transport(String)
    }

    private let cache: ImageCache
    private let session: URLSession
    private var inFlight: [String: Task<Data, Error>] = [:]

    public init(cache: ImageCache = ImageCache(), session: URLSession = .shared) {
        self.cache = cache
        self.session = session
    }

    /// 已解码图片的缓存（避免重复解码大图）
    private var decoded: [String: PlatformImage] = [:]

    public func data(for url: URL) async throws -> Data {
        if let cached = await cache.cachedData(for: url) {
            return cached
        }
        let key = url.absoluteString
        // 合并同一 URL 的并发请求
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task<Data, Error> { [session] in
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw LoadError.badStatus(http.statusCode)
            }
            return data
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let data = try await task.value
            await cache.store(data, for: url)
            return data
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.transport(error.localizedDescription)
        }
    }

    /// 取已解码图片（内存中只保留解码结果，未命中则下载并解码）
    public func image(for url: URL) async throws -> PlatformImage {
        let key = url.absoluteString
        if let cached = decoded[key] { return cached }
        let data = try await data(for: url)
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { throw LoadError.transport("图片解码失败") }
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { throw LoadError.transport("图片解码失败") }
        #else
        throw LoadError.transport("当前平台不支持图片解码")
        #endif
        decoded[key] = image
        return image
    }

    public func clearMemory() async {
        decoded.removeAll()
        await cache.clearMemory()
    }
}

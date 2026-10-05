import Foundation

/// 打包种子（seed）的安装器。
///
/// `scripts/ios-seed.py` 在**每次构建**时把站点当前的**全部 JSON 元数据**与**全部预览图**
/// （56 张，约 2.5 MB）放进 App 包内的 `Seed/`。这里在首次启动（或种子版本变化时）
/// 把它们灌进本地缓存：
///
///   * 元数据 → `FirstPageCache`：首屏立刻有内容，不必等网络往返（线上首次约 4 秒）
///   * 预览图 → `ImageCache`：**走它自己的键推导**，不在这里复刻缓存键
///     （两边各算一套哈希迟早对不上，缓存就永远命不中）
///
/// 之后完全走既有逻辑：缓存先出、后台再校验。
public enum SeedInstaller {
    public struct Seed: Decodable, Sendable {
        public let generatedAt: String
        public let pages: [PageEnvelope]
        /// previewUrl → 资源文件名
        public let imageFiles: [String: String]
    }

    /// 种子里的每一页都是 API 原样响应，取 `data` 即可得到 `ImagePageDTO`。
    public struct PageEnvelope: Decodable, Sendable {
        public let data: ImagePageDTO
    }

    /// 装过的种子版本。用 `generatedAt` 而不是布尔值：每次重新构建都会刷新它，
    /// 所以"装了新版本 App"会重新灌一次，而日常启动几乎零开销。
    static let installedVersionKey = "seed.installedVersion"

    /// - Returns: 本次是否真的执行了安装（版本未变时返回 false）
    @discardableResult
    public static func installIfNeeded(
        cache: ImageCache,
        metadata: FirstPageCache?,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        guard let seed = loadSeed(bundle: bundle) else { return false }
        guard defaults.string(forKey: installedVersionKey) != seed.generatedAt else { return false }

        // 元数据只在缓存**为空**时铺：打包快照可能比用户手里的缓存旧，
        // 覆盖反而是倒退。而且后台校验会立刻跟上，不铺也不会缺内容。
        if let metadata, let first = seed.pages.first, await metadata.load() == nil {
            await metadata.save(first.data)
        }

        var installed = 0
        for (urlString, file) in seed.imageFiles {
            let ns = file as NSString
            guard let url = URL(string: urlString),
                  let fileURL = bundle.url(
                      forResource: ns.deletingPathExtension,
                      withExtension: ns.pathExtension,
                      subdirectory: "Seed/images"
                  ),
                  let bytes = try? Data(contentsOf: fileURL)
            else { continue }
            await cache.store(bytes, for: url)
            installed += 1
        }

        defaults.set(seed.generatedAt, forKey: installedVersionKey)
        return installed > 0 || !seed.pages.isEmpty
    }

    static func loadSeed(bundle: Bundle) -> Seed? {
        guard let url = bundle.url(forResource: "seed", withExtension: "json", subdirectory: "Seed"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Seed.self, from: data)
    }
}

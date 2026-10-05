import Foundation
import Testing
@testable import PicImpactKit

/// 打包种子的安装逻辑。
///
/// 这是**启动路径**上的代码：装错了最坏情况是应用打不开，所以必须有断言，
/// 而且要用真实的包结构（`Seed/seed.json` + `Seed/images/*`）来测，不能用替身。
@Suite("打包种子安装")
struct SeedInstallerTests {
    private let previewURL = URL(string: "https://example.com/preview/cehzhhvi.webp")!

    /// 造一个最小的包：Info.plist + Seed/seed.json + Seed/images/00.webp
    private func makeBundle(imageBytes: Data = Data("FAKE-WEBP".utf8)) throws -> (Bundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seedtest-\(UUID().uuidString)")
        let imagesDir = root.appendingPathComponent("Seed/images")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        // Bundle(path:) 需要一个像包一样的目录
        let plist: [String: Any] = [
            "CFBundleIdentifier": "test.seed.\(UUID().uuidString)",
            "CFBundleName": "seedtest",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))

        try imageBytes.write(to: imagesDir.appendingPathComponent("00.webp"))

        let page = ImagePageDTO(list: [], page: 1, pageSize: 24, pageTotal: 1, hasMore: false, album: nil)
        let seed: [String: Any] = [
            "generatedAt": "2026-10-05T13:19:29+0800",
            "pages": [["data": try JSONSerialization.jsonObject(with: JSONEncoder().encode(page))]],
            "imageFiles": [previewURL.absoluteString: "00.webp"],
        ]
        try JSONSerialization.data(withJSONObject: seed)
            .write(to: root.appendingPathComponent("Seed/seed.json"))

        guard let bundle = Bundle(path: root.path) else { throw TestError.bundle }
        return (bundle, root)
    }

    private enum TestError: Error { case bundle, missing }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "seedtest-\(UUID().uuidString)")!
    }

    @Test("首次安装：元数据进首屏缓存，预览图进图片缓存")
    func installsOnFirstRun() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = FirstPageCache(directory: root.appendingPathComponent("meta"), key: "first-page")
        let cache = ImageCache()

        let didInstall = await SeedInstaller.installIfNeeded(
            cache: cache, metadata: metadata, bundle: bundle, defaults: makeDefaults()
        )

        #expect(didInstall, "首次应当安装")
        let page = await metadata.load()
        #expect(page?.page == 1, "首屏元数据应当被铺上")
        let bytes = await cache.cachedData(for: previewURL)
        #expect(bytes == Data("FAKE-WEBP".utf8), "预览图应当按 **previewUrl** 键写进缓存")
    }

    @Test("同一版本不重复安装（日常启动零开销）")
    func doesNotReinstallSameVersion() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = FirstPageCache(directory: root.appendingPathComponent("meta"), key: "first-page")
        let cache = ImageCache()
        let defaults = makeDefaults()

        let first = await SeedInstaller.installIfNeeded(cache: cache, metadata: metadata, bundle: bundle, defaults: defaults)
        let second = await SeedInstaller.installIfNeeded(cache: cache, metadata: metadata, bundle: bundle, defaults: defaults)
        #expect(first)
        #expect(second == false, "版本没变就不该再装一次")
    }

    @Test("已经更新过的缓存不被打包快照覆盖")
    func doesNotOverwriteNewerCache() async throws {
        let (bundle, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = FirstPageCache(directory: root.appendingPathComponent("meta"), key: "first-page")
        // 先放一份"用户已经更新过"的数据
        let newer = ImagePageDTO(list: [], page: 7, pageSize: 24, pageTotal: 9, hasMore: true, album: nil)
        await metadata.save(newer)

        _ = await SeedInstaller.installIfNeeded(
            cache: ImageCache(), metadata: metadata, bundle: bundle, defaults: makeDefaults()
        )
        let page = await metadata.load()
        #expect(page?.page == 7, "缓存非空时不该被种子覆盖（后台校验会负责刷新）")
    }

    @Test("包里没有种子时不崩、返回 false")
    func missingSeedIsSafe() async {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let bundle = Bundle(path: empty.path) ?? .main
        let didInstall = await SeedInstaller.installIfNeeded(
            cache: ImageCache(), metadata: nil, bundle: bundle, defaults: makeDefaults()
        )
        #expect(didInstall == false)
    }
}

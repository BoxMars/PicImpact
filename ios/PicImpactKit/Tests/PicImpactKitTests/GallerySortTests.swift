import Foundation
import Testing

@testable import PicImpactKit

/// 排序选项与偏好的单测。
///
/// 这里钉住两件"错了就会静默出问题"的事：
/// 1. **默认档不能带 `sort` 参数** —— 带上就等于换了个 URL，服务端缓存与边缘缓存都会被劈成两份；
/// 2. 切换排序必须**清掉磁盘首屏缓存** —— 那个缓存只按 `"first-page"` 一个 key 存，
///    不清的话重启会先把旧排序的第一页铺出来。
@Suite("T12 · 画廊排序")
@MainActor
struct GallerySortTests {

    /// 记录排序偏好落盘调用的哑替身（`@unchecked Sendable` + 锁：闭包要求 Sendable）
    final class SortRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [GallerySort] = []

        func record(_ sort: GallerySort) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(sort)
        }

        var values: [GallerySort] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func makeCache() -> FirstPageCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-sort-tests-\(UUID().uuidString)", isDirectory: true)
        return FirstPageCache(directory: directory, key: "first-page")
    }

    // MARK: - 取值映射

    @Test("默认档必须不带 sort 参数（请求 URL 要与老版本逐字节相同）")
    func defaultSendsNoSortParameter() {
        #expect(GallerySort.serverDefault.queryValue == nil)
        #expect(GallerySort.uploadedDesc.queryValue == "uploaded_desc")
    }

    @Test("界面只暴露两项，且文案 key 用的是仓库里既有的那两条")
    func selectableOptions() {
        #expect(GallerySort.selectable == [.serverDefault, .uploadedDesc])
        for option in GallerySort.selectable {
            #expect(IslandStrings.hasValue(option.labelKey), "\(option.labelKey) 取不到文案")
        }
        #expect(GallerySort.serverDefault.labelKey == "Album.shootTimeNewToOld")
        #expect(GallerySort.uploadedDesc.labelKey == "Album.uploadTimeNewToOld")
    }

    // MARK: - 偏好持久化

    @Test("偏好：没存过就是默认档；存了能读回来")
    func preferenceRoundTrip() {
        let suiteName = "gallery-sort-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preference = GallerySortPreference(defaults: defaults)
        #expect(preference.load() == .serverDefault, "没存过应当是默认档")

        preference.save(.uploadedDesc)
        #expect(GallerySortPreference(defaults: defaults).load() == .uploadedDesc)
    }

    @Test("偏好：认不出来的值回落到默认档（不让一个坏键把界面卡住）")
    func preferenceFallsBack() {
        let suiteName = "gallery-sort-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("uploaded_asc_but_never_shipped", forKey: GallerySortPreference.storageKey)
        #expect(GallerySortPreference(defaults: defaults).load() == .serverDefault)

        defaults.set(42, forKey: GallerySortPreference.storageKey)
        #expect(GallerySortPreference(defaults: defaults).load() == .serverDefault)
    }

    // MARK: - store 行为

    @Test("首次加载不带 sort；切换后所有请求都带上新排序")
    func storeThreadsSortThroughRequests() async {
        let source = StubGalleryDataSource(totalPages: 2, itemsPerPage: 3)
        let store = GalleryStore(dataSource: source)

        await store.loadFirstPageIfNeeded()
        #expect(await source.requestedSorts() == [nil], "默认档第一次请求不能带 sort")

        await store.setSort(.uploadedDesc)
        #expect(store.sort == .uploadedDesc)

        await store.loadNextPage()
        let sorts = await source.requestedSorts()
        #expect(sorts.dropFirst().allSatisfy { $0 == "uploaded_desc" }, "切换后每个请求都要带新排序：\(sorts)")
    }

    @Test("轮询也必须带当前排序（漏了就会「切完排序，一分钟后又变回默认」）")
    func pollCarriesSort() async {
        let source = StubGalleryDataSource(totalPages: 1, itemsPerPage: 3)
        let store = GalleryStore(dataSource: source, sort: .uploadedDesc)

        await store.pollForUpdates()

        // 第一次是轮询本身，第二次是它发现"总页数对不上"后触发的 refresh —— 两次都必须带排序
        let sorts = await source.requestedSorts()
        #expect(!sorts.isEmpty)
        #expect(sorts.allSatisfy { $0 == "uploaded_desc" }, "实际收到：\(sorts)")
    }

    @Test("切换排序会作废磁盘首屏缓存（失败时也不留旧排序的内容）")
    func switchingSortClearsDiskCache() async {
        let cache = makeCache()
        let source = StubGalleryDataSource(totalPages: 1, itemsPerPage: 3)
        let store = GalleryStore(dataSource: source, cache: cache)

        await store.loadFirstPageIfNeeded()
        #expect(await cache.load() != nil, "首屏缓存应当已写入")

        // 让切换后的重拉失败：如果缓存没被清掉，旧排序的内容就会留在盘上
        await source.setFailOnPage(1)
        await store.setSort(.uploadedDesc)

        #expect(await cache.load() == nil, "切换排序必须先清掉旧排序的缓存")
    }

    @Test("切到同一个排序：不发请求、不落盘（避免无意义的重拉）")
    func switchingToSameSortIsNoOp() async {
        let source = StubGalleryDataSource(totalPages: 1, itemsPerPage: 3)
        let recorder = SortRecorder()
        let store = GalleryStore(
            dataSource: source,
            sort: .uploadedDesc,
            persistSort: { recorder.record($0) }
        )

        await store.setSort(.uploadedDesc)

        #expect(await source.requestCount() == 0)
        #expect(recorder.values.isEmpty)
    }

    @Test("切换排序会把选择落盘")
    func switchingSortPersists() async {
        let source = StubGalleryDataSource(totalPages: 1, itemsPerPage: 3)
        let recorder = SortRecorder()
        let store = GalleryStore(
            dataSource: source,
            sort: .serverDefault,
            persistSort: { recorder.record($0) }
        )

        await store.setSort(.uploadedDesc)

        #expect(recorder.values == [.uploadedDesc])
    }
}

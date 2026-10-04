import Foundation
import Testing

@testable import PicImpactKit

/// 可编程的假数据源：记录请求了哪些页、可以注入延迟与错误。
actor StubGalleryDataSource: GalleryDataSource {
    private var pages: [Int: [ImageDTO]] = [:]
    private var requestedPages: [Int] = []
    private var failOnPage: Int?
    private var delayNanoseconds: UInt64 = 0
    private var totalPages = 1

    init(totalPages: Int = 1, itemsPerPage: Int = 3) {
        self.totalPages = totalPages
        for page in 1...max(1, totalPages) {
            pages[page] = (0..<itemsPerPage).map { index in
                Self.makeImage(id: "p\(page)-i\(index)")
            }
        }
    }

    static func makeImage(id: String, type: Int = 1) -> ImageDTO {
        let json = """
        {"id":"\(id)","imageName":"\(id).jpeg","url":"https://x/\(id).jpeg",
         "previewUrl":"https://x/\(id).webp","videoUrl":"","blurhash":"",
         "width":4000,"height":3000,"title":"t","detail":"","type":\(type),
         "labels":[],"lon":"","lat":"","exif":null,"albumLicense":null,
         "createdAt":"2026-10-03T11:36:14.539Z"}
        """
        return try! APIDecoding.makeDecoder().decode(ImageDTO.self, from: Data(json.utf8))
    }

    func setFailOnPage(_ page: Int?) { failOnPage = page }
    /// 替换某一页的内容（模拟"网站更新了"）。
    func replacePage(_ page: Int, with ids: [String]) {
        pages[page] = ids.map { Self.makeImage(id: $0) }
    }
    func setDelay(_ nanoseconds: UInt64) { delayNanoseconds = nanoseconds }
    func requested() -> [Int] { requestedPages }
    func requestCount() -> Int { requestedPages.count }

    func images(
        album: String?,
        tag: String?,
        camera: String?,
        lens: String?,
        page: Int
    ) async throws -> ImagePageDTO {
        requestedPages.append(page)
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        if failOnPage == page {
            throw APIError.transport("注入的失败")
        }
        let list = pages[page] ?? []
        return ImagePageDTO(
            list: list,
            page: page,
            pageSize: 24,
            pageTotal: totalPages,
            hasMore: page < totalPages,
            album: album
        )
    }
}

@Suite("T7 · 画廊分页状态机")
@MainActor
struct GalleryStoreTests {

    @Test("首次加载取第 1 页并填满列表")
    func loadsFirstPage() async throws {
        let source = StubGalleryDataSource(totalPages: 3, itemsPerPage: 3)
        let store = GalleryStore(dataSource: source)

        await store.loadFirstPageIfNeeded()

        #expect(store.images.count == 3)
        #expect(store.phase == .loaded)
        #expect(store.hasMore)
        #expect(store.pageSize == 24, "页大小应取自响应，而不是硬编码")
        let requestedAfterFirst = await source.requested()
        #expect(requestedAfterFirst == [1])
    }

    @Test("重复 onAppear 不会重复请求首页")
    func doesNotReloadFirstPage() async throws {
        let source = StubGalleryDataSource(totalPages: 3)
        let store = GalleryStore(dataSource: source)

        await store.loadFirstPageIfNeeded()
        await store.loadFirstPageIfNeeded()
        await store.loadFirstPageIfNeeded()

        let count = await source.requestCount()
        let pages = await source.requested()
        #expect(count == 1, "只应请求一次，实际 \(pages)")
    }

    @Test("上拉加载追加下一页，且按 hasMore 停止")
    func loadsNextPageUntilEnd() async throws {
        let source = StubGalleryDataSource(totalPages: 3, itemsPerPage: 3)
        let store = GalleryStore(dataSource: source)

        await store.loadFirstPageIfNeeded()
        await store.loadNextPage()
        #expect(store.images.count == 6)
        #expect(store.hasMore)

        await store.loadNextPage()
        #expect(store.images.count == 9)
        #expect(store.hasMore == false, "第 3 页之后应没有更多")

        // 到底之后再触发不应再请求
        await store.loadNextPage()
        let countAtEnd = await source.requestCount()
        let pagesAtEnd = await source.requested()
        #expect(countAtEnd == 3, "末页后不应再请求，实际 \(pagesAtEnd)")
    }

    @Test("触底时连续并发触发只加载一次下一页（滚动场景最容易踩）")
    func concurrentNextPageLoadsOnce() async throws {
        let source = StubGalleryDataSource(totalPages: 5, itemsPerPage: 3)
        await source.setDelay(60_000_000)
        let store = GalleryStore(dataSource: source)

        await store.loadFirstPageIfNeeded()
        // 模拟同一时刻多次触底回调。
        // 这里不用 withTaskGroup：Swift 6.3 的 region-based isolation 检查器
        // 在「taskGroup + @MainActor 闭包」这个组合上会报 "pattern that the
        // region-based isolation checker does not understand how to check"（编译器内部限制）。
        // 用 Task 句柄数组等价、且能正常编译。
        let tasks = (0..<5).map { _ in
            Task { @MainActor in await store.loadNextPage() }
        }
        for task in tasks { await task.value }

        let concurrentPages = await source.requested()
        #expect(concurrentPages == [1, 2], "并发触底只应加载第 2 页，实际 \(concurrentPages)")
        #expect(store.images.count == 6)
    }

    @Test("下拉刷新清空重来")
    func refreshResets() async throws {
        let source = StubGalleryDataSource(totalPages: 3, itemsPerPage: 3)
        let store = GalleryStore(dataSource: source)

        await store.loadFirstPageIfNeeded()
        await store.loadNextPage()
        #expect(store.images.count == 6)

        await store.refresh()
        #expect(store.images.count == 3, "刷新后应只剩第一页")
        #expect(store.hasMore)
        let refreshedPages = await source.requested()
        #expect(refreshedPages == [1, 2, 1])
    }

    @Test("失败进入 failed 状态并可重试")
    func failureThenRetry() async throws {
        let source = StubGalleryDataSource(totalPages: 3, itemsPerPage: 3)
        await source.setFailOnPage(1)
        let store = GalleryStore(dataSource: source)

        await store.loadFirstPageIfNeeded()
        guard case let .failed(message) = store.phase else {
            Issue.record("应进入 failed 状态，实际 \(store.phase)")
            return
        }
        #expect(message.isEmpty == false)
        #expect(store.images.isEmpty)

        // 恢复后重试应当成功
        await source.setFailOnPage(nil)
        await store.retry()
        #expect(store.phase == .loaded)
        #expect(store.images.count == 3)
    }

    @Test("追加时按 id 去重（防翻页与刷新竞态导致重复）")
    func appendDeduplicates() async throws {
        let source = StubGalleryDataSource(totalPages: 2, itemsPerPage: 3)
        let store = GalleryStore(dataSource: source)

        await store.loadFirstPageIfNeeded()
        let firstPageIDs = store.images.map(\.id)
        await store.loadNextPage()

        #expect(Set(store.images.map(\.id)).count == store.images.count, "不应出现重复 id")
        #expect(store.images.prefix(3).map(\.id) == firstPageIDs, "首页顺序应保持稳定")
    }

    @Test("首屏前 4 张标记为高优先级（对应 Web 的 fetchPriority=high）")
    func priorityFlagsFirstFour() async throws {
        let source = StubGalleryDataSource(totalPages: 1, itemsPerPage: 6)
        let store = GalleryStore(dataSource: source)
        await store.loadFirstPageIfNeeded()

        #expect(store.isPriority(index: 0))
        #expect(store.isPriority(index: 3))
        #expect(store.isPriority(index: 4) == false)
        #expect(GalleryStore.priorityCount == 4, "数量应与 Web 端一致")
    }

    @Test("Live Photo 类型按 type != 1 判定（与 Web 一致）")
    func livePhotoDetection() async throws {
        let image = StubGalleryDataSource.makeImage(id: "live", type: 2)
        #expect(image.isLivePhoto)
        #expect(StubGalleryDataSource.makeImage(id: "still", type: 1).isLivePhoto == false)
    }
}

/// 首屏缓存：**先加载缓存数据，再后台检查是否更新**。
///
/// 背景：`/images?page=1` 实测 1.5–3.4s，而每次启动都要重取。用户要求
/// "先加载缓存数据，然后再后台检查是否更新"。
@Suite("T8 · 首屏缓存的先显示后校验")
@MainActor
struct GalleryCacheTests {

    private func makeCache() -> FirstPageCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicImpactCacheTests-\(UUID().uuidString)")
        return FirstPageCache(directory: dir, key: "first-page")
    }

    private func page(_ ids: [String], hasMore: Bool = false) -> ImagePageDTO {
        ImagePageDTO(
            list: ids.map { StubGalleryDataSource.makeImage(id: $0) },
            page: 1,
            pageSize: 24,
            pageTotal: hasMore ? 2 : 1,
            hasMore: hasMore,
            album: nil
        )
    }

    @Test("缓存能存能取")
    func roundTrips() async {
        let cache = makeCache()
        #expect(await cache.load() == nil, "初始应没有缓存")
        await cache.save(page(["a", "b"]))
        let loaded = await cache.load()
        #expect(loaded?.list.map(\.id) == ["a", "b"])
    }

    @Test("有缓存时：网络还没回来就先显示缓存内容，且不回到加载态")
    func showsCacheBeforeRevalidation() async throws {
        let cache = makeCache()
        await cache.save(page(["cached-1", "cached-2"]))

        // 假数据源返回 p1-i0..2，但要 300ms 才回来 —— 用来观察"中间状态"
        let source = StubGalleryDataSource(totalPages: 1, itemsPerPage: 3)
        await source.setDelay(300_000_000)
        let store = GalleryStore(dataSource: source, cache: cache)

        let task = Task { await store.loadFirstPageIfNeeded() }
        try await Task.sleep(nanoseconds: 120_000_000)   // 网络仍在路上
        let duringFetch = store.images.map(\.id)
        let phaseDuringFetch = store.phase
        await task.value

        #expect(duringFetch == ["cached-1", "cached-2"], "网络未返回时就该显示缓存内容，实际 \(duringFetch)")
        #expect(phaseDuringFetch == .loaded, "显示缓存期间不该回到加载态，实际 \(phaseDuringFetch)")
        #expect(store.images.map(\.id) == ["p1-i0", "p1-i1", "p1-i2"], "校验完成后应换成新数据")
    }

    @Test("后台校验失败时：保留缓存内容，不换成错误页")
    func failedRevalidationKeepsCache() async {
        let cache = makeCache()
        await cache.save(page(["cached-1"]))

        let source = StubGalleryDataSource(totalPages: 1)
        await source.setFailOnPage(1)
        let store = GalleryStore(dataSource: source, cache: cache)

        await store.loadFirstPageIfNeeded()

        #expect(store.images.map(\.id) == ["cached-1"], "校验失败不该丢掉已显示的缓存内容")
        #expect(store.phase == .loaded, "校验失败不该切到错误页，实际 \(store.phase)")
    }

    @Test("首次成功加载后会写缓存，供下次启动立刻显示")
    func writesCacheAfterSuccess() async {
        let cache = makeCache()
        let source = StubGalleryDataSource(totalPages: 1, itemsPerPage: 3)
        let store = GalleryStore(dataSource: source, cache: cache)

        await store.loadFirstPageIfNeeded()

        let cached = await cache.load()
        #expect(cached?.list.map(\.id) == ["p1-i0", "p1-i1", "p1-i2"], "加载成功后应写入缓存")
    }

    @Test("缓存命中但后台校验失败时，仍然能翻下一页（回归）")
    func paginatesAfterFailedRevalidation() async {
        let cache = makeCache()
        // 注意 hasMore: true —— 缓存里存的是第 1 页，后面还有第 2 页
        await cache.save(page(["cached-1", "cached-2"], hasMore: true))

        // 第一页校验失败（模拟网络抖动），但后续页是可用的
        let source = StubGalleryDataSource(totalPages: 3, itemsPerPage: 3)
        await source.setFailOnPage(1)
        let store = GalleryStore(dataSource: source, cache: cache)

        await store.loadFirstPageIfNeeded()
        #expect(store.images.map(\.id) == ["cached-1", "cached-2"], "应保留缓存内容")

        // 关键：这里曾经被 `currentPage > 0` 挡住，导致后面永远加载不出来
        await store.loadNextPage()
        let requested = await source.requested()
        #expect(requested.contains(2), "缓存命中后仍应能请求第 2 页，实际请求了 \(requested)")
        #expect(store.images.count > 2, "第 2 页应追加到列表，实际 \(store.images.map(\.id))")
    }

    @Test("没有缓存时行为与以前一致：会经过 loadingFirstPage")
    func withoutCacheBehavesAsBefore() async {
        let source = StubGalleryDataSource(totalPages: 1, itemsPerPage: 3)
        let store = GalleryStore(dataSource: source)   // 不传缓存
        #expect(store.phase == .idle)
        await store.loadFirstPageIfNeeded()
        #expect(store.phase == .loaded)
        #expect(store.images.count == 3)
    }
}

extension GalleryCacheTests {
    @Test("第二次启动场景：后台校验还在飞时滑到底，第 2 页不能被丢掉（回归）")
    func nextPageSurvivesInFlightRevalidation() async throws {
        let cache = makeCache()
        await cache.save(page(["cached-1", "cached-2"], hasMore: true))

        // 后台校验慢（模拟真实网络 1.5–3.4s 量级），用户在此之前就滑到底了
        let source = StubGalleryDataSource(totalPages: 3, itemsPerPage: 3)
        await source.setDelay(300_000_000)
        let store = GalleryStore(dataSource: source, cache: cache)

        let firstLoad = Task { await store.loadFirstPageIfNeeded() }
        try await Task.sleep(nanoseconds: 80_000_000)   // 校验仍在飞
        await store.loadNextPage()                       // 会被 !isLoading 挡住 → 必须记下来
        await firstLoad.value

        let requested = await source.requested()
        #expect(
            requested.contains(2),
            "滑到底那一次不能在「加载中」时被丢掉，实际请求了 \(requested)"
        )
    }
}

@Suite("T9 · 主动查询网站更新")
@MainActor
struct GalleryPollingTests {
    @Test("第一张没变时不刷新 —— 不打扰已翻页/滚动的位置")
    func keepsStateWhenUnchanged() async {
        let source = StubGalleryDataSource(totalPages: 2, itemsPerPage: 3)
        let store = GalleryStore(dataSource: source)
        await store.loadFirstPageIfNeeded()
        let before = store.images.map(\.id)
        let countBefore = await source.requestCount()

        await store.pollForUpdates()

        #expect(store.images.map(\.id) == before, "内容没变就不该改动列表")
        let requested = await source.requested()
        #expect(requested.last == 1, "只该请求第一页做比较，实际 \(requested)")
        let countAfter = await source.requestCount()
        #expect(countAfter == countBefore + 1, "查询应恰好发一次请求")
    }

    @Test("发现第一张变化时刷新列表")
    func refreshesWhenFirstChanges() async {
        let source = StubGalleryDataSource(totalPages: 2, itemsPerPage: 3)
        let store = GalleryStore(dataSource: source)
        await store.loadFirstPageIfNeeded()
        #expect(store.images.first?.id == "p1-i0")

        // 模拟网站更新：第一页内容变了
        await source.replacePage(1, with: ["new-0", "p1-i1", "p1-i2"])
        await store.pollForUpdates()

        #expect(
            store.images.first?.id == "new-0",
            "应刷新成新内容，实际 \(store.images.first?.id ?? "nil")"
        )
    }

    @Test("查询失败时静默，不影响已有内容")
    func silentOnFailure() async {
        let source = StubGalleryDataSource(totalPages: 1, itemsPerPage: 3)
        let store = GalleryStore(dataSource: source)
        await store.loadFirstPageIfNeeded()
        let before = store.images.map(\.id)

        await source.setFailOnPage(1)
        await store.pollForUpdates()

        #expect(store.images.map(\.id) == before, "查询失败不该清空或改动内容")
        #expect(store.phase == .loaded, "查询失败不该切成错误页，实际 \(store.phase)")
    }
}

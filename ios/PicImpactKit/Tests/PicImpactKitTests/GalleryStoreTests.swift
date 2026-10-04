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

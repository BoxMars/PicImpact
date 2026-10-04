import Foundation
import Observation

/// 画廊列表的分页状态机。
///
/// 把分页逻辑独立于视图，是因为它是这类界面最容易出错的地方：
/// 重复加载、并发触发、末页判断、错误后无法重试。这些都能脱离 UI 测试。
@Observable
@MainActor
public final class GalleryStore {

    public enum Phase: Equatable, Sendable {
        case idle
        /// 首次加载（列表还是空的，需要占位指示器）
        case loadingFirstPage
        /// 下拉刷新。
        ///
        /// **必须与 `loadingFirstPage` 分开**：下拉刷新时系统已经显示了自己的指示器
        /// （`.refreshable`），若这里也当成首次加载，界面会出现两个刷新图标。
        case refreshing
        case loadingNextPage
        case loaded
        case failed(String)
    }

    public private(set) var images: [ImageDTO] = []
    public private(set) var phase: Phase = .idle
    /// 还有没有下一页。**以服务端返回的 hasMore 为准**，不要自己拿 page 和 pageTotal 算
    public private(set) var hasMore = true
    /// 页大小从 /config 读取，不硬编码
    public private(set) var pageSize: Int = 24

    public let album: String?
    public let tag: String?

    private let dataSource: GalleryDataSource
    /// 首屏磁盘缓存，用来"先出缓存、再后台校验"。为 nil 时行为与以前完全一致。
    private let cache: FirstPageCache?
    private var currentPage = 0
    /// 防止同一时刻发起多次加载（滚动时最容易触发）
    private var isLoading = false

    public init(
        dataSource: GalleryDataSource,
        album: String? = nil,
        tag: String? = nil,
        cache: FirstPageCache? = nil
    ) {
        self.dataSource = dataSource
        self.album = album
        self.tag = tag
        self.cache = cache
    }

    /// 首屏前几张要最高下载优先级（对应 Web 的 fetchPriority=high）。
    /// 数量与 Web 端一致：前 4 张。
    public static let priorityCount = 4

    public func isPriority(index: Int) -> Bool {
        index < Self.priorityCount
    }

    public var isEmpty: Bool {
        images.isEmpty && phase == .loaded
    }

    /// 首次进入时加载首页；已加载过则不做任何事（避免每次 onAppear 都重拉）。
    ///
    /// 顺序是"**先加载缓存数据，再后台检查是否更新**"：
    /// 1. 有缓存就立刻铺上（`phase` 直接是 `.loaded`，不显示占位指示器）
    /// 2. 无论有没有缓存，都再请求一次第一页校验更新；有内容时这次是**静默**的
    ///    （不切回加载态、失败也不覆盖现有内容）
    public func loadFirstPageIfNeeded() async {
        guard currentPage == 0, !isLoading else { return }

        if images.isEmpty, let cache, let cached = await cache.load(), !cached.list.isEmpty {
            images = cached.list
            pageSize = cached.pageSize
            hasMore = cached.hasMore
            phase = .loaded
        }

        await load(page: 1, replacing: true)
    }

    /// 触底加载下一页
    public func loadNextPage() async {
        guard hasMore, !isLoading, currentPage > 0 else { return }
        await load(page: currentPage + 1, replacing: false)
    }

    /// 下拉刷新：重新拉第一页。
    ///
    /// **不清空现有列表**：清空会让整屏内容先消失再出现（跳变），
    /// 而新数据到达后整体替换即可，视觉上更稳。
    public func refresh() async {
        guard !isLoading else { return }
        hasMore = true
        await load(page: 1, replacing: true, isRefresh: true)
    }

    /// 失败后重试（失败时不在 phase 里保留 page 进度，重试当前目标页）
    public func retry() async {
        guard !isLoading else { return }
        if currentPage == 0 {
            await load(page: 1, replacing: true)
        } else {
            await load(page: currentPage + 1, replacing: false)
        }
    }

    private func load(page: Int, replacing: Bool, isRefresh: Bool = false) async {
        isLoading = true
        // 调用前是否已经有内容（缓存铺上的、或之前加载的）
        let hadContent = !images.isEmpty
        // 有内容时的"第一页校验"是**静默**的：不切回加载态，用户看到的仍是现有内容
        let silentRevalidation = hadContent && page == 1 && replacing && !isRefresh

        if isRefresh {
            phase = .refreshing
        } else if silentRevalidation {
            // 保持 .loaded
        } else {
            phase = (page == 1 && replacing) ? .loadingFirstPage : .loadingNextPage
        }

        do {
            let result = try await dataSource.images(
                album: album,
                tag: tag,
                camera: nil,
                lens: nil,
                page: page
            )
            pageSize = result.pageSize
            hasMore = result.hasMore

            if replacing {
                images = result.list
            } else {
                // 去重：服务端理论上不会重复，但翻页与刷新竞态时宁可多一层保险
                let existing = Set(images.map(\.id))
                images.append(contentsOf: result.list.filter { !existing.contains($0.id) })
            }
            currentPage = page
            phase = .loaded
            // 第一页成功了就更新缓存（供下次启动立刻显示）
            if page == 1, replacing, let cache {
                await cache.save(result)
            }
        } catch {
            // 静默校验失败：保留现有内容，不要把用户已看到的画面换成错误页
            phase = silentRevalidation ? .loaded : .failed(Self.describe(error))
        }

        isLoading = false
    }

    private static func describe(_ error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.errorDescription ?? "加载失败"
        }
        return error.localizedDescription
    }
}

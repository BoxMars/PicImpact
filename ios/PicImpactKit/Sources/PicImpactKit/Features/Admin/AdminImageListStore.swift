import Foundation
import Observation

/// 相册列表的来源。抽成协议是为了让管理页的列表状态机可以脱离网络测试。
public protocol AlbumListProviding: Sendable {
    func albums() async throws -> [AlbumDTO]
}

extension APIClient: AlbumListProviding {
    // `albums()` 已经存在（公开接口 `/albums`），这里只是给它一个可注入的协议身份
}

/// 管理页的图片列表状态。
///
/// 与 `GalleryStore` 分开：画廊是公开只读、走公开 API 且有自己的缓存；管理列表要走**带会话**的
/// 管理接口，还要能删除。混成一个 store 会让"会话失效"这种状态污染画廊。
@Observable
@MainActor
public final class AdminImageListStore {

    public private(set) var images: [AdminImageSummary] = []
    public private(set) var albums: [AlbumDTO] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var errorMessage: String?
    public private(set) var hasMore = false
    public private(set) var total = 0
    /// 正在删除的图片 id（界面上把那一行的按钮置灰，避免重复点）
    public private(set) var deletingIDs: Set<String> = []

    /// 上传目标 / 列表过滤用的相册值（形如 `/daily`）
    public var albumValue: String = ""

    private let api: any AdminImageAPI
    private let albumSource: any AlbumListProviding
    private let cookie: @MainActor () -> String?
    private let pageSize: Int
    private var page = 1

    public init(
        api: any AdminImageAPI,
        albumSource: any AlbumListProviding,
        cookie: @escaping @MainActor () -> String?,
        pageSize: Int = AdminImageClient.defaultPageSize
    ) {
        self.api = api
        self.albumSource = albumSource
        self.cookie = cookie
        self.pageSize = pageSize
    }

    /// 相册（上传必须先选一个；服务端也会校验它是否存在）
    public func loadAlbums() async {
        do {
            let list = try await albumSource.albums()
            albums = list
            if albumValue.isEmpty, let first = list.first { albumValue = first.value }
        } catch {
            // 相册拉不到不该让整页打不开：错误提示已经有了，列表仍可看
            errorMessage = UploadCoordinator.failureMessage(error)
        }
    }

    public func loadFirstPage() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await fetch(page: 1, replacing: true)
    }

    public func loadNextPage() async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetch(page: page + 1, replacing: false)
    }

    /// 上传成功后刷新（新图在最前面，所以直接重载第一页）
    public func refreshAfterUpload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await fetch(page: 1, replacing: true)
    }

    public func select(album value: String) async {
        guard value != albumValue else { return }
        albumValue = value
        isLoading = true
        defer { isLoading = false }
        await fetch(page: 1, replacing: true)
    }

    private func fetch(page requestedPage: Int, replacing: Bool) async {
        guard let cookieHeader = cookie(), !cookieHeader.isEmpty else {
            errorMessage = "登录状态已失效，请重新登录"
            return
        }
        do {
            let result = try await api.listImages(
                page: requestedPage,
                pageSize: pageSize,
                album: albumValue.isEmpty ? nil : albumValue,
                cookie: cookieHeader
            )
            page = result.page
            total = result.total
            hasMore = result.hasMore
            images = replacing ? result.items : images + result.items
            errorMessage = nil
        } catch {
            errorMessage = UploadCoordinator.failureMessage(error)
        }
    }

    /// 删除（软删除）。成功后**立刻**从本地列表移除，不必等重新拉取。
    public func delete(id: String) async {
        guard !deletingIDs.contains(id) else { return }
        guard let cookieHeader = cookie(), !cookieHeader.isEmpty else {
            errorMessage = "登录状态已失效，请重新登录"
            return
        }
        deletingIDs.insert(id)
        defer { deletingIDs.remove(id) }
        do {
            try await api.deleteImage(id: id, cookie: cookieHeader)
            images.removeAll { $0.id == id }
            total = max(0, total - 1)
            errorMessage = nil
        } catch {
            errorMessage = UploadCoordinator.failureMessage(error)
        }
    }

    /// 编辑：保存标题 / 详情 / 标签。
    ///
    /// 成功后**就地更新本地那一条**（不整页重拉）：重拉会让列表跳一下，
    /// 而且用户在编辑时通常正盯着这一行。返回值给调用方决定要不要收起编辑页。
    @discardableResult
    public func saveMetadata(id: String, title: String, detail: String, labels: [String]) async -> Bool {
        guard let item = images.first(where: { $0.id == id }) else { return false }
        guard let cookieHeader = cookie(), !cookieHeader.isEmpty else {
            errorMessage = "登录状态已失效，请重新登录"
            return false
        }
        // url / width / height 是服务端的硬校验，必须回传（其余字段见 AdminImageUpdate 的说明）
        let update = AdminImageUpdate(
            id: id, url: item.url, width: item.width, height: item.height,
            title: title, detail: detail, labels: labels
        )
        do {
            try await api.updateImage(update, cookie: cookieHeader)
            replace(id: id) { $0.with(title: title, detail: detail, labels: labels) }
            errorMessage = nil
            return true
        } catch {
            errorMessage = UploadCoordinator.failureMessage(error)
            return false
        }
    }

    /// 编辑：显示 / 隐藏（0＝显示，1＝隐藏）
    @discardableResult
    public func setVisibility(id: String, show: Int) async -> Bool {
        guard let cookieHeader = cookie(), !cookieHeader.isEmpty else {
            errorMessage = "登录状态已失效，请重新登录"
            return false
        }
        do {
            try await api.updateImageShow(id: id, show: show, cookie: cookieHeader)
            replace(id: id) { $0.with(show: show) }
            errorMessage = nil
            return true
        } catch {
            errorMessage = UploadCoordinator.failureMessage(error)
            return false
        }
    }

    /// 编辑：换相册。服务端收的是相册 **id**（`PUT /images/update-Album` 里按 id 查相册）
    @discardableResult
    public func moveToAlbum(id: String, albumId: String, albumValue newValue: String, albumName: String) async -> Bool {
        guard let cookieHeader = cookie(), !cookieHeader.isEmpty else {
            errorMessage = "登录状态已失效，请重新登录"
            return false
        }
        do {
            try await api.updateImageAlbum(imageId: id, albumId: albumId, cookie: cookieHeader)
            replace(id: id) { $0.with(albumValue: newValue, albumName: albumName) }
            errorMessage = nil
            return true
        } catch {
            errorMessage = UploadCoordinator.failureMessage(error)
            return false
        }
    }

    private func replace(id: String, _ transform: (AdminImageSummary) -> AdminImageSummary) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index] = transform(images[index])
    }

    public func clearError() {
        errorMessage = nil
    }
}

/// 就地改一条列表项。`AdminImageSummary` 的字段全是 `let`，逐字段复制容易漏，
/// 所以集中在这里做（每个 `with` 只改自己那几个字段）。
extension AdminImageSummary {
    func with(title: String? = nil, detail: String? = nil, labels: [String]? = nil, show: Int? = nil, albumValue: String? = nil, albumName: String? = nil) -> AdminImageSummary {
        AdminImageSummary(
            id: id,
            url: url,
            previewUrl: previewUrl,
            title: title ?? self.title,
            detail: detail ?? self.detail,
            width: width,
            height: height,
            show: show ?? self.show,
            showOnMainpage: showOnMainpage,
            labels: labels ?? self.labels,
            createdAt: createdAt,
            albumValue: albumValue ?? self.albumValue,
            albumName: albumName ?? self.albumName,
            exif: exif
        )
    }
}

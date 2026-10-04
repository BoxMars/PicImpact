import Foundation

/// 画廊数据源。抽成协议是为了让分页逻辑可以脱离网络测试 ——
/// 否则"上拉加载更多"这类最容易出错的地方只能靠手点。
public protocol GalleryDataSource: Sendable {
    func images(
        album: String?,
        tag: String?,
        camera: String?,
        lens: String?,
        page: Int
    ) async throws -> ImagePageDTO
}

/// 站点信息数据源
public protocol SiteConfigDataSource: Sendable {
    func siteConfig() async throws -> SiteConfigDTO
    func albums() async throws -> [AlbumDTO]
    func tags() async throws -> [String]
    func filters(album: String?) async throws -> FiltersDTO
}

extension APIClient: GalleryDataSource {}
extension APIClient: SiteConfigDataSource {}

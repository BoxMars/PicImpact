import Foundation
import Observation
import PicImpactKit

/// 应用级依赖与站点配置。
///
/// 启动时**必须先取 `/config`**：它同时提供能力开关（`features`）与页大小。
/// API 契约里客户端被要求"依据 features 决定显示哪些功能，而不是猜版本号"。
@Observable
@MainActor
final class AppEnvironment {

    let client: APIClient
    let loader: ImageLoader
    let downloader: DownloadService
    let gallery: GalleryStore

    private(set) var config: SiteConfigDTO?
    private(set) var configError: String?

    init() {
        let client = APIClient()
        // 图片缓存显式建出来并交给 loader：打包种子的预览图要灌进**同一个**缓存，
        // 否则灌进去的和读的不是一份（ImageLoader 默认会自建一个）。
        let imageCache = ImageCache()
        let loader = ImageLoader(cache: imageCache)
        self.client = client
        self.loader = loader
        self.downloader = DefaultDownloadService(loader: loader)
        // 首屏缓存：实现"先加载缓存数据，再后台检查是否更新"
        self.gallery = GalleryStore(
            dataSource: client,
            album: nil,
            cache: FirstPageCache(key: "first-page"),
            imageCache: imageCache
        )
    }

    /// 能力开关。未加载到配置时一律为 false —— 宁可少显示，也不要显示了却点不动。
    var features: SiteConfigDTO.Features {
        config?.features ?? .none
    }

    var siteTitle: String {
        config?.site.title ?? GalleryHeader.defaultTitle
    }

    func bootstrap() async {
        do {
            config = try await client.siteConfig()
            configError = nil
        } catch {
            configError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

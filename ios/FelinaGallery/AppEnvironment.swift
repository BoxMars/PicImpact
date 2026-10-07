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
    /// 登录态。挂在环境上而不是视图里：标题三击、登录 sheet、管理页三处都要读它，
    /// 放在一处才能保证"凭证"与"界面状态"永远同步。
    let auth: AuthStore
    /// 管理端接口（上传签发 / 登记 / 列表 / 删除）
    let adminImages: AdminImageClient
    /// 管理页的图片列表
    let adminList: AdminImageListStore
    /// 上传队列（选图 → 直传 R2 → 登记）
    let uploads: UploadCoordinator

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
        // 会话 Cookie 存 Keychain（不能用 UserDefaults：明文、会随备份带走）
        let auth = AuthStore(api: AuthClient(), keychain: KeychainStore())
        self.auth = auth

        #if DEBUG
        // 只在 DEBUG 构建里存在的测试钩子：把会话或故障注入进去（见文件末尾的说明）
        AppEnvironment.applyTestHooks(auth: auth)
        let adminImages = AdminImageClient()
        let adminAPI: any AdminImageAPI = TestHooks.failRegisterStep
            ? FailingRegisterAdminAPI(base: adminImages)
            : adminImages
        #else
        let adminImages = AdminImageClient()
        let adminAPI: any AdminImageAPI = adminImages
        #endif

        self.adminImages = adminImages
        // 会话 Cookie 由 auth 一处持有：管理接口每次请求都现取，登出/过期后立刻失效
        self.adminList = AdminImageListStore(
            api: adminAPI,
            albumSource: client,
            cookie: { [weak auth] in auth?.sessionCookieHeader }
        )
        self.uploads = UploadCoordinator(
            api: adminAPI,
            cookie: { [weak auth] in auth?.sessionCookieHeader }
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

    #if DEBUG
    /// 测试钩子（**只在 DEBUG 编译**，发布包里这段代码不存在）。
    ///
    /// 为什么需要：端到端验收要在模拟器上真的走一遍"上传到生产"，而实施者没有、
    /// 也不该去找管理员密码。于是允许从**启动参数**注入一个真实会话来跑测试，
    /// 而不是把密码写进任何地方：
    /// ```
    /// xcrun simctl launch <udid> dev.boxz.felina \
    ///   -FelinaTestSessionCookie "__Secure-pic-impact.session_token=xxx; Path=/; Domain=felina.boxz.dev"
    /// ```
    /// 注入的内容就是 App 登录成功后本来会写进 Keychain 的那份（同一个
    /// `SessionCookies` + `KeychainStore`），所以后续走的是**完全真实**的会话路径。
    /// 用完会在服务端吊销这个会话（脚本 `scripts/api/mint-test-session.ts --revoke`）。
    private static func applyTestHooks(auth: AuthStore) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-FelinaTestSessionCookie"),
              flagIndex + 1 < arguments.count
        else { return }

        let raw = arguments[flagIndex + 1]
        guard let cookie = AuthCookie(setCookieHeader: raw, defaultDomain: "felina.boxz.dev"),
              let encoded = try? SessionCookies(cookies: [cookie]).encoded()
        else {
            NSLog("[FelinaTest] 注入的会话 cookie 解析失败，忽略")
            return
        }
        _ = KeychainStore().set(encoded, for: AuthStore.defaultStorageKey)
        NSLog("[FelinaTest] 已注入测试会话（cookie 名 \(cookie.name)）")
    }
    #endif
}

#if DEBUG
/// DEBUG 专用的启动参数开关注解（集中放一处，避免散落在各处读 `ProcessInfo`）
private enum TestHooks {
    /// `-FelinaTestFailRegister 1`：让登记步骤必定失败，用来复现"原图已上传但未登记"的孤儿对象场景
    static var failRegisterStep: Bool {
        ProcessInfo.processInfo.arguments.contains("-FelinaTestFailRegister")
    }
}

/// 把"登记"这一步打断的装饰器。其余步骤（签发、直传 R2）**照常真实执行** ——
/// 这正是孤儿对象产生的真实路径：对象已经在桶里，只是没进库。
private struct FailingRegisterAdminAPI: AdminImageAPI {
    let base: AdminImageAPI

    func signUpload(filename: String, contentType: String, albumValue: String, size: Int, cookie: String) async throws -> SignedUpload {
        try await base.signUpload(filename: filename, contentType: contentType, albumValue: albumValue, size: size, cookie: cookie)
    }

    func registerImage(_ input: AdminRegisterInput, cookie: String) async throws -> RegisteredImage {
        throw APIError.transport("（测试注入）登记步骤被强制失败")
    }

    func listImages(page: Int, pageSize: Int, album: String?, cookie: String) async throws -> AdminImagePage {
        try await base.listImages(page: page, pageSize: pageSize, album: album, cookie: cookie)
    }

    func deleteImage(id: String, cookie: String) async throws {
        try await base.deleteImage(id: id, cookie: cookie)
    }
}
#endif

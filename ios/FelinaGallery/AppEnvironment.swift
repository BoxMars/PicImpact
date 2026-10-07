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
    /// 判重账本
    let ledger: UploadLedger?
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
        let adminAPI: any AdminImageAPI = (TestHooks.failRegisterStep || TestHooks.failListWith401)
            ? FailingRegisterAdminAPI(base: adminImages, listReturns401: TestHooks.failListWith401)
            : adminImages
        #else
        let adminImages = AdminImageClient()
        let adminAPI: any AdminImageAPI = adminImages
        #endif

        self.adminImages = adminImages
        self.ledger = UploadLedger()
        // 会话 Cookie 由 auth 一处持有：管理接口每次请求都现取，登出/过期后立刻失效
        self.adminList = AdminImageListStore(
            api: adminAPI,
            albumSource: client,
            cookie: { [weak auth] in auth?.sessionCookieHeader }
        )
        self.uploads = UploadCoordinator(
            api: adminAPI,
            cookie: { [weak auth] in auth?.sessionCookieHeader },
            // 判重依据之一：这台设备传过哪些照片（离线也能判，重装前一直有效）
            ledger: self.ledger,
            // 判重依据之二：服务端列表里已有的那些（元数据足够 —— 拍摄时间/尺寸/机型）
            serverFingerprints: { [weak adminList] in
                (adminList?.images ?? []).map { image in
                    let title = image.title.isEmpty
                        ? (URL(string: image.url)?.lastPathComponent ?? "")
                        : image.title
                    return (
                        UploadFingerprint(
                            // 服务端只有元数据，没有原图字节 —— digest 留空即"不比字节"
                            digest: "",
                            capturedAt: EXIFDateParser.date(from: image.exif.dataTime),
                            width: image.width,
                            height: image.height,
                            model: image.exif.model
                        ),
                        image.id,
                        title
                    )
                }
            }
        )
    }

    #if DEBUG
    /// 临时：真机诊断（`-FelinaDiagnose 1`）。把"会话有没有落盘、请求带了什么、服务端返回几"打成日志，
    /// 用 `xcrun devicectl device process launch --console` 直接看。**不打印任何凭证原文。**
    func runDiagnoseIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-FelinaDiagnose") else { return }
        Task { await Self.diagnose(auth: auth, siteOrigin: APIClient.siteOrigin()) }
    }

    static func diagnose(auth: AuthStore, siteOrigin: URL) async {
        APILog.credentials("=== diagnose start ===")

        // 1) 会话：Keychain 里到底有没有、能不能读出来
        let stored = await KeychainStore().data(for: AuthStore.defaultStorageKey)
        APILog.credentials("diagnose keychain.hasSession=\(stored != nil) bytes=\(stored?.count ?? 0)")
        if let stored, let cookies = try? SessionCookies.decoded(from: stored) {
            let names = cookies.cookies.map(\.name).joined(separator: ",")
            let expired = cookies.cookies.map { $0.isExpired(at: Date()) ? "1" : "0" }.joined()
            APILog.credentials("diagnose session.cookies=\(cookies.cookies.count) names=\(names) expiredFlags=\(expired)")
        }
        let header = auth.sessionCookieHeader
        APILog.credentials("diagnose session.headerPresent=\(header != nil)")

        // 2) Keychain 写：真机上"卡住"是否发生在这里（量耗时）
        let probeKey = "diagnose-probe"
        let probe = Data("probe".utf8)
        let writeStart = Date()
        let wrote = await KeychainStore().set(probe, for: probeKey)
        let writeMS = Date().timeIntervalSince(writeStart) * 1000
        let readBack = await KeychainStore().data(for: probeKey)
        APILog.credentials(
            "diagnose keychain.write ok=\(wrote) readback=\(readBack == probe) ms=\(String(format: "%.1f", writeMS))"
        )
        _ = await KeychainStore().remove(probeKey)

        // 3) 接口：不带会话 / 带会话 各是什么状态码
        let base = siteOrigin.absoluteString
        let publicList = await Self.probe("GET", "\(base)/api/public/v1/images?page=1", cookie: nil)
        let adminAnon = await Self.probe("GET", "\(base)/api/v1/admin/images?page=1&pageSize=1", cookie: nil)
        let adminAuth = await Self.probe("GET", "\(base)/api/v1/admin/images?page=1&pageSize=1", cookie: header)
        APILog.credentials("diagnose public.list(no cookie)=\(publicList) admin.list(no cookie)=\(adminAnon) admin.list(with cookie)=\(adminAuth)")
        APILog.credentials("=== diagnose end ===")
    }

    static func probe(_ method: String, _ urlString: String, cookie: String?) async -> Int {
        guard let url = URL(string: urlString) else { return -1 }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            APILog.transportError(method, urlString, error.localizedDescription)
            return -1
        }
    }
    #endif

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
        Task { _ = await KeychainStore().set(encoded, for: AuthStore.defaultStorageKey) }
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

    /// `-FelinaTestFailList401`：让管理列表返回 401，用来验证"会话失效必须可见"
    static var failListWith401: Bool {
        ProcessInfo.processInfo.arguments.contains("-FelinaTestFailList401")
    }
}

/// 把"登记"这一步打断的装饰器。其余步骤（签发、直传 R2）**照常真实执行** ——
/// 这正是孤儿对象产生的真实路径：对象已经在桶里，只是没进库。
private struct FailingRegisterAdminAPI: AdminImageAPI {
    let base: AdminImageAPI
    /// 让列表请求返回 401（验证"失败可见"）
    var listReturns401 = false

    func signUpload(filename: String, contentType: String, albumValue: String, size: Int, cookie: String) async throws -> SignedUpload {
        try await base.signUpload(filename: filename, contentType: contentType, albumValue: albumValue, size: size, cookie: cookie)
    }

    func registerImage(_ input: AdminRegisterInput, cookie: String) async throws -> RegisteredImage {
        throw APIError.transport("（测试注入）登记步骤被强制失败")
    }

    func listImages(page: Int, pageSize: Int, album: String?, cookie: String) async throws -> AdminImagePage {
        if listReturns401 {
            throw APIError.http(status: 401, code: nil, message: "authentication failed")
        }
        return try await base.listImages(page: page, pageSize: pageSize, album: album, cookie: cookie)
    }

    func deleteImage(id: String, cookie: String) async throws {
        try await base.deleteImage(id: id, cookie: cookie)
    }

    // 编辑不参与"孤儿对象"那个场景，原样透传
    func updateImage(_ update: AdminImageUpdate, cookie: String) async throws {
        try await base.updateImage(update, cookie: cookie)
    }

    func updateImageShow(id: String, show: Int, cookie: String) async throws {
        try await base.updateImageShow(id: id, show: show, cookie: cookie)
    }

    func updateImageAlbum(imageId: String, albumId: String, cookie: String) async throws {
        try await base.updateImageAlbum(imageId: imageId, albumId: albumId, cookie: cookie)
    }
}
#endif

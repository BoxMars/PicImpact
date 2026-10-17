import Foundation
import Observation
import PicImpactKit
import UIKit

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
    /// 推送设备注册（clientId / 心跳节流 / 登出停用）。纯逻辑，可在 `swift test` 里覆盖。
    let push: PushRegistrar
    /// 点通知要打开的那张图。冷启动时回调早于界面出现，所以必须有个地方先存住（规格 §5.4）。
    let pushRoutes: PushRouteInbox

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
        let sortPreference = GallerySortPreference()
        self.gallery = GalleryStore(
            dataSource: client,
            album: nil,
            sort: sortPreference.load(),
            cache: FirstPageCache(key: "first-page"),
            imageCache: imageCache,
            // 排序偏好落盘。UserDefaults 而不是 Keychain：它不是秘密，且要能被单测用独立 suite 隔离。
            persistSort: { sortPreference.save($0) }
        )
        // 会话 Cookie 存 Keychain（不能用 UserDefaults：明文、会随备份带走）
        let auth = AuthStore(api: AuthClient(), keychain: KeychainStore())
        self.auth = auth

        // 推送设备注册。clientId 与心跳记录都落 Keychain（与会话同一个 service，account 各不相同）：
        // 它们不该出现在明文 plist / 备份里，规则与"会话 Cookie 放 Keychain"一致。
        //
        // ⚠️ 注册**不需要会话**：推送发给所有装了 App 的人（家人/朋友），登录只用于上传/管理。
        // 所以这里不再注入 Cookie —— 早先那版把设备绑在管理员账号上，是设计错误。
        let push = PushRegistrar(
            api: PushClient(),
            keychain: KeychainStore()
        )
        self.push = push
        self.pushRoutes = PushRouteInbox()

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
        let adminList = AdminImageListStore(
            api: adminAPI,
            albumSource: client,
            cookie: { [weak auth] in auth?.sessionCookieHeader }
        )
        self.adminList = adminList
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
            },
            // 登记请求带上 X-Felina-Client-Id：服务端据此跳过"发起这次上传的那台设备"（规格 §4.5）
            clientId: { [weak push] in push?.clientId }
        )

        // 登出 → 停用这台设备的推送。钩子挂在 AuthStore 的 signOut 里，且在服务端吊销会话**之前**
        // 执行（DELETE 要带一个仍然有效的 Cookie，见 AuthStore.onSignOut 的说明）。
        auth.onSignOut = { [weak push] in await push?.unregister() }

        // AppDelegate 与业务之间**唯一**的接线点（见 PushCoordinator 的说明）。
        // 前台推送 = 立刻刷新的信号：画廊马上查一次更新；
        // 管理列表是带会话的接口，没登录时不调它 —— 否则只会往管理页写一句"登录状态已失效"。
        PushCoordinator.shared.bind(
            registrar: push,
            inbox: self.pushRoutes,
            onForegroundPush: { [weak gallery, weak auth] in
                await gallery?.pollForUpdates()
                if auth?.isSignedIn == true {
                    await adminList.refreshAfterUpload()
                }
            }
        )
    }

    /// 推送心跳 / 首次授权：**启动时**与每次回前台各调一次，**不需要登录**。
    ///
    /// 装了 App 的人都该收到「有新照片」的通知（登录只是上传/管理才需要），
    /// 所以第一次进来就会申请系统权限；之后每次启动只是静默续一次 token。
    func startPush() async {
        await PushCoordinator.shared.start()
    }

    /// 打开系统设置里的本 App 页面。系统不会再弹第二次授权框，这是用户唯一的出路（规格 §2.8）。
    func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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

        // 4) 用**真实的管理客户端 + 内存会话**打一次列表：这是管理页看到的那条路径。
        //    "401" 与 "200 但 0 行" 是两个完全不同的方向，必须在这里分清。
        let client = AdminImageClient()
        let sessionHeader = header ?? ""
        do {
            let page = try await client.listImages(page: 1, pageSize: 24, album: nil, cookie: sessionHeader)
            let titles = page.items.prefix(3).map { $0.title.isEmpty ? "(无标题)" : $0.title }
            APILog.credentials("diagnose admin.client.list OK total=\(page.total) items=\(page.items.count) hasMore=\(page.hasMore) first=\(titles.joined(separator: " / "))")
        } catch {
            APILog.credentials("diagnose admin.client.list FAILED error=\(String(describing: error))")
        }
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
        // clientId 要在**任何上传之前**就绪：它要进登记的请求头（用户可能一起来就进管理页传图）。
        // 这里不等它失败/成功 —— 首次生成后它就是 Keychain 里的一条稳定记录。
        await push.prepareClientId()
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

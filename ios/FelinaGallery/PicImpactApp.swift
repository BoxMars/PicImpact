import PicImpactKit
import SwiftUI

/// 应用入口。
///
/// 用 SwiftUI 生命周期；启动时按 `/config` 的能力开关装配界面 ——
/// 关闭的功能不显示入口，而不是显示了再报错。
///
/// ⚠️ **唯一一处破例**：推送需要一个最小的 `AppDelegate`（见 `AppDelegate.swift` 顶部的说明）——
/// SwiftUI 没有"注册远程通知并拿到 device token"的等价 API，这不是风格选择。
/// 它只做回调转发，业务逻辑仍在 Kit 里（可单测）。
@main
struct PicImpactApp: App {
    /// 推送与通知回调的入口（必须由 SwiftUI 创建，所以只能挂在这里）
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .task { await environment.bootstrap() }
                .onAppear {
                    #if DEBUG
                    environment.runDiagnoseIfRequested()
                    #endif
                }
                // 恢复登录态与拉配置互不依赖，所以分成两个 task 并行，不用互相等
                .task {
                    await environment.auth.restoreSession()
                    // 推送**不依赖登录**（设备与账号无关，装了 App 就该收到新照片通知），
                    // 所以这里的先后只影响"权限框什么时候出现"：等会话恢复完再问，
                    // 用户第一眼看到的是相册而不是一个突兀的系统弹框。
                    await environment.startPush()
                }
        }
    }
}

/// 根视图：**只有画廊**。
///
/// 之前是「画廊 / 地图」两个 Tab，现已去掉 TabView —— 产品只需要一个画廊。
/// `MapGalleryView` 仍保留在 kit 里（有测试覆盖），将来若要加回不必重写。
struct RootView: View {
    let environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @State private var previewTarget: ImageDTO?
    /// 管理界面（登录 → 占位管理页）是否展示。
    ///
    /// 放在视图里而不是 AuthStore 里：它是"这个 sheet 开着没有"的界面状态，
    /// 与"凭证是否有效"是两件事 —— 会话失效不该自动把 sheet 关掉（用户正在输密码时会被打断）。
    @State private var showAdmin = false
    /// 通知权限被关掉（管理页据此显示"去系统设置"）。
    ///
    /// 为什么不直接把 `environment.push.isDenied` 传进 sheet：sheet 的内容闭包**不在** body
    /// 求值期执行，`@Observable` 追踪不到那次读取 —— 用户在管理页里点了"不允许"之后，
    /// 横幅不会自己出现。用 `@State` + `onChange` 才是可靠的。
    @State private var pushDenied = false
    /// 推送跳转失败时的一句提示（图已被删除/隐藏）。**只提示、不跳** ——
    /// 把用户扔进一个空白预览页比不跳更糟（规格 §5.4）。
    @State private var pushNotice: String?

    var body: some View {
        NavigationStack {
            HomeView(
                store: environment.gallery,
                loader: environment.loader,
                showDownload: environment.features.download,
                downloader: environment.downloader,
                // 标题与副标题现在显示在页面内的缎带上（与 Web 一致），导航栏不再重复
                headerTitle: environment.siteTitle,
                // 后台入口：连续点击标题三次。没有可见按钮是有意为之。
                onTitleTripleTap: { showAdmin = true },
                onSelect: { previewTarget = $0 }
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $previewTarget) { image in
                PreviewView(
                    model: PreviewModel(
                        image: image,
                        loader: environment.loader,
                        downloader: environment.downloader
                    ),
                    features: environment.features
                )
                // 左缘右滑退出。
                //
                // 为什么不用系统的 interactivePopGestureRecognizer：为它写过两版
                // UIKit 桥接（viewDidAppear 里接管 delegate、shouldBegin 不再 cast
                // gesture.view），用户反馈**仍然滑不动**，两次都是靠推理、没有验证。
                // 这里改成纯 SwiftUI 的拖拽，行为确定、不依赖系统手势的内部状态；
                // 系统手势若本来就通，两者同时存在也不冲突（都只是 dismiss 一次）。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            // 必须从**左缘**起手，且明显是水平向右，避免抢走页面内的滑动
                            guard value.startLocation.x <= 32,
                                  dx > 80,
                                  dx > abs(dy) * 1.5
                            else { return }
                            previewTarget = nil
                        }
                )
            }
        }
        .tint(AnimalTokens.primary)
        .overlay(alignment: .top) { pushNoticeView }
        // 运行中到达的跳转（点通知时 App 在前台/后台）
        .onChange(of: environment.pushRoutes.pending) { _, route in
            guard route != nil else { return }
            Task { await openPendingPushRoute() }
        }
        // 权限状态变化（用户刚拒绝 / 刚在设置里打开）→ 管理页那个入口要跟着出现/消失
        .onChange(of: environment.push.authorization) { _, value in
            pushDenied = value == .denied
        }
        // 回前台再心跳一次（App 可能在后台挂了几小时甚至几天，token 也可能被系统轮换）。
        // 重复调用不会造成多余请求：24 小时节流与"token 变了才重登记"都在 PushRegistrar 里。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await environment.startPush() }
        }
        .task {
            // 冷启动：点通知拉起 App 时 `didReceive` 早于这个视图出现（规格 §5.4），
            // 所以视图一出现就必须查一次"有没有待跳转"；运行中到达的由上面的 onChange 处理。
            // 顺带把权限状态取一次初值 —— onChange 不会为初始值触发。
            pushDenied = environment.push.isDenied
            await openPendingPushRoute()
        }
        .sheet(isPresented: $showAdmin) {
            // sheet 内部自己决定显示登录表单还是管理页（见 AdminGateView）
            AdminGateView(
                store: environment.auth,
                images: environment.adminList,
                uploads: environment.uploads,
                loader: environment.loader,
                // 权限被关掉时管理页给出"去系统设置"的出口（打开设置只能在 App target 做）
                pushDenied: pushDenied,
                onOpenNotificationSettings: { environment.openNotificationSettings() },
                // 进管理页才申请通知权限并注册 APNs（不在启动时申请，规格 §5.2）
                // 进管理页时再检查一次权限状态（比如用户刚在系统设置里打开），
                // 不再是"申请权限"的时机 —— 那个在启动时就做过了（见 PushCoordinator.start）。
                onEnterAdmin: { await environment.startPush() },
                // 上传成功 / 删除之后公开画廊要跟着变（与 web 的 revalidate 是同一件事）。
                // 必须"作废磁盘缓存 + 重拉"：只重拉的话，下次启动会先把旧缓存铺出来，
                // 用户看到的就是"重开 App 还是旧图"。
                onLibraryChanged: { await environment.gallery.invalidateCacheAndRefresh() },
                onDismiss: { showAdmin = false }
            )
        }
    }

    /// 消费"点通知要打开的那张图"：按 id 取公开 DTO → 交给已有的 `previewTarget` 打开预览。
    ///
    /// 复用 `APIClient.image(id:)`（已存在的 `GET /api/public/v1/images/:id`）而不是先拉列表：
    /// 深链接场景不必为一张图把首页翻一遍（规格 §5.4）。App 侧全局
    /// `.reloadIgnoringLocalCacheData` 保证拿到的不是 60 秒边缘缓存里的旧答案。
    private func openPendingPushRoute() async {
        guard let route = environment.pushRoutes.take() else { return }
        do {
            let image = try await environment.client.image(id: route.imageId)
            pushNotice = nil
            previewTarget = image
        } catch {
            pushNotice = "这条通知里的照片已不在画廊里"
            // 4 秒后自动消失；期间用户点了别的图也不影响
            try? await Task.sleep(for: .seconds(4))
            if pushNotice != nil { pushNotice = nil }
        }
    }

    @ViewBuilder
    private var pushNoticeView: some View {
        if let pushNotice {
            // 复用设计系统的纸卡（App target 拿不到 Kit 内部的 islandSurface，
            // 而且"描边 + 硬阴影"的顺序只允许在那个实现里出现一次）
            IslandCard(cornerRadius: 12, borderWidth: 1.5, hardShadowOffsetY: 2) {
                Text(pushNotice)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AnimalSignatures.cardText)
                    .padding(.horizontal, AnimalTokens.spacingMD)
                    .padding(.vertical, AnimalTokens.spacingSM)
            }
            .padding(.top, AnimalTokens.spacingMD)
            .accessibilityIdentifier("push-route-notice")
        }
    }
}

import SwiftUI

/// 管理入口的外壳：未登录显示登录表单，已登录显示管理页。
///
/// ## 为什么两步共用一个 sheet，而不是"登录成功再 push 一层"
/// 这是个两步就结束的流程。用一层导航的话，"关闭"要在两个地方各处理一次
/// （表单里返回、管理页里返回），而这两处必须表现一致 —— 多一个状态就多一处可能不一致。
/// 现在无论走到哪一步，关闭都只是把 sheet 收起来。
///
/// ## 依赖都是外面传进来的
/// 管理页要用带会话的管理接口、要显示缩略图、上传/删除后还要刷新公开画廊 ——
/// 这些都由 App target 装配（`AppEnvironment`），kit 里不认识它们的具体来源。
public struct AdminGateView: View {

    private let store: AuthStore
    private let images: AdminImageListStore
    private let uploads: UploadCoordinator
    private let loader: ImageLoader
    private let onLibraryChanged: () async -> Void
    private let onDismiss: () -> Void
    /// 系统通知权限被关闭（用户拒绝过，或后来在设置里关掉）。管理页据此给"去系统设置"的入口。
    private let pushDenied: Bool
    /// 打开系统设置里的本 App 通知开关（`UIApplication.openSettingsURLString` 只能在 App target 用）。
    private let onOpenNotificationSettings: () -> Void
    /// 进入管理页（登录成功 / 已有会话）时调用：申请通知权限并注册 APNs。
    /// **不在启动时申请**（规格 §5.2）：冷启动直接弹权限框同意率最低，而且那时还没有会话可以注册设备。
    private let onEnterAdmin: () async -> Void

    public init(
        store: AuthStore,
        images: AdminImageListStore,
        uploads: UploadCoordinator,
        loader: ImageLoader,
        pushDenied: Bool = false,
        onOpenNotificationSettings: @escaping () -> Void = {},
        onEnterAdmin: @escaping () async -> Void = {},
        onLibraryChanged: @escaping () async -> Void = {},
        onDismiss: @escaping () -> Void
    ) {
        self.store = store
        self.images = images
        self.uploads = uploads
        self.loader = loader
        self.pushDenied = pushDenied
        self.onOpenNotificationSettings = onOpenNotificationSettings
        self.onEnterAdmin = onEnterAdmin
        self.onLibraryChanged = onLibraryChanged
        self.onDismiss = onDismiss
    }

    public var body: some View {
        Group {
            if let user = store.currentUser {
                AdminHomeView(
                    user: user,
                    images: images,
                    uploads: uploads,
                    loader: loader,
                    isBusy: store.isWorking,
                    storageWarning: store.storageWarning,
                    pushDenied: pushDenied,
                    onOpenNotificationSettings: onOpenNotificationSettings,
                    onSignOut: {
                        // 登出是异步的（要告诉服务端吊销会话），但界面不该等它 ——
                        // 本地凭证在 signOut 里立刻清掉，然后由我们收起 sheet。
                        Task {
                            await store.signOut()
                            onDismiss()
                        }
                    },
                    onClose: onDismiss,
                    onLibraryChanged: onLibraryChanged
                )
                // 登录成功、或带着已有会话打开管理页时各触发一次。
                // `id` 用 user.id：同一账号反复进出不会重复弹框（系统本来也只会弹一次），
                // 但**换账号**必须重新走一遍（上一个账号登出时把这台设备停用了）。
                .task(id: user.id) {
                    await onEnterAdmin()
                }
            } else {
                AdminLoginView(
                    isBusy: store.isWorking,
                    errorMessage: store.errorMessage,
                    onCancel: onDismiss,
                    onSubmit: { email, password in
                        Task { await store.signIn(email: email, password: password) }
                    }
                )
            }
        }
    }
}

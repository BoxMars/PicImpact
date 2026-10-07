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

    public init(
        store: AuthStore,
        images: AdminImageListStore,
        uploads: UploadCoordinator,
        loader: ImageLoader,
        onLibraryChanged: @escaping () async -> Void = {},
        onDismiss: @escaping () -> Void
    ) {
        self.store = store
        self.images = images
        self.uploads = uploads
        self.loader = loader
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

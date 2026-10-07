import SwiftUI

/// 管理入口的外壳：未登录显示登录表单，已登录显示占位管理页。
///
/// ## 为什么两步共用一个 sheet，而不是"登录成功再 push 一层"
/// 这是个两步就结束的流程。用一层导航的话，"关闭"要在两个地方各处理一次
/// （表单里返回、管理页里返回），而这两处必须表现一致 —— 多一个状态就多一处可能不一致。
/// 现在无论走到哪一步，关闭都只是把 sheet 收起来。
public struct AdminGateView: View {

    private let store: AuthStore
    private let onDismiss: () -> Void

    public init(store: AuthStore, onDismiss: @escaping () -> Void) {
        self.store = store
        self.onDismiss = onDismiss
    }

    public var body: some View {
        Group {
            if let user = store.currentUser {
                AdminHomeView(
                    user: user,
                    isBusy: store.isWorking,
                    onSignOut: {
                        // 登出是异步的（要告诉服务端吊销会话），但界面不该等它 ——
                        // 本地凭证在 signOut 里立刻清掉，然后由我们收起 sheet。
                        Task {
                            await store.signOut()
                            onDismiss()
                        }
                    },
                    onClose: onDismiss
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

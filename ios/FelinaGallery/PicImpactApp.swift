import PicImpactKit
import SwiftUI

/// 应用入口。
///
/// 用 SwiftUI 生命周期（无 AppDelegate）。启动时按 `/config` 的能力开关装配界面 ——
/// 关闭的功能不显示入口，而不是显示了再报错。
@main
struct PicImpactApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .task { await environment.bootstrap() }
                // 恢复登录态与拉配置互不依赖，所以分成两个 task 并行，不用互相等
                .task { await environment.auth.restoreSession() }
        }
    }
}

/// 根视图：**只有画廊**。
///
/// 之前是「画廊 / 地图」两个 Tab，现已去掉 TabView —— 产品只需要一个画廊。
/// `MapGalleryView` 仍保留在 kit 里（有测试覆盖），将来若要加回不必重写。
struct RootView: View {
    let environment: AppEnvironment
    @State private var previewTarget: ImageDTO?
    /// 管理界面（登录 → 占位管理页）是否展示。
    ///
    /// 放在视图里而不是 AuthStore 里：它是"这个 sheet 开着没有"的界面状态，
    /// 与"凭证是否有效"是两件事 —— 会话失效不该自动把 sheet 关掉（用户正在输密码时会被打断）。
    @State private var showAdmin = false

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
        .sheet(isPresented: $showAdmin) {
            // sheet 内部自己决定显示登录表单还是管理页（见 AdminGateView）
            AdminGateView(
                store: environment.auth,
                images: environment.adminList,
                uploads: environment.uploads,
                loader: environment.loader,
                // 上传成功 / 删除之后公开画廊要跟着变（与 web 的 revalidate 是同一件事）
                onLibraryChanged: { await environment.gallery.refresh() },
                onDismiss: { showAdmin = false }
            )
        }
    }
}

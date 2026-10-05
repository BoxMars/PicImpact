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

    var body: some View {
        NavigationStack {
            HomeView(
                store: environment.gallery,
                loader: environment.loader,
                showDownload: environment.features.download,
                downloader: environment.downloader,
                // 标题与副标题现在显示在页面内的缎带上（与 Web 一致），导航栏不再重复
                headerTitle: environment.siteTitle,
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
    }
}

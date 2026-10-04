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
                onSelect: { previewTarget = $0 }
            )
            .navigationTitle(environment.siteTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $previewTarget) { image in
                PreviewView(
                    model: PreviewModel(
                        image: image,
                        loader: environment.loader,
                        downloader: environment.downloader
                    ),
                    features: environment.features
                )
            }
        }
        .tint(AnimalTokens.primary)
    }
}

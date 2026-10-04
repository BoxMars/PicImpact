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

/// 根视图：画廊 / 地图两个 Tab。
///
/// 地图 Tab 只在 `features.map` 为真时出现（契约里的能力协商）。
struct RootView: View {
    let environment: AppEnvironment
    @State private var selection = 0
    @State private var previewTarget: ImageDTO?

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                HomeView(
                    store: environment.gallery,
                    loader: environment.loader,
                    showDownload: environment.features.download,
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
            .tabItem { Label("画廊", systemImage: "photo.on.rectangle.angled") }
            .tag(0)

            if environment.features.map {
                NavigationStack {
                    MapTab(environment: environment, onSelect: { previewTarget = $0 })
                }
                .tabItem { Label("地图", systemImage: "map") }
                .tag(1)
            }
        }
        .tint(AnimalTokens.primary)
    }
}

/// 地图 Tab 自己的数据源：地图需要的是"有 GPS 的图"，与画廊首页的分页语义不同，
/// 因此单独取（对应 Web 的 `fetchMapImages`）。
private struct MapTab: View {
    let environment: AppEnvironment
    let onSelect: (ImageDTO) -> Void
    @State private var images: [ImageDTO] = []

    var body: some View {
        Group {
            if images.isEmpty {
                ContentUnavailableView("暂无带位置的照片", systemImage: "mappin.slash")
            } else {
                MapGalleryView(items: images, onSelect: onSelect)
            }
        }
        .navigationTitle("地图")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard images.isEmpty else { return }
            // 地图取首两页即可（Web 端也是一次性取回，数据量不大）
            var collected: [ImageDTO] = []
            for page in 1...2 {
                guard let result = try? await environment.client.images(page: page) else { break }
                collected.append(contentsOf: result.list)
                if !result.hasMore { break }
            }
            images = collected.filter(\.hasCoordinate)
        }
    }
}

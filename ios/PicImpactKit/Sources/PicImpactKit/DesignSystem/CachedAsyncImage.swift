import SwiftUI

/// 使用 `ImageLoader`（含三级缓存与请求合并）的异步图片视图。
///
/// 不用 `AsyncImage`：它每次出现在屏幕上都会重新走网络，且没有请求合并 ——
/// 画廊滚动时同一张图被多个视图同时请求是常态。
public struct CachedAsyncImage: View {
    private let url: URL?
    private let loader: ImageLoader
    private let contentMode: ContentMode
    private let onLoaded: ((PlatformImage) -> Void)?

    @State private var image: PlatformImage?
    @State private var didFail = false

    public init(
        url: URL?,
        loader: ImageLoader,
        contentMode: ContentMode = .fill,
        onLoaded: ((PlatformImage) -> Void)? = nil
    ) {
        self.url = url
        self.loader = loader
        self.contentMode = contentMode
        self.onLoaded = onLoaded
    }

    public var body: some View {
        Group {
            if let image {
                #if canImport(UIKit)
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                #elseif canImport(AppKit)
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                #endif
            } else if didFail {
                // 失败时不显示错误文案（画廊里会很吵），只留占位
                AnimalTokens.bgSecondary
            } else {
                AnimalTokens.bgSecondary
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: url) {
            guard let url else { return }
            didFail = false
            do {
                let loaded = try await loader.image(for: url)
                image = loaded
                onLoaded?(loaded)
            } catch {
                didFail = true
            }
        }
    }
}

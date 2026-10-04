import SwiftUI

/// 首页画廊（ACNH 岛屿卡 + 行优先瀑布流 + 无限滚动）。
///
/// 布局完全由 `MasonryLayout`（纯函数、已与浏览器实际渲染逐项对齐）算出，
/// 视图只负责把算好的 frame 应用上去 —— 这样"顺序对不对"不需要靠肉眼看。
public struct HomeView: View {
    @State private var store: GalleryStore
    private let loader: ImageLoader
    private let showDownload: Bool
    private let onSelect: (ImageDTO) -> Void

    public init(
        store: GalleryStore,
        loader: ImageLoader,
        showDownload: Bool = false,
        onSelect: @escaping (ImageDTO) -> Void = { _ in }
    ) {
        _store = State(initialValue: store)
        self.loader = loader
        self.showDownload = showDownload
        self.onSelect = onSelect
    }

    public var body: some View {
        GeometryReader { proxy in
            let padding = MasonryLayout.horizontalPadding(forWidth: proxy.size.width)
            let contentWidth = min(
                MasonryLayout.maxContainerWidth,
                max(0, proxy.size.width - padding * 2)
            )
            let columns = MasonryLayout.columns(forWidth: proxy.size.width)
            let layout = makeLayout(contentWidth: contentWidth, columns: columns)

            ScrollView {
                ZStack(alignment: .topLeading) {
                    // 透明占位撑出滚动高度
                    Color.clear.frame(height: layout.contentHeight)

                    ForEach(Array(store.images.enumerated()), id: \.element.id) { index, image in
                        let placement = layout.placements[index]
                        GalleryCell(
                            image: image,
                            columnWidth: layout.columnWidth,
                            loader: loader,
                            showDownload: showDownload,
                            onTap: { onSelect(image) },
                            onDownload: {}
                        )
                        // 布局只给"内容高度"，卡片自身高度由同一份计算得出，二者一致
                        .offset(x: placement.frame.minX, y: placement.frame.minY)
                        .onAppear {
                            // 接近末尾时预取下一页
                            if index >= store.images.count - 4 {
                                Task { await store.loadNextPage() }
                            }
                        }
                    }

                    if case let .failed(message) = store.phase, store.images.isEmpty {
                        failureView(message)
                            .frame(width: contentWidth, alignment: .center)
                            .padding(.top, 80)
                    }

                    if store.phase == .loadingFirstPage {
                        ProgressView()
                            .frame(width: contentWidth, height: 160, alignment: .center)
                    }
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .padding(.horizontal, padding)
                .padding(.vertical, AnimalTokens.spacingLG)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(AnimalTokens.bg)
            .refreshable { await store.refresh() }
            .task { await store.loadFirstPageIfNeeded() }
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: AnimalTokens.spacingMD) {
            Text(message)
                .font(.system(size: AnimalTokens.fontSize))
                .foregroundStyle(AnimalTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await store.retry() }
            }
            .buttonStyle(.borderedProminent)
            .tint(AnimalTokens.primary)
        }
    }

    /// 用同一份 `MasonryLayout` 计算放置位置。
    ///
    /// 每项的高度 = 图片等比缩放后的高度 + 固定信息块高度 ——
    /// 都在渲染之前就能算出，所以不需要"先渲染再测量"，也就不会出现重排跳动。
    private func makeLayout(contentWidth: CGFloat, columns: Int) -> MasonryLayout {
        let metrics = MasonryLayout.Metrics.web(containerWidth: contentWidth, columns: columns)
        let heights: [CGFloat] = store.images.map { image in
            let imageHeight: CGFloat = image.aspectRatio > 0
                ? max(1, metrics.columnWidth / image.aspectRatio)
                : metrics.columnWidth
            return imageHeight + GalleryCellMetrics.infoBlockHeight
        }
        return MasonryLayout.layout(heights: heights, metrics: metrics)
    }
}

private extension MasonryLayout {
    var columnWidth: CGFloat {
        placements.first?.frame.width ?? 0
    }
}

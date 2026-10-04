import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 首页画廊（ACNH 岛屿卡 + 行优先瀑布流 + 无限滚动）。
///
/// 布局由 `MasonryLayout`（纯函数，已与浏览器实际渲染逐项对齐）算出，视图只负责应用
/// 算好的 frame —— 这样"顺序对不对"不需要靠肉眼判定。
///
/// ## 高度从哪里来（这是与 Web 行为对齐的关键）
/// - 图片部分：由宽高比与列宽直接算出，渲染前即可知
/// - 信息块部分：内容长短不一（标题一两行、描述有无、EXIF 芯片是否换行、标签多少），
///   **必须实测**。这里让每个卡片用 `GeometryReader` 上报信息块自身高度，
///   回传后参与布局。
///
/// 之所以不会重蹈 Web 端的覆辙（测量值含预留间距 → 跨行数正反馈 → 每轮长 16px）：
/// 测量对象是**信息块的自然内容高度**，而卡片永远不会被容器拉伸
/// （`MasonryLayout` 只给偏移量，不给拉伸；容器也不是 Grid）。
public struct HomeView: View {
    @State private var store: GalleryStore
    @State private var infoHeights: [String: CGFloat] = [:]
    @State private var downloadingIDs: Set<String> = []

    private let loader: ImageLoader
    private let showDownload: Bool
    private let downloader: DownloadService?
    private let headerTitle: String
    private let headerSubtitle: String
    private let onSelect: (ImageDTO) -> Void

    public init(
        store: GalleryStore,
        loader: ImageLoader,
        showDownload: Bool = false,
        downloader: DownloadService? = nil,
        headerTitle: String = "大福映画 Felina Gallery",
        headerSubtitle: String = GalleryHeader.defaultSubtitle,
        onSelect: @escaping (ImageDTO) -> Void = { _ in }
    ) {
        _store = State(initialValue: store)
        self.loader = loader
        self.showDownload = showDownload
        self.downloader = downloader
        self.headerTitle = headerTitle
        self.headerSubtitle = headerSubtitle
        self.onSelect = onSelect
    }

    /// 尚未测量时的兜底高度。取"标题一行 + 描述 + EXIF 一行 + 操作行"的常见情形，
    /// 实测值到达后会立刻替换 —— 兜底只影响首帧，不会长期偏离。
    private static let estimatedInfoHeight: CGFloat = 150

    public var body: some View {
        GeometryReader { proxy in
            let padding = MasonryLayout.horizontalPadding(forWidth: proxy.size.width)
            let contentWidth = min(
                MasonryLayout.maxContainerWidth,
                max(0, proxy.size.width - padding * 2)
            )
            let columns = MasonryLayout.columns(forWidth: proxy.size.width)
            let metrics = MasonryLayout.Metrics.web(containerWidth: contentWidth, columns: columns)
            let layout = makeLayout(metrics: metrics)

            ScrollView {
              VStack(spacing: 0) {
                // 头部全宽（与 Web 一致：header 与 Divider 都在网格容器之外）
                GalleryHeader(
                    title: headerTitle,
                    subtitle: headerSubtitle,
                    photoCount: store.images.count
                )

                ZStack(alignment: .topLeading) {
                    Color.clear.frame(height: layout.contentHeight)

                    ForEach(Array(store.images.enumerated()), id: \.element.id) { index, image in
                        let placement = layout.placements[index]
                        cell(for: image, columnWidth: metrics.columnWidth)
                            .offset(x: placement.frame.minX, y: placement.frame.minY)
                            .onAppear {
                                if index >= store.images.count - 4 {
                                    Task { await store.loadNextPage() }
                                }
                            }
                    }

                    if case let .failed(message) = store.phase, store.images.isEmpty {
                        failureView(message)
                            .frame(width: contentWidth)
                            .padding(.top, 80)
                    }

                    // 只在**首次加载**时给内联指示器。
                    // 下拉刷新有自己的 .refreshing 状态，系统已经显示了指示器，
                    // 这里再画一个就会出现两个刷新图标。
                    if store.phase == .loadingFirstPage {
                        ProgressView().frame(width: contentWidth, height: 160)
                    }
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .padding(.horizontal, padding)
                // Web 的网格容器是 padding-top/bottom: 16
                .padding(.top, AnimalTokens.spacingLG)
                .padding(.bottom, AnimalTokens.spacingLG)
                .frame(maxWidth: .infinity, alignment: .center)
              }
            }
            .background(AnimalTokens.bg)
            .refreshable { await store.refresh() }
            .task { await store.loadFirstPageIfNeeded() }
        }
    }

    private func cell(for image: ImageDTO, columnWidth: CGFloat) -> some View {
        GalleryCell(
            image: image,
            columnWidth: columnWidth,
            loader: loader,
            showDownload: showDownload,
            isDownloading: downloadingIDs.contains(image.id),
            onTap: { onSelect(image) },
            onDownload: { Task { await performDownload(image) } },
            onCopyLink: { LinkActions.copyImageLink(image) },
            onShareLink: { LinkActions.copyShareLink(image) },
            onInfoHeightChange: { height in
                // 仅在变化超过半像素时更新，避免布局抖动与无谓的重算
                guard height > 0 else { return }
                if let current = infoHeights[image.id], abs(current - height) < 0.5 { return }
                infoHeights[image.id] = height
            }
        )
    }

    /// 用同一份 `MasonryLayout` 计算放置位置。
    /// 每项高度 = 图片等比缩放高度（可算） + 信息块实测高度（回退到估算值）
    private func makeLayout(metrics: MasonryLayout.Metrics) -> MasonryLayout {
        let heights: [CGFloat] = store.images.map { image in
            let imageHeight: CGFloat = image.aspectRatio > 0
                ? max(1, metrics.columnWidth / image.aspectRatio)
                : metrics.columnWidth
            let infoHeight = infoHeights[image.id] ?? Self.estimatedInfoHeight
            return imageHeight + infoHeight
        }
        return MasonryLayout.layout(heights: heights, metrics: metrics)
    }

    private func performDownload(_ image: ImageDTO) async {
        guard let downloader, !downloadingIDs.contains(image.id) else { return }
        downloadingIDs.insert(image.id)
        _ = try? await downloader.download(image)
        downloadingIDs.remove(image.id)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: AnimalTokens.spacingMD) {
            Text(message)
                .font(.system(size: AnimalTokens.fontSize))
                .foregroundStyle(AnimalTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await store.retry() } }
                .buttonStyle(.borderedProminent)
                .tint(AnimalTokens.primary)
        }
    }
}

/// 复制链接 / 分享直链。
///
/// 对应 Web 卡片操作行里的 `icon-diy`（复制图片链接）与 `icon-helicopter`（复制分享直链）。
/// 触屏上没有剪贴板失败的常见场景，但仍要给出反馈。
public enum LinkActions {
    /// 图片直链
    public static func copyImageLink(_ image: ImageDTO) {
        copy(image.url)
    }

    /// 站点地址。分享链接形如 `https://felina.boxz.dev/preview/<id>`
    /// （与 Web 的 `${origin}/preview/${id}` 语义一致）。
    public static let siteURL = URL(string: "https://felina.boxz.dev")!

    /// 分享链接本身。调系统分享面板时用它，复制到剪贴板时也用它 —— 只算一次。
    public static func shareURL(for image: ImageDTO, baseURL: URL = siteURL) -> URL {
        baseURL.appendingPathComponent("preview").appendingPathComponent(image.id)
    }

    /// 复制分享直链到剪贴板（保留：系统分享面板不可用时的降级路径）
    public static func copyShareLink(_ image: ImageDTO, baseURL: URL = siteURL) {
        copy(shareURL(for: image, baseURL: baseURL).absoluteString)
    }

    private static func copy(_ value: String) {
        guard !value.isEmpty else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #endif
    }
}

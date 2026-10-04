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
    /// 头部（缎带标题所在的那块）是否还在画面里。
    /// 滑出画面后右下角出现"回到顶部"，否则用户只能一路滑回去。
    @State private var isHeaderVisible = true
    /// 用来在"重新进入应用"时立即查询更新
    @Environment(\.scenePhase) private var scenePhase

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
        headerTitle: String = GalleryHeader.defaultTitle,
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

    /// 主动查询间隔（用户定为 1 分钟）。
    ///
    /// 另外**每次重新进入应用都会立即查询一次**（见下面的 scenePhase 处理），
    /// 所以这个间隔只影响"一直停留在应用里"的情况。
    static let updatePollInterval: Duration = .seconds(60)

    /// "回到顶部"滚动锚点的 id
    private static let topAnchorID = "home-top"

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

            ScrollViewReader { scrollProxy in
            ScrollView {
              VStack(spacing: 0) {
                // 头部全宽（与 Web 一致：header 与 Divider 都在网格容器之外）
                GalleryHeader(
                    title: headerTitle,
                    subtitle: headerSubtitle,
                    photoCount: store.images.count
                )
                .id(Self.topAnchorID)

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

                    // 首次加载时放**骨架块**，不放 spinner。
                    //
                    // 为什么彻底不用 spinner：下拉刷新由系统给出刷新指示器，
                    // 只要我自己也画一个 spinner，两者就可能同屏（首次加载在途时下拉刷新
                    // 就是这种情况：refresh() 因 guard 立刻返回，系统指示器亮了、
                    // 而 phase 仍是 .loadingFirstPage，内联那个也还亮着 —— 实测两个刷新）。
                    // 现在把"我自己画 spinner"这个可能性直接去掉，同屏最多只有一个。
                    if store.phase == .loadingFirstPage {
                        // ⚠️ 加载提示**不能参与布局**：之前那版骨架直接放进布局后，
                        // 真实卡片到达时页面会自己向下滚约 470pt（缎带标题被滚出画面）。
                        // 继续用"零高度 + 溢出的 overlay"：不改变滚动内容的高度。
                        Color.clear
                            .frame(height: 0)
                            .overlay(alignment: .top) {
                                GalleryLoadingIndicator()
                            }
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
            // 首页**保留沉浸式**：内容可以滚到状态栏底下（用户明确说明这条限制只针对详情页）
            .background(AnimalTokens.bg)
            .modifier(HeaderVisibilityTracker { visible in
                if visible != isHeaderVisible { isHeaderVisible = visible }
            })
            .refreshable { await store.refresh() }
            .task { await store.loadFirstPageIfNeeded() }
            // 每次重新进入应用立即查询一次更新 —— 无论是从后台返回，还是被杀掉后重新启动
            // （冷启动那条路径由上面的 loadFirstPageIfNeeded 负责：先出缓存、再后台校验）。
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await store.pollForUpdates() }
                }
            }
            // 每 5 秒主动查询网站是否有更新（用户要求）。
            // 只在页面存在期间运行；App 切到后台时 iOS 会挂起进程，轮询自然暂停。
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.updatePollInterval)
                    if Task.isCancelled { break }
                    await store.pollForUpdates()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isHeaderVisible {
                    IslandChevronButton(direction: .up, label: "顶部") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo(Self.topAnchorID, anchor: .top)
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isHeaderVisible)
            }
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

/// 画廊首次加载的骨架占位：两张与卡片同款式的空卡。
///
/// ## 为什么用骨架而不是 spinner
/// 下拉刷新由**系统**给出刷新指示器（`.refreshable`）。只要 App 自己也画 spinner，
/// 两者就可能同屏 —— 首次加载在途时下拉刷新就是这种情况：`refresh()` 因 `isLoading`
/// 守卫立刻返回，系统指示器亮了，而 `phase` 仍是 `.loadingFirstPage`，
/// 内联那个 spinner 也还亮着，用户看到的就是"两个刷新"。
///
/// 所以这里把"App 自己画 spinner"这个可能性直接去掉：同屏最多只剩系统那一个。
/// 图片占位同理（见 `CachedAsyncImage`）。
///
/// 首屏加载提示：ACNH 图标 + "加载中"。
///
/// 用户要求替换掉原来的两个占位框（"取消那个两个框框，换成 acnh 的图标+加载中"）。
///
/// ⚠️ 它会被放在"零高度 + 溢出 overlay"里使用，**不要**在这里写会影响父布局的修饰符 ——
/// 一旦它参与滚动内容的布局，真实卡片到达时页面会自己向下滚（曾经发生过，
/// 表现为"一打开在最底部、标题往下跑"）。
struct GalleryLoadingIndicator: View {
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 12) {
            AnimalIcon(.camera, size: 44)
                .opacity(pulsing ? 0.45 : 1)
                .scaleEffect(pulsing ? 0.94 : 1)
            Text("加载中")
                .font(.system(size: 13, weight: .heavy))
                .tracking(0.04 * 13)
                .foregroundStyle(AnimalTokens.textSecondary) // #9f927d
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
        .padding(.bottom, 40)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

/// 跟踪"头部（缎带标题）是否还在画面里"，用来决定何时显示"回到顶部"。
///
/// 为什么不用 PreferenceKey 上报 GeometryReader 的位置：实测那样上报的值
/// **恒为 default（0）**、不随滚动变化（`headerMinY=0` 只打印一次），按钮永远不出现。
/// `onScrollGeometryChange` 是专为读取滚动位置设计的 API，直接拿到 contentOffset。
///
/// 注意它是 **iOS 18+**；部署目标是 iOS 17，所以 iOS 17 上退化为"始终视为可见"
/// （也就是不显示回到顶部按钮）。
private struct HeaderVisibilityTracker: ViewModifier {
    let onChange: (Bool) -> Void

    /// 滚过这么多就算标题看不见了。
    /// 缎带标题在头部内偏下（顶部还有 40pt 内边距），所以阈值取 100。
    private static let threshold: CGFloat = 100

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                onChange(offset < Self.threshold)
            }
        } else {
            content
        }
    }
}

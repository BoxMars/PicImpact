import SwiftUI

/// 画廊卡片（simple / ACNH 主题）。
///
/// 结构逐项对应 Web 端 `components/gallery/simple/gallery-image.tsx` 的信息块：
///
/// ```
/// ① 标题 + 日期（两端对齐，baseline 对齐）
/// ② 描述
/// ③ EXIF 芯片行：相机 / 光圈 / 快门 / 焦距 / ISO —— **每个芯片带一个彩色 ACNH 图标**
/// ④ 标签（🏷 前缀）
/// ⑤ 分隔线（1px，#c4b89e 透明度 0.35）
/// ⑥ 操作行：复制链接 / 分享直链 / 下载原图 / 查看 EXIF
/// ```
///
/// ## 关于信息块高度
/// Web 端卡片高度是内容撑开的，瀑布流靠 `ResizeObserver` 实测。
/// iOS 侧这里也实测 —— 但**只测量信息块自身**，绝不测量被容器拉伸后的卡片
/// （Web 端踩过的坑：允许拉伸时测得高度会含预留间距，导致跨行数正反馈、每轮长 16px）。
/// 测得的真实高度回传给 `HomeView` 参与布局，因此卡片不会被留白撑高。
public struct GalleryCell: View {

    public let image: ImageDTO
    public let columnWidth: CGFloat
    public let loader: ImageLoader
    public let showDownload: Bool
    public let isDownloading: Bool
    public let onTap: () -> Void
    public let onDownload: () -> Void
    public let onCopyLink: () -> Void
    public let onShareLink: () -> Void
    public let onInfoHeightChange: (CGFloat) -> Void

    public init(
        image: ImageDTO,
        columnWidth: CGFloat,
        loader: ImageLoader,
        showDownload: Bool = false,
        isDownloading: Bool = false,
        onTap: @escaping () -> Void = {},
        onDownload: @escaping () -> Void = {},
        onCopyLink: @escaping () -> Void = {},
        onShareLink: @escaping () -> Void = {},
        onInfoHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.image = image
        self.columnWidth = columnWidth
        self.loader = loader
        self.showDownload = showDownload
        self.isDownloading = isDownloading
        self.onTap = onTap
        self.onDownload = onDownload
        self.onCopyLink = onCopyLink
        self.onShareLink = onShareLink
        self.onInfoHeightChange = onInfoHeightChange
    }

    /// 图片按列宽等比缩放后的高度（不裁切，与 Web 的 object-fit 语义一致）
    public var imageHeight: CGFloat {
        guard image.aspectRatio > 0 else { return columnWidth }
        return max(1, columnWidth / image.aspectRatio)
    }

    public var body: some View {
        Button(action: onTap) {
            IslandCard {
                VStack(alignment: .leading, spacing: 0) {
                    imageArea
                    infoBlock
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: InfoBlockHeightKey.self,
                                    value: proxy.size.height
                                )
                            }
                        }
                }
            }
        }
        // 用不带阴影的按压样式：卡片的厚度由 IslandCard 自己提供，
        // 再叠一层 IslandPressStyle 会让硬阴影被画两次（顶边出现第二条边框）
        .buttonStyle(IslandCardPressStyle())
        .frame(width: columnWidth)
        .onPreferenceChange(InfoBlockHeightKey.self) { height in
            onInfoHeightChange(height)
        }
    }

    // MARK: - 图片区

    private var imageArea: some View {
        CachedAsyncImage(url: image.displayURL, loader: loader, contentMode: .fill)
            .frame(width: columnWidth, height: imageHeight)
            .clipped()
            .overlay(alignment: .topLeading) {
                if image.isLivePhoto {
                    // 对应 Web 的 LIVE 角标
                    Text("LIVE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(AnimalSignatures.cardText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .circular))
                        .padding(6)
                }
            }
    }

    // MARK: - 信息块

    /// Web 的 `padding: '10px 14px 12px'` + `gap: 6`
    private enum Layout {
        static let topPadding: CGFloat = 10
        static let horizontalPadding: CGFloat = 14
        static let bottomPadding: CGFloat = 12
        static let gap: CGFloat = 6
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: Layout.gap) {
            titleRow
            descriptionRow
            exifRow
            tagsRow
            separator
            actionRow
        }
        .padding(.top, Layout.topPadding)
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.bottom, Layout.bottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ① 标题 + 日期
    @ViewBuilder
    private var titleRow: some View {
        let date = EXIFTimeFormatter.displayDate(fromEXIF: image.exif?.dataTime)
        if !image.title.isEmpty || date != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !image.title.isEmpty {
                    Text(image.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AnimalTokens.text) // #794f27
                        .lineSpacing(13 * 0.4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let date {
                    Text(date)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AnimalSignatures.cardBorder) // #c4b89e
                        .fixedSize()
                }
            }
        }
    }

    /// ② 描述
    @ViewBuilder
    private var descriptionRow: some View {
        if !image.detail.isEmpty {
            Text(image.detail)
                .font(.system(size: 12))
                .foregroundStyle(AnimalTokens.textSecondary) // #9f927d
                .lineSpacing(12 * 0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ③ EXIF 芯片行 —— 每个芯片一个彩色 ACNH 图标 + 值
    @ViewBuilder
    private var exifRow: some View {
        let chips = exifChips
        if !chips.isEmpty {
            // Web: flexWrap, gap '4px 10px', marginTop 2
            FlowLayout(rowSpacing: 4, columnSpacing: 10) {
                ForEach(chips, id: \.title) { chip in
                    HStack(spacing: 3) {
                        AnimalIcon(chip.icon, size: AnimalIconSize.chip)
                        Text(chip.value)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AnimalTokens.textSecondary) // #9f927d
                            .lineLimit(1)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// 测试可见：芯片构建规则里有几个容易抄错的细节（Web 的实现）
    struct Chip: Equatable {
        let title: String
        let icon: AnimalIconName
        let value: String
    }

    var exifChips: [Chip] {
        guard let exif = image.exif else { return [] }
        var chips: [Chip] = []

        // 相机：make + model（Web 要求两者都有才显示）
        if let make = exif.make, let model = exif.model {
            chips.append(Chip(title: "相机", icon: .camera, value: "\(make) \(model)"))
        }
        if let fNumber = exif.fNumber {
            chips.append(Chip(title: "光圈", icon: .variant, value: fNumber))
        }
        if let exposure = exif.exposureTime {
            chips.append(Chip(title: "曝光时间", icon: .miles, value: exposure))
        }
        if let focal = exif.focalLength {
            // Web 用 parseFloat(...).toFixed(0) + 'mm'
            let numeric = focal.prefix { $0.isNumber || $0 == "." }
            if let value = Double(numeric) {
                chips.append(Chip(title: "焦距", icon: .map, value: "\(Int(value.rounded()))mm"))
            }
        }
        if let iso = exif.isoSpeedRating {
            chips.append(Chip(title: "感光度 ISO", icon: .critterpedia, value: "ISO \(iso)"))
        }
        return chips
    }

    /// ④ 标签（🏷 前缀，与 Web 一致）
    @ViewBuilder
    private var tagsRow: some View {
        if !image.labels.isEmpty {
            FlowLayout(rowSpacing: 4, columnSpacing: 4) {
                ForEach(image.labels, id: \.self) { label in
                    Text("🏷 \(label)")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.3)
                        .foregroundStyle(AnimalTokens.primary) // #19c8b9
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(AnimalTokens.primaryBG) // #e6f9f6
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .circular))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .circular)
                                .strokeBorder(AnimalTokens.primary, lineWidth: 1.5)
                        }
                }
            }
            .padding(.top, 2)
        }
    }

    /// ⑤ 分隔线
    private var separator: some View {
        Rectangle()
            .fill(AnimalSignatures.cardBorder.opacity(0.35))
            .frame(height: 1)
            .padding(.vertical, 2)
    }

    /// ⑥ 操作行（Web: gap 14, height 24）
    private var actionRow: some View {
        // 按用户要求：卡片下方只保留**两个**按钮（分享 / 下载），并且**带文字**，
        // 且**不要边框**。不再提供"复制图片链接"（原来是 icon-diy 那个）。
        HStack(spacing: 8) {
            actionButton(icon: .helicopter, label: "分享", action: onShareLink)

            if showDownload {
                if isDownloading {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("下载中…")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AnimalTokens.textSecondary)
                    }
                    .frame(height: 26)
                } else {
                    actionButton(icon: .shopping, label: "下载", action: onDownload)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: 26)
    }

    /// 卡片操作按钮：图标 + 文字（无边框、无底色）
    private func actionButton(icon: AnimalIconName, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                AnimalIcon(icon, size: 16)
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AnimalSignatures.cardText) // #725d42
                    .fixedSize()
            }
            .frame(height: 26)
            // 按用户要求：不加边框。
            // 底色也一并去掉 —— 信息块本身就贴在纸色上，同色底纯属多余。
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 信息块高度上报（仅测量信息块自身，不测量整张卡片）
struct InfoBlockHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 简易流式布局（对应 CSS 的 `flex-wrap`）。
///
/// SwiftUI 没有内建 wrap 容器；`LazyVGrid` 会强制等宽列，与 Web 的"按内容宽度换行"不一致，
/// 所以这里按内容宽度自己折行。
public struct FlowLayout: Layout {
    public var rowSpacing: CGFloat
    public var columnSpacing: CGFloat

    public init(rowSpacing: CGFloat, columnSpacing: CGFloat) {
        self.rowSpacing = rowSpacing
        self.columnSpacing = columnSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + columnSpacing + size.width > maxWidth {
                totalHeight += rowHeight + rowSpacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? columnSpacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + columnSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

import SwiftUI

/// 详情页的信息数据。把 `PreviewModel` 的计算结果打包，便于视图与测试各自独立使用。
public struct PreviewInfoData: Equatable, Sendable {
    public var basicInfo: [PreviewModel.InfoRow] = []
    public var captureParams: [PreviewModel.ParamItem] = []
    public var deviceItems: [PreviewModel.DeviceItem] = []
    public var deviceFocalRow: PreviewModel.InfoRow?
    public var captureMode: [PreviewModel.InfoRow] = []
    public var technical: [PreviewModel.InfoRow] = []

    public init() {}

    /// 是否有任何内容可展示（全空时不渲染整块面板）
    public var isEmpty: Bool {
        basicInfo.isEmpty && captureParams.isEmpty && deviceItems.isEmpty
            && deviceFocalRow == nil && captureMode.isEmpty && technical.isEmpty
    }
}

/// 详情页的信息分区。
///
/// 分区与行内容严格对应 Web `preview-image.tsx`：
/// ```
/// 基本信息   尺寸 / 像素 / 拍摄时间
/// 拍摄参数   焦距 / 光圈 / 曝光时间 / 感光度   ← 带 ACNH 图标的胶囊，两列
/// 设备信息   icon-camera 厂商+机型 / icon-design 镜头 / 焦距
/// 拍摄模式   曝光程序 / 曝光模式 / 白平衡
/// 技术参数   位深度 / CFA 模式
/// ─── 影调分析 / 直方图由调用方接在后面 ───
/// ```
/// 分区之间用青色虚线（`IslandDashedDivider`），对应 Web 的 `<Divider type="dashed-teal">`。
public struct PreviewInfoSections: View {
    private let data: PreviewInfoData

    public init(data: PreviewInfoData) {
        self.data = data
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !data.basicInfo.isEmpty {
                section("Exif.basicInfo") {
                    rows(data.basicInfo)
                }
            }

            if !data.captureParams.isEmpty {
                divider
                section("Exif.captureParams") {
                    // Web 是 `grid grid-cols-2 gap-2`
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(data.captureParams) { item in
                            IslandParamBadge(icon: item.icon, value: item.value, label: item.label)
                        }
                    }
                }
            }

            if !data.deviceItems.isEmpty || data.deviceFocalRow != nil {
                divider
                section("Exif.deviceInfo") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(data.deviceItems) { item in
                            HStack(spacing: 6) {
                                AnimalIcon(item.icon, size: 14)
                                Text(item.text)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AnimalSignatures.cardText)
                                Spacer(minLength: 0)
                            }
                        }
                        if let row = data.deviceFocalRow {
                            IslandRow(label: row.label, value: row.value)
                        }
                    }
                }
            }

            if !data.captureMode.isEmpty {
                divider
                section("Exif.captureMode") {
                    rows(data.captureMode)
                }
            }

            if !data.technical.isEmpty {
                divider
                section("Exif.technicalParams") {
                    rows(data.technical)
                }
            }
        }
    }

    private var divider: some View {
        IslandDashedDivider()
    }

    @ViewBuilder
    private func section<Content: View>(
        _ titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IslandSectionTitle(IslandStrings.text(titleKey))
            content()
        }
    }

    private func rows(_ items: [PreviewModel.InfoRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { row in
                IslandRow(label: row.label, value: row.value)
            }
        }
    }
}

/// 详情页的操作行。
///
/// 对应 Web 的 `ActionBtn`：图标在上、文字在下（`flex-direction: column; gap: 4`），
/// 图标 20、文字 10pt / 700 / `#9f927d`，按钮内边距 `4 6`。
///
/// **图标与卡片不同**：详情页的"分享直链"用 `icon-chat`，
/// 而卡片里的同名操作用的是 `icon-helicopter` —— 两处本就不同，不能统一。
public struct PreviewActionRow: View {
    public struct Action: Identifiable {
        public let id: String
        public let icon: AnimalIconName
        public let label: String
        public let handler: () -> Void

        public init(id: String, icon: AnimalIconName, label: String, handler: @escaping () -> Void) {
            self.id = id
            self.icon = icon
            self.label = label
            self.handler = handler
        }
    }

    private let actions: [Action]

    public init(actions: [Action]) {
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(actions) { action in
                Button(action: action.handler) {
                    VStack(spacing: 4) {
                        AnimalIcon(action.icon, size: 20)
                        Text(action.label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AnimalTokens.textSecondary) // #9f927d
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.label)
            }
        }
    }
}

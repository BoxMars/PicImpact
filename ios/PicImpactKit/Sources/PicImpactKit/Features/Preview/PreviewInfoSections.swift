import SwiftUI

/// 详情页的信息数据。把 `PreviewModel` 的计算结果打包，便于视图与测试各自独立使用。
public struct PreviewInfoData: Equatable, Sendable {
    public var basicInfo: [PreviewModel.InfoRow] = []
    public var captureParams: [PreviewModel.InfoRow] = []
    public var device: [PreviewModel.InfoRow] = []
    public var captureMode: [PreviewModel.InfoRow] = []
    public var technical: [PreviewModel.InfoRow] = []

    public init() {}

    /// 是否有任何内容可展示（全空时不渲染整块面板）
    public var isEmpty: Bool {
        basicInfo.isEmpty && captureParams.isEmpty && device.isEmpty
            && captureMode.isEmpty && technical.isEmpty
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
                    // 按用户要求与其他分区一致：标签—值行，不带图标、不做两列
                    rows(data.captureParams)
                }
            }

            if !data.device.isEmpty {
                divider
                section("Exif.deviceInfo") {
                    rows(data.device)
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

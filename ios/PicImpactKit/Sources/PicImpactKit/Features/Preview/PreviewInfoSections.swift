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
    /// 双栏：设备方向与照片方向**不一致**时用两栏排布。
    private let twoColumn: Bool
    /// 影调分析与直方图也参与分栏（否则它们会整宽独占一行）。
    private let tone: ToneAnalysis?
    private let histogram: Histogram?

    public init(
        data: PreviewInfoData,
        twoColumn: Bool = false,
        tone: ToneAnalysis? = nil,
        histogram: Histogram? = nil
    ) {
        self.data = data
        self.twoColumn = twoColumn
        self.tone = tone
        self.histogram = histogram
    }

    /// 一个可排布的分区。除了"标签—值"行，还可能是图表（影调分析 / 直方图）。
    private struct Item: Identifiable {
        enum Kind {
            case rows([PreviewModel.InfoRow])
            case tone(ToneAnalysis)
            case histogram(Histogram)
        }

        let id: String
        let titleKey: String
        let kind: Kind
    }

    /// 目前要展示的分区（顺序与 Web 一致）。
    ///
    /// 改写成列表是为了能按宽度**分到两栏** —— 之前是一串内联 if，没法切。
    private var items: [Item] {
        var out: [Item] = []
        if !data.basicInfo.isEmpty {
            out.append(Item(id: "basic", titleKey: "Exif.basicInfo", kind: .rows(data.basicInfo)))
        }
        if !data.captureParams.isEmpty {
            out.append(Item(id: "params", titleKey: "Exif.captureParams", kind: .rows(data.captureParams)))
        }
        if !data.device.isEmpty {
            out.append(Item(id: "device", titleKey: "Exif.deviceInfo", kind: .rows(data.device)))
        }
        if !data.captureMode.isEmpty {
            out.append(Item(id: "mode", titleKey: "Exif.captureMode", kind: .rows(data.captureMode)))
        }
        if !data.technical.isEmpty {
            out.append(Item(id: "tech", titleKey: "Exif.technicalParams", kind: .rows(data.technical)))
        }
        // 图表排在信息分区之后（与 Web 顺序一致），并且**参与同一套分栏**
        if let tone {
            out.append(Item(id: "tone", titleKey: "Exif.toneAnalysis", kind: .tone(tone)))
        }
        return out
    }

    @ViewBuilder
    private func content(of item: Item) -> some View {
        switch item.kind {
        case .rows(let rows):
            self.rows(rows)
        case .tone(let tone):
            ToneAnalysisView(analysis: tone)
        case .histogram(let histogram):
            HistogramPanel(histogram: histogram)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            columns
            // 直方图**整宽单独一行**（用户要求）—— 它也参与分栏的话，
            // 上面那条亮蓝色虚线只会跨半栏，与卡片其它分隔线对不齐。
            if let histogram {
                IslandDashedDivider()
                section("Exif.histogram") {
                    HistogramPanel(histogram: histogram)
                }
            }
        }
    }

    @ViewBuilder
    private var columns: some View {
        if twoColumn {
            // 按**连续**顺序对半分（前半在左、后半在右），而不是奇偶项交替。
            //
            // 原来按奇偶分（左：基本信息/设备信息/技术参数，右：拍摄参数/拍摄模式），
            // 读起来是断的 —— 用户反馈"信息栏也弄反了"。连续分栏后，
            // 从上到下・先左后右的顺序与单栏时一致。
            let half = (items.count + 1) / 2
            HStack(alignment: .top, spacing: 24) {
                column(Array(items.prefix(half)))
                column(Array(items.dropFirst(half)))
            }
        } else {
            column(items)
        }
    }

    @ViewBuilder
    private func column(_ list: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(list) { item in
                // 每栏内，除第一项外都在前面加分隔线（与单栏版本的观感一致）
                if item.id != list.first?.id {
                    divider
                }
                section(item.titleKey) {
                    content(of: item)
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

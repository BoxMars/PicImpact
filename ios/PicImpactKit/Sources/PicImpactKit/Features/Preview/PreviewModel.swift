import Foundation
import Observation

/// 预览页状态机。
///
/// 独立于视图的理由同 `GalleryStore`：这里的状态组合并不简单 ——
/// 缩略图先到、原图后到（交叉淡入）、分析结果各自异步、下载是第三种独立状态。
/// 把这些塞进视图里，任何一个分支出错都只能靠手点复现。
@Observable
@MainActor
public final class PreviewModel {

    public enum LoadPhase: Equatable, Sendable {
        case idle
        case loadingPreview
        case previewReady
        case originalReady
        case failed(String)
    }

    public struct EXIFRow: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let value: String
    }

    public private(set) var phase: LoadPhase = .idle
    public private(set) var previewImage: PlatformImage?
    public private(set) var originalImage: PlatformImage?
    public private(set) var tone: ToneAnalysis?
    public private(set) var histogram: Histogram?
    public private(set) var isDownloading = false
    public private(set) var downloadError: String?

    public let image: ImageDTO

    private let loader: ImageLoader
    private let downloader: DownloadService?

    public init(image: ImageDTO, loader: ImageLoader, downloader: DownloadService? = nil) {
        self.image = image
        self.loader = loader
        self.downloader = downloader
    }

    /// 缩略图是否已经可以显示（对应 Web 的底图先淡入）
    public var showsPreview: Bool { previewImage != nil }

    /// 原图是否已就绪（对应 Web 的 HD 层淡入）
    public var showsOriginal: Bool { originalImage != nil }

    // MARK: - 加载

    /// 先取缩略图（立刻可见），再后台取原图；两者都就绪后做分析。
    ///
    /// 顺序是有意的：若先等原图，用户会盯着空白屏；而且原图 4~5MB，
    /// 先缩略图能让首屏有意义的内容尽快出现（与 Web 的行为一致）。
    public func load() async {
        guard phase == .idle || isFailed else { return }
        phase = .loadingPreview

        // 1) 缩略图
        if let url = image.displayURL {
            do {
                previewImage = try await loader.image(for: url)
                phase = .previewReady
            } catch {
                phase = .failed(Self.describe(error))
                return
            }
        }

        // 2) 原图（失败不算致命：缩略图仍然可看）
        if let originalURL = image.originalURL, originalURL != image.displayURL {
            if let original = try? await loader.image(for: originalURL) {
                originalImage = original
                phase = .originalReady
            }
        } else if previewImage != nil {
            // 没有独立原图时，缩略图就是最终图
            originalImage = previewImage
            phase = .originalReady
        }

        // 3) 分析（用原图优先，回退缩略图）
        await runAnalysis()
    }

    /// 分析用图：优先原图，回退缩略图
    public func runAnalysis() async {
        guard let source = originalImage ?? previewImage else { return }
        let toneResult = PixelSampler.analyzeTone(from: source)
        let histogramResult = PixelSampler.histogram(from: source)
        tone = toneResult
        histogram = histogramResult
    }

    // MARK: - 下载

    public func download() async {
        guard let downloader, !isDownloading else { return }
        isDownloading = true
        downloadError = nil
        do {
            try await downloader.download(image)
        } catch {
            downloadError = error.localizedDescription
        }
        isDownloading = false
    }

    // MARK: - 分区展示数据
    //
    // 结构与 Web `preview-image.tsx` 的分区一一对应：
    //   基本信息 / 拍摄参数 / 设备信息 / 拍摄模式 / 技术参数
    // 文案取自同一份 i18n 表（`IslandStrings`），因此两端**措辞**也一致。

    public struct InfoRow: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let value: String
    }

    /// 拍摄参数胶囊：图标 + 值 + 无障碍标签
    public struct ParamItem: Identifiable, Equatable, Sendable {
        public let id: String
        public let icon: AnimalIconName
        public let value: String
        public let label: String
    }

    /// 设备信息里的"图标 + 文本"行
    public struct DeviceItem: Identifiable, Equatable, Sendable {
        public let id: String
        public let icon: AnimalIconName
        public let text: String
    }

    /// 焦距文本。
    ///
    /// Web 用 `parseFloat(focal_length).toFixed(2) + ' mm'` → `"5.96 mm"`。
    /// **注意与卡片的区别**：卡片里是 `toFixed(0)` → `"6mm"`，两处格式不同，不能互相套用。
    public var focalLengthText: String? {
        guard let raw = image.exif?.focalLength else { return nil }
        // 取前导数字部分，等价于 JS 的 parseFloat
        let head = raw.drop(while: { $0 == " " }).prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })
        guard let value = Double(head) else { return nil }
        return String(format: "%.2f mm", value)
    }

    /// 基本信息：尺寸 / 像素 / 拍摄时间
    public var basicInfoRows: [InfoRow] {
        var rows: [InfoRow] = []
        if let dimensions = dimensionsText {
            rows.append(InfoRow(id: "dimensions", label: IslandStrings.text("Exif.dimensions"), value: dimensions))
        }
        if let megapixels = megapixelsText {
            rows.append(InfoRow(id: "pixels", label: IslandStrings.text("Exif.pixels"), value: megapixels))
        }
        if let time = EXIFTimeFormatter.displayDate(fromEXIF: image.exif?.dataTime), !time.isEmpty {
            rows.append(InfoRow(id: "data_time", label: IslandStrings.text("Exif.captureTime"), value: time))
        }
        return rows
    }

    /// 拍摄参数：焦距 / 光圈 / 曝光时间 / 感光度（顺序与 Web 一致）
    ///
    /// 关于这几个标签的文案来源：Web 里宽度参数胶囊的 `label` 是**硬编码中文字面量**
    /// （"焦距"/"光圈"/"曝光时间"/"感光度"），只有"焦距"在 i18n 表里另有同值条目。
    /// 这里照实处理：有键的走 i18n，没有的用字面量 —— 不去编造不存在的键。
    public var captureParams: [ParamItem] {
        var items: [ParamItem] = []
        if let focal = focalLengthText {
            items.append(ParamItem(id: "focal_length", icon: .map, value: focal, label: "焦距"))
        }
        if let fNumber = image.exif?.fNumber, !fNumber.isEmpty {
            items.append(ParamItem(id: "f_number", icon: .variant, value: fNumber, label: "光圈"))
        }
        if let exposure = image.exif?.exposureTime, !exposure.isEmpty {
            items.append(ParamItem(id: "exposure_time", icon: .miles, value: exposure, label: "曝光时间"))
        }
        if let iso = image.exif?.isoSpeedRating, !iso.isEmpty {
            items.append(ParamItem(id: "iso", icon: .critterpedia, value: "ISO \(iso)", label: "感光度"))
        }
        return items
    }

    /// 设备信息：厂商+机型、镜头（都带图标）
    public var deviceItems: [DeviceItem] {
        var items: [DeviceItem] = []
        // Web 要求 make 与 model **同时存在**才显示这一行
        if let make = image.exif?.make, !make.isEmpty,
           let model = image.exif?.model, !model.isEmpty {
            items.append(DeviceItem(id: "camera", icon: .camera, text: "\(make) \(model)"))
        }
        if let lens = image.exif?.lensModel, !lens.isEmpty {
            items.append(DeviceItem(id: "lens", icon: .design, text: lens))
        }
        return items
    }

    /// 设备信息里的焦距行（与拍摄参数里的重复，Web 两端都显示，故保留）
    public var deviceFocalRow: InfoRow? {
        guard let focal = focalLengthText else { return nil }
        return InfoRow(id: "device_focal", label: IslandStrings.text("Exif.focalLength"), value: focal)
    }

    /// 拍摄模式：曝光程序 / 曝光模式 / 白平衡
    public var captureModeRows: [InfoRow] {
        var rows: [InfoRow] = []
        if let program = image.exif?.exposureProgram, !program.isEmpty {
            rows.append(InfoRow(id: "exposure_program", label: IslandStrings.text("Exif.exposureProgram"), value: program))
        }
        if let mode = image.exif?.exposureMode, !mode.isEmpty {
            rows.append(InfoRow(id: "exposure_mode", label: IslandStrings.text("Exif.exposureMode"), value: mode))
        }
        if let balance = image.exif?.whiteBalance, !balance.isEmpty {
            rows.append(InfoRow(id: "white_balance", label: IslandStrings.text("Exif.whiteBalance"), value: balance))
        }
        return rows
    }

    /// 技术参数：位深度 / CFA 模式
    public var technicalRows: [InfoRow] {
        var rows: [InfoRow] = []
        if let bits = image.exif?.bits, !bits.isEmpty {
            rows.append(InfoRow(id: "bits", label: IslandStrings.text("Exif.bitDepth"), value: bits))
        }
        if let cfa = image.exif?.cfaPattern, !cfa.isEmpty {
            rows.append(InfoRow(id: "cfa_pattern", label: IslandStrings.text("Exif.cfaPattern"), value: cfa))
        }
        return rows
    }

    /// 打包成详情页视图需要的分区数据
    public var infoData: PreviewInfoData {
        var data = PreviewInfoData()
        data.basicInfo = basicInfoRows
        data.captureParams = captureParams
        data.deviceItems = deviceItems
        data.deviceFocalRow = deviceFocalRow
        data.captureMode = captureModeRows
        data.technical = technicalRows
        return data
    }

    public var dimensionsText: String? {
        guard image.width > 0, image.height > 0 else { return nil }
        return "\(image.width) × \(image.height)"
    }

    /// 百万像素，保留一位小数（与 Web 的展示方式一致）
    public var megapixelsText: String? {
        guard image.width > 0, image.height > 0 else { return nil }
        let megapixels = Double(image.width) * Double(image.height) / 1_000_000
        return String(format: "%.1f MP", megapixels)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private static func describe(_ error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.errorDescription ?? "加载失败"
        }
        return error.localizedDescription
    }
}

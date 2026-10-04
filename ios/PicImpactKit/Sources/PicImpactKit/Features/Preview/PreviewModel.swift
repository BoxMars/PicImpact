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

    // MARK: - EXIF 行

    /// 构建 EXIF 展示行。
    ///
    /// **只展示 Web 端实际读取的字段**（见 `preview-image.tsx`）——
    /// 多展示或少展示都会让两端信息不一致。
    public func exifRows() -> [EXIFRow] {
        var rows: [EXIFRow] = []

        func add(_ key: String, _ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            rows.append(EXIFRow(id: key, label: label, value: value))
        }

        add("dimensions", "尺寸", dimensionsText)
        add("pixels", "像素", megapixelsText)
        add("data_time", "拍摄时间", EXIFTimeFormatter.displayString(fromEXIF: image.exif?.dataTime))
        add("make", "厂商", image.exif?.make)
        add("model", "相机", image.exif?.model)
        add("lens_model", "镜头", image.exif?.lensModel)
        add("focal_length", "焦距", image.exif?.focalLength)
        add("f_number", "光圈", image.exif?.fNumber)
        add("exposure_time", "快门", image.exif?.exposureTime)
        add("exposure_program", "曝光程序", image.exif?.exposureProgram)
        add("iso_speed_rating", "ISO", image.exif?.isoSpeedRating)
        add("bits", "位深", image.exif?.bits)

        return rows
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

import Foundation
import ImageIO

/// 从原图字节里读 EXIF，并**按 Web 端的形态**整理成登记接口要的 JSON 对象。
///
/// ## 为什么格式要对齐
/// `images.exif` 是原样透传的 JSON，App 与 Web 写进去的形态必须一致，否则同一张图
/// 在两端显示不同（评审要点 3）。形态基准是生产库里已有的数据（Web 用 ExifReader）：
/// ```json
/// {"make":"Apple","model":"iPhone 15","bits":"8","data_time":"2026:10:06 15:42:40",
///  "exposure_time":"1/39","f_number":"f/1.6","exposure_program":"Normal program",
///  "iso_speed_rating":640,"focal_length":"5.96 mm","lens_specification":"5.96-5.96 mm f/1.6",
///  "lens_model":"iPhone 15 back dual wide camera 5.96mm f/1.6","exposure_mode":"Auto exposure",
///  "color_space":"Uncalibrated","white_balance":"Auto white balance"}
/// ```
/// 注意几个容易做错的地方：
/// - `exposure_time` 是**展示形态** `"1/39"`，不是 `0.0256`；
/// - `f_number` 带前缀 `"f/1.6"`；`focal_length` 带单位 `"5.96 mm"`；
/// - `iso_speed_rating` 是**数字**（因为服务端 API 与 App 的解码都是宽松的，但 Web 存的是数字，
///   保持一致才能让"相机/镜头"筛选与分析页的行为一致）；
/// - 相机/镜头筛选依赖 `model` 与 `lens_model`（`server/db/query/images.ts` 按
///   `exif->>'model'` / `exif->>'lens_model'` 过滤），所以这两个字段尤其不能少。
///
/// ## 为什么不用第三方库
/// ImageIO（系统框架）就能拿到 TIFF/EXIF 字典；本项目不允许引入第三方依赖
/// （也正因如此 blurhash 交给了服务端算）。
public enum ImageEXIFReader {

    /// 一张图的元数据：EXIF + **应用 EXIF 方向之后**的显示尺寸。
    ///
    /// 尺寸只是"兜底"：服务端会用原图的真实显示尺寸覆盖 `images.width/height`
    /// （`server/lib/preview-storage.ts` 的 `readDisplaySize`）。但兜底值也不能是错的 ——
    /// 方向为 5~8 时宽高要互换，否则服务端万一没能下载原图，库里就留下一个横竖颠倒的宽高比。
    public struct ImageMetadata: Sendable, Equatable {
        public let exif: [String: JSONValue]
        public let width: Int
        public let height: Int

        public init(exif: [String: JSONValue], width: Int, height: Int) {
            self.exif = exif
            self.width = width
            self.height = height
        }
    }

    /// 一次解析拿到 EXIF 与尺寸（避免同一份数据解析两遍）
    public static func metadata(from data: Data) -> ImageMetadata {
        guard let properties = properties(from: data) else {
            return ImageMetadata(exif: [:], width: 0, height: 0)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swap = orientation >= 5 && orientation <= 8
        return ImageMetadata(
            exif: exif(from: properties),
            width: swap ? height : width,
            height: swap ? width : height
        )
    }

    /// 读 EXIF。解不出任何东西时返回空字典（**不是**失败）——
    /// 一张没有 EXIF 的图（截图、微信导出图）本来就该照常上传。
    public static func read(from data: Data) -> [String: JSONValue] {
        guard let properties = properties(from: data) else { return [:] }
        return exif(from: properties)
    }

    private static func properties(from data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties
    }

    private static func exif(from properties: [CFString: Any]) -> [String: JSONValue] {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]

        var result: [String: JSONValue] = [:]

        func putString(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            result[key] = .string(value)
        }

        /// 原始数字 → 展示形态（例如 1.6 → "f/1.6"）
        func putFormatted(_ key: String, _ value: Double?, _ transform: (Double) -> String?) {
            guard let value, let text = transform(value) else { return }
            result[key] = .string(text)
        }

        /// 原始数字 → 枚举名（例如 2 → "Normal program"）
        func putNamed(_ key: String, _ value: Double?, _ transform: (Int) -> String?) {
            guard let value, let text = transform(Int(value)) else { return }
            result[key] = .string(text)
        }

        putString("make", string(tiff[kCGImagePropertyTIFFMake]))
        putString("model", string(tiff[kCGImagePropertyTIFFModel]))
        // TIFF 的 BitsPerSample 没有公开常量，只能按标签名取。
        // 实测：用 ImageIO 写 JPEG 时那个键会被丢掉，但顶层会留下 Depth（=8），所以两级兜底。
        putString("bits", string(tiff["BitsPerSample" as CFString]) ?? string(properties[kCGImagePropertyDepth]))
        putString("data_time", string(exif[kCGImagePropertyExifDateTimeOriginal]) ?? string(exif[kCGImagePropertyExifDateTimeDigitized]))
        putFormatted("exposure_time", number(exif[kCGImagePropertyExifExposureTime]), exposureTime)
        putFormatted("f_number", number(exif[kCGImagePropertyExifFNumber]), fNumber)
        putNamed("exposure_program", number(exif[kCGImagePropertyExifExposureProgram]), exposureProgramName)
        result["iso_speed_rating"] = isoValue(exif)
        putFormatted("focal_length", number(exif[kCGImagePropertyExifFocalLength]), focalLength)
        putString("lens_specification", lensSpecification(exif[kCGImagePropertyExifLensSpecification]))
        putString("lens_model", string(exif[kCGImagePropertyExifLensModel]))
        putNamed("exposure_mode", number(exif[kCGImagePropertyExifExposureMode]), exposureModeName)
        putNamed("white_balance", number(exif[kCGImagePropertyExifWhiteBalance]), whiteBalanceName)
        putNamed("color_space", number(exif[kCGImagePropertyExifColorSpace]), colorSpaceName)

        return result
    }

    // MARK: - 展示形态（纯函数，单测直接断言）

    /// `0.0256` → `"1/39"`；`2` → `"2"`。与 ExifReader 的 `description` 形态一致。
    public static func exposureTime(_ seconds: Double) -> String? {
        guard seconds > 0, seconds.isFinite else { return nil }
        if seconds >= 1 {
            return JSONValue.trim(seconds)
        }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    /// `1.6` → `"f/1.6"`
    public static func fNumber(_ value: Double) -> String? {
        guard value > 0, value.isFinite else { return nil }
        return "f/\(JSONValue.trim(value))"
    }

    /// `5.96` → `"5.96 mm"`
    public static func focalLength(_ value: Double) -> String? {
        guard value > 0, value.isFinite else { return nil }
        return "\(JSONValue.trim(value)) mm"
    }

    /// `[5.96, 5.96, 1.6, 1.6]` → `"5.96-5.96 mm f/1.6"`
    public static func lensSpecification(_ values: [Double]) -> String? {
        guard values.count == 4, values.allSatisfy({ $0.isFinite }) else { return nil }
        // 焦距区间**始终**写成 `a-b mm`（生产库里 5.96-5.96 也是这么存的，来自 ExifReader）；
        // 光圈相等时收成单个值（`f/1.6`），不等时才写区间。
        let focal = "\(JSONValue.trim(values[0]))-\(JSONValue.trim(values[1]))"
        let aperture = values[2] == values[3]
            ? JSONValue.trim(values[2])
            : "\(JSONValue.trim(values[2]))-\(JSONValue.trim(values[3]))"
        return "\(focal) mm f/\(aperture)"
    }

    /// EXIF ExposureProgram 枚举 → ExifReader 的英文描述
    public static func exposureProgramName(_ value: Int) -> String? {
        switch value {
        case 0: return "Not defined"
        case 1: return "Manual"
        case 2: return "Normal program"
        case 3: return "Aperture priority"
        case 4: return "Shutter priority"
        case 5: return "Creative program"
        case 6: return "Action program"
        case 7: return "Portrait mode"
        case 8: return "Landscape mode"
        default: return nil
        }
    }

    public static func exposureModeName(_ value: Int) -> String? {
        switch value {
        case 0: return "Auto exposure"
        case 1: return "Manual exposure"
        case 2: return "Auto bracket"
        default: return nil
        }
    }

    public static func whiteBalanceName(_ value: Int) -> String? {
        switch value {
        case 0: return "Auto white balance"
        case 1: return "Manual white balance"
        default: return nil
        }
    }

    public static func colorSpaceName(_ value: Int) -> String? {
        switch value {
        case 1: return "sRGB"
        case 65535: return "Uncalibrated"
        default: return nil
        }
    }

    // MARK: - 桥接（ImageIO 给的是 NSNumber/NSString/NSArray，类型不保证）

    private static func string(_ raw: Any?) -> String? {
        switch raw {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return JSONValue.trim(value.doubleValue)
        default:
            return nil
        }
    }

    private static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    /// ISO 在 EXIF 里可能是 `ISOSpeedRatings`（数组）或数字
    private static func isoValue(_ exif: [CFString: Any]) -> JSONValue? {
        let raw = exif[kCGImagePropertyExifISOSpeedRatings]
        if let values = raw as? [NSNumber], let first = values.first {
            return .int(first.intValue)
        }
        if let value = raw as? NSNumber {
            return .int(value.intValue)
        }
        return nil
    }

    private static func lensSpecification(_ raw: Any?) -> String? {
        guard let values = raw as? [NSNumber], values.count == 4 else { return nil }
        return lensSpecification(values.map(\.doubleValue))
    }
}

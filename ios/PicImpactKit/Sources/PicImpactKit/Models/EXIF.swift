import Foundation

/// EXIF 数据。
///
/// 服务端**原样透传**整个 EXIF 对象（不做字段白名单），目的是让服务端新增 EXIF 字段
/// 不需要发新版 App。因此这里：
///   - 只声明我们真正要用的字段（与 Web 端 `preview-image.tsx` 读取的一致）
///   - **其余一律忽略**（Decodable 默认行为，不需要额外配置）
///   - 所有字段都用 `LenientString`，因为服务端类型不统一（生产实测
///     `iso_speed_rating` 是数字而 `bits` 是字符串）
public struct EXIF: Decodable, Sendable, Equatable {
    public let make: String?
    public let model: String?
    public let lensModel: String?
    public let focalLength: String?
    public let fNumber: String?
    public let exposureTime: String?
    public let exposureProgram: String?
    /// 生产实测类型为**数字**（如 640），故走宽松解码
    public let isoSpeedRating: String?
    /// EXIF 原始时间格式：`2026:10:02 20:15:12`，需经 `EXIFTimeFormatter` 归一化
    public let dataTime: String?
    public let bits: String?
    public let cfaPattern: String?

    enum CodingKeys: String, CodingKey {
        case make
        case model
        case lensModel = "lens_model"
        case focalLength = "focal_length"
        case fNumber = "f_number"
        case exposureTime = "exposure_time"
        case exposureProgram = "exposure_program"
        case isoSpeedRating = "iso_speed_rating"
        case dataTime = "data_time"
        case bits
        case cfaPattern = "cfa_pattern"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            (try? c.decodeIfPresent(LenientString.self, forKey: key))??.value
        }
        make = text(.make)
        model = text(.model)
        lensModel = text(.lensModel)
        focalLength = text(.focalLength)
        fNumber = text(.fNumber)
        exposureTime = text(.exposureTime)
        exposureProgram = text(.exposureProgram)
        isoSpeedRating = text(.isoSpeedRating)
        dataTime = text(.dataTime)
        bits = text(.bits)
        cfaPattern = text(.cfaPattern)
    }
}

/// EXIF 时间归一化。
///
/// **必须复刻 Web 端的 `lib/utils/exif-time.ts` 规则**，否则同一张图在两端显示的时间会不同。
/// EXIF 的原始格式是 `YYYY:MM:DD HH:MM:SS`（冒号分隔日期），不是标准 ISO 形式，
/// 直接丢给 `DateFormatter` 硬解会得到错误结果或 nil。
public enum EXIFTimeFormatter {

    /// 归一化为 `yyyy-MM-dd HH:mm:ss`；无法解析时返回 nil（界面应自行决定如何降级）
    public static func displayString(fromEXIF raw: String?) -> String? {
        guard let date = parse(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 解析 EXIF 原始时间。
    /// 兼容两种写法：`2026:10:02 20:15:12`（EXIF 标准）与 `2026-10-02 20:15:12`（部分设备）。
    ///
    /// 注意：`DateFormatter` 与 `ISO8601DateFormatter` 没有共同的可调用父类型，
    /// 不能塞进同一个数组去遍历（那样数组会退化成 `[Formatter]`，没有 `date(from:)`）。
    /// 另外这里每次新建 formatter —— 它们都不是 `Sendable`，共享静态实例在
    /// Swift 6 严格并发下无法编译。
    public static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespaces)

        for pattern in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = pattern
            if let date = formatter.date(from: normalized) { return date }
        }

        return APIDecoding.parseISO8601(normalized)
    }
}

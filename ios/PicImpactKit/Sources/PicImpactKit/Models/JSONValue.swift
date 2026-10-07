import Foundation

/// 任意 JSON 值。
///
/// ## 为什么需要它
/// 上传登记接口的 `exif` 是一个**服务端原样透传**的 JSON 对象（见 `server/db/operate/images.ts`
/// 里 `exif: image.exif` 直接写库），字段类型并不统一：生产实测 `iso_speed_rating` 是**数字**，
/// 而 `make` / `exposure_time` 是字符串。Swift 里没有一个"随便什么 JSON"的内建类型：
/// 用 `[String: Any]` 不可 `Codable`、不可 `Sendable`，在 Swift 6 严格并发下根本传不出去。
///
/// 所以用这个枚举把 EXIF 读出来的字典装起来 —— 它能精确表达"哪个字段是数字、哪个是字符串"，
/// 从而让 App 写进去的 EXIF 与 Web（ExifReader）写进去的形状一致。
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // ⚠️ 顺序重要：Bool 必须在 Int 之前试（JSON 的 true/false 不能当成数字），
        // 而 Int 要在 Double 之前（否则 640 会先被解成 640.0，编码回去就变成带小数点的形式）。
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法识别的 JSON 值")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// 供显示/拼接用：数字不留多余的 `.0`
    public var stringValue: String? {
        switch self {
        case let .string(value): return value
        case let .int(value): return String(value)
        case let .double(value): return JSONValue.trim(value)
        case let .bool(value): return String(value)
        case .null, .array, .object: return nil
        }
    }

    /// 去掉无意义的小数尾巴：`5.96` 保持 `5.96`，`640.0` 变成 `640`。
    /// 与服务端/web 看到的字符串形态对齐（例如 `focal_length` 存的是 `"5.96 mm"`）。
    static func trim(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%g", value)
    }
}

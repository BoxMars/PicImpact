import Foundation

/// 宽松字符串解码。
///
/// **为什么需要它**：服务端的 `exif` 是原样透传的 JSON，字段类型并不统一。
/// 生产实测：`iso_speed_rating` 是**数字**（`640`），而 `bits` / `f_number` 等是字符串；
/// 将来还可能冒出布尔或 null。如果按 `String?` 直接解，整页会在解码阶段失败 ——
/// 而这完全不该让图片看不了。
///
/// 策略：能解成什么就转成什么，**遇到任何不认识的类型一律返回 nil 而不是抛错**。
/// 这与 API 契约里「客户端必须忽略未知字段」是同一套前向兼容思路。
public struct LenientString: Decodable, Sendable, Equatable {
    public let value: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let string = try? container.decode(String.self) {
            // 空串按 nil 处理：生产里 lon/lat 会用 "" 表示缺失
            value = string.isEmpty ? nil : string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            // 640.0 这类要显示成 "640" 而不是 "640.0"
            value = double == double.rounded() ? String(Int(double)) : String(double)
        } else if let bool = try? container.decode(Bool.self) {
            value = String(bool)
        } else {
            value = nil
        }
    }
}

/// 统一的 JSON 解码器配置。
///
/// `createdAt` 形如 `2026-10-03T11:36:14.539Z`（**带毫秒**），
/// 而 `JSONDecoder.DateDecodingStrategy.iso8601` 不接受小数秒 —— 必须自定义，否则整页解不开。
public enum APIDecoding {
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parseISO8601(raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析时间：\(raw)"
            )
        }
        return decoder
    }

    /// 解析 ISO 8601。
    ///
    /// 每次新建 formatter 而不是共享静态实例：`ISO8601DateFormatter` / `DateFormatter`
    /// 都不是 `Sendable`，在 Swift 6 严格并发下作为全局共享可变状态会直接编译失败。
    /// 这里的调用频率是「每张图一次」，重建的开销可以忽略，换来的是彻底没有共享状态。
    public static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// 服务端统一响应信封：`{ code, message, data }`
public struct ApiEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    public let code: Int
    public let message: String
    public let data: Payload
}

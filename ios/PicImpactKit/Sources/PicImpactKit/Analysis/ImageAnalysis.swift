import Foundation

/// RGBA8 像素缓冲（每像素 4 字节，顺序 R,G,B,A）。
///
/// 之所以自己定义一个简单缓冲而不是直接依赖平台图片类型：
/// 分析算法是纯函数，这样就能用**手算得出的期望值**去测试它，
/// 不必在测试里造真实图片。
public struct RGBABuffer: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public var pixelCount: Int { width * height }

    /// 生成单色缓冲（测试用）
    public static func solid(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> RGBABuffer {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            bytes.append(contentsOf: [r, g, b, a])
        }
        return RGBABuffer(width: width, height: height, bytes: bytes)
    }

    /// 生成黑白棋盘（测试用）。用于构造确定的标准差。
    public static func checkerboard(width: Int, height: Int, dark: UInt8 = 0, light: UInt8 = 255) -> RGBABuffer {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = (x + y) % 2 == 0 ? dark : light
                bytes.append(contentsOf: [value, value, value, 255])
            }
        }
        return RGBABuffer(width: width, height: height, bytes: bytes)
    }
}

/// 影调分析结果
public struct ToneAnalysis: Equatable, Sendable {
    public enum ToneType: String, Sendable {
        case lowKey = "low-key"
        case highKey = "high-key"
        case normal
        case highContrast = "high-contrast"
    }

    public let toneType: ToneType
    /// 平均亮度 0–100
    public let brightness: Int
    /// 对比度 0–100
    public let contrast: Int
    /// 暗部（亮度 < 64）像素占比
    public let shadowRatio: Double
    /// 亮部（亮度 > 192）像素占比
    public let highlightRatio: Double

    /// 空数据时的默认值（与 Web 端 `analyzeTone` 的无像素分支一致）
    public static let empty = ToneAnalysis(
        toneType: .normal, brightness: 50, contrast: 50, shadowRatio: 0.33, highlightRatio: 0.33
    )
}

/// 直方图（**128 箱**）。
///
/// 注意：Web 端内部先统计 256 箱，输出前两两合并成 128 箱
/// （`compressed[floor(i/2)] += channel[i]`）。这里直接照此实现 ——
/// 若按 256 箱渲染，形状与 Web 会有可辨差异。
public struct Histogram: Equatable, Sendable {
    public static let binCount = 128
    public let red: [Int]
    public let green: [Int]
    public let blue: [Int]
    public let luminance: [Int]

    public var maxValue: Int {
        max(
            red.max() ?? 0,
            green.max() ?? 0,
            blue.max() ?? 0,
            luminance.max() ?? 0
        )
    }
}

/// 影调与直方图分析。
///
/// **所有阈值与公式都逐条照抄 Web 端**（`tone-analysis.tsx` / `histogram-chart.tsx`）——
/// 抄错任何一处，同一张图在两端会得出不同的影调结论。
public enum ImageAnalysis {

    /// 采样尺寸（与 Web 一致：影调最大 200，直方图最大 300）
    public static func sampledSize(width: Int, height: Int, maxSize: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let scale = min(Double(maxSize) / Double(width), Double(maxSize) / Double(height))
        return (Int(Double(width) * scale), Int(Double(height) * scale))
    }

    public static let toneSampleMaxSize = 200
    public static let histogramSampleMaxSize = 300

    /// 亮度公式（Rec.709 系数），**每像素先四舍五入到整数** —— 与 Web 的 `Math.round` 一致，
    /// 后续的均值与方差都基于这个整数值，不做这一步结果会有细微差异。
    @inline(__always)
    static func luminance(r: UInt8, g: UInt8, b: UInt8) -> Int {
        let value = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        return Int(value.rounded())
    }

    /// 影调分析
    public static func analyzeTone(_ buffer: RGBABuffer) -> ToneAnalysis {
        let total = buffer.pixelCount
        guard total > 0, buffer.bytes.count >= total * 4 else { return .empty }

        var luminances = [Int]()
        luminances.reserveCapacity(total)
        var sum = 0
        for offset in stride(from: 0, to: total * 4, by: 4) {
            let value = luminance(
                r: buffer.bytes[offset],
                g: buffer.bytes[offset + 1],
                b: buffer.bytes[offset + 2]
            )
            luminances.append(value)
            sum += value
        }

        let average = Double(sum) / Double(total)
        let brightness = Int(((average / 255) * 100).rounded())

        let variance = luminances.reduce(0.0) { partial, value in
            let delta = Double(value) - average
            return partial + delta * delta
        } / Double(total)
        let standardDeviation = variance.squareRoot()
        let contrast = min(100, Int(((standardDeviation / 128) * 100).rounded()))

        // 暗部/亮部阈值
        let shadowThreshold = 64
        let highlightThreshold = 192
        var shadowCount = 0
        var highlightCount = 0
        for value in luminances {
            if value < shadowThreshold {
                shadowCount += 1
            } else if value > highlightThreshold {
                highlightCount += 1
            }
        }
        let shadowRatio = Double(shadowCount) / Double(total)
        let highlightRatio = Double(highlightCount) / Double(total)

        // 判定顺序不能改：先看对比度，再看低照度，再看高照度
        let toneType: ToneAnalysis.ToneType
        if contrast > 60 {
            toneType = .highContrast
        } else if brightness < 35 && shadowRatio > 0.4 {
            toneType = .lowKey
        } else if brightness > 65 && highlightRatio > 0.4 {
            toneType = .highKey
        } else {
            toneType = .normal
        }

        return ToneAnalysis(
            toneType: toneType,
            brightness: brightness,
            contrast: contrast,
            shadowRatio: shadowRatio,
            highlightRatio: highlightRatio
        )
    }

    /// 直方图（4 通道各 128 箱）
    public static func histogram(_ buffer: RGBABuffer) -> Histogram {
        let total = buffer.pixelCount
        guard total > 0, buffer.bytes.count >= total * 4 else {
            let zeros = [Int](repeating: 0, count: Histogram.binCount)
            return Histogram(red: zeros, green: zeros, blue: zeros, luminance: zeros)
        }

        var redRaw = [Int](repeating: 0, count: 256)
        var greenRaw = [Int](repeating: 0, count: 256)
        var blueRaw = [Int](repeating: 0, count: 256)
        var luminanceRaw = [Int](repeating: 0, count: 256)

        for offset in stride(from: 0, to: total * 4, by: 4) {
            let r = Int(buffer.bytes[offset])
            let g = Int(buffer.bytes[offset + 1])
            let b = Int(buffer.bytes[offset + 2])
            redRaw[r] += 1
            greenRaw[g] += 1
            blueRaw[b] += 1
            luminanceRaw[luminance(r: buffer.bytes[offset], g: buffer.bytes[offset + 1], b: buffer.bytes[offset + 2])] += 1
        }

        // 256 → 128：两两合并（与 Web 的 compress 一致）
        func compress(_ channel: [Int]) -> [Int] {
            var compressed = [Int](repeating: 0, count: Histogram.binCount)
            for index in 0..<256 {
                compressed[index / 2] += channel[index]
            }
            return compressed
        }

        return Histogram(
            red: compress(redRaw),
            green: compress(greenRaw),
            blue: compress(blueRaw),
            luminance: compress(luminanceRaw)
        )
    }
}

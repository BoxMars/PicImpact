import Foundation
import Testing

@testable import PicImpactKit

/// T11 验证：影调与直方图算法**与 Web 端逐值一致**。
///
/// 基准 `Fixtures/analysis-golden.json` 由 `scripts/ios-analysis-fixture.mjs` 生成，
/// 那份脚本把 Web 端 `tone-analysis.tsx` / `histogram-chart.tsx` 的算法原样抄了一遍。
/// 所以这条测试回答的是：「移植有没有抄错阈值或公式」，
/// 而不是「Swift 自己算得对不对」——后者无法发现抄错。
@Suite("T11 · 影调与直方图（对齐 Web 端算法）")
struct ImageAnalysisTests {

    struct GoldenTone: Decodable {
        let toneType: String
        let brightness: Int
        let contrast: Int
        let shadowRatio: Double
        let highlightRatio: Double
    }

    struct GoldenHistogram: Decodable {
        let red: [Int]
        let green: [Int]
        let blue: [Int]
        let luminance: [Int]
    }

    struct GoldenCase: Decodable {
        let width: Int
        let height: Int
        let tone: GoldenTone
        let histogram: GoldenHistogram
    }

    struct Golden: Decodable {
        let cases: [String: GoldenCase]
    }

    static let golden: Golden? = {
        guard let url = Bundle.module.url(
            forResource: "analysis-golden",
            withExtension: "json",
            subdirectory: "Fixtures"
        ),
        let data = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(Golden.self, from: data)
        else {
            Issue.record("找不到 analysis-golden.json —— 无法证明与 Web 算法一致")
            return nil
        }
        return decoded
    }()

    // MARK: - 用与 Node 脚本相同的规则重建图案

    enum Pattern: String, CaseIterable {
        case solidMidGray = "solid-mid-gray"
        case solidBlack = "solid-black"
        case solidWhite = "solid-white"
        case solidRed = "solid-red"
        case checkerboard
        case gradientRamp = "gradient-ramp"
        case lcgNoise = "lcg-noise"

        func make(width: Int, height: Int) -> RGBABuffer {
            var bytes = [UInt8]()
            bytes.reserveCapacity(width * height * 4)

            switch self {
            case .solidMidGray:
                for _ in 0..<(width * height) { bytes.append(contentsOf: [128, 128, 128, 255]) }
            case .solidBlack:
                for _ in 0..<(width * height) { bytes.append(contentsOf: [0, 0, 0, 255]) }
            case .solidWhite:
                for _ in 0..<(width * height) { bytes.append(contentsOf: [255, 255, 255, 255]) }
            case .solidRed:
                for _ in 0..<(width * height) { bytes.append(contentsOf: [255, 0, 0, 255]) }
            case .checkerboard:
                for y in 0..<height {
                    for x in 0..<width {
                        let value: UInt8 = (x + y) % 2 == 0 ? 0 : 255
                        bytes.append(contentsOf: [value, value, value, 255])
                    }
                }
            case .gradientRamp:
                for _ in 0..<height {
                    for x in 0..<width {
                        let raw = (Double(x) / Double(width - 1)) * 255
                        let value = UInt8(raw.rounded())
                        bytes.append(contentsOf: [value, value, value, 255])
                    }
                }
            case .lcgNoise:
                // 必须与 JS 的 `Math.imul(seed, 1664525) + 1013904223 >>> 0` 等价：
                // UInt32 的溢出即模 2^32，&* / &+ 保留该语义
                var seed: UInt32 = 12345
                func next() -> UInt8 {
                    seed = seed &* 1664525 &+ 1013904223
                    return UInt8(seed & 0xFF)
                }
                for _ in 0..<(width * height) {
                    bytes.append(contentsOf: [next(), next(), next(), 255])
                }
            }
            return RGBABuffer(width: width, height: height, bytes: bytes)
        }
    }

    // MARK: - 断言

    @Test("基准文件包含全部图案")
    func goldenIsComplete() throws {
        let golden = try #require(Self.golden)
        for pattern in Pattern.allCases {
            #expect(golden.cases[pattern.rawValue] != nil, "基准缺少图案 \(pattern.rawValue)")
        }
    }

    @Test("影调结论与 Web 端逐字段一致（含取整）")
    func toneMatchesGolden() throws {
        let golden = try #require(Self.golden)
        for pattern in Pattern.allCases {
            let expected = try #require(golden.cases[pattern.rawValue])
            let buffer = pattern.make(width: expected.width, height: expected.height)
            let actual = ImageAnalysis.analyzeTone(buffer)

            #expect(
                actual.toneType.rawValue == expected.tone.toneType,
                "\(pattern.rawValue)：影调类型应为 \(expected.tone.toneType)，实际 \(actual.toneType.rawValue)"
            )
            #expect(
                actual.brightness == expected.tone.brightness,
                "\(pattern.rawValue)：亮度应为 \(expected.tone.brightness)，实际 \(actual.brightness)"
            )
            #expect(
                actual.contrast == expected.tone.contrast,
                "\(pattern.rawValue)：对比度应为 \(expected.tone.contrast)，实际 \(actual.contrast)"
            )
            // 占比是浮点，给极小容差
            #expect(
                abs(actual.shadowRatio - expected.tone.shadowRatio) < 1e-9,
                "\(pattern.rawValue)：暗部占比不一致"
            )
            #expect(
                abs(actual.highlightRatio - expected.tone.highlightRatio) < 1e-9,
                "\(pattern.rawValue)：亮部占比不一致"
            )
        }
    }

    @Test("直方图逐箱一致（4 通道 × 128 箱）")
    func histogramMatchesGolden() throws {
        let golden = try #require(Self.golden)
        for pattern in Pattern.allCases {
            let expected = try #require(golden.cases[pattern.rawValue])
            let buffer = pattern.make(width: expected.width, height: expected.height)
            let actual = ImageAnalysis.histogram(buffer)

            #expect(actual.red.count == Histogram.binCount)
            #expect(actual.red == expected.histogram.red, "\(pattern.rawValue)：红通道直方图不一致")
            #expect(actual.green == expected.histogram.green, "\(pattern.rawValue)：绿通道直方图不一致")
            #expect(actual.blue == expected.histogram.blue, "\(pattern.rawValue)：蓝通道直方图不一致")
            #expect(actual.luminance == expected.histogram.luminance, "\(pattern.rawValue)：亮度直方图不一致")
        }
    }

    // MARK: - 手算断言（不依赖基准，用来独立交叉验证基准本身）

    @Test("手算：50% 灰 → 亮度 50、对比度 0、normal")
    func handComputedMidGray() {
        let result = ImageAnalysis.analyzeTone(.solid(width: 8, height: 8, r: 128, g: 128, b: 128))
        #expect(result.brightness == 50)
        #expect(result.contrast == 0)
        #expect(result.toneType == .normal)
        #expect(result.shadowRatio == 0)
    }

    @Test("手算：纯黑 → low-key；纯白 → high-key")
    func handComputedExtremes() {
        let black = ImageAnalysis.analyzeTone(.solid(width: 8, height: 8, r: 0, g: 0, b: 0))
        #expect(black.brightness == 0)
        #expect(black.shadowRatio == 1)
        #expect(black.toneType == .lowKey)

        let white = ImageAnalysis.analyzeTone(.solid(width: 8, height: 8, r: 255, g: 255, b: 255))
        #expect(white.brightness == 100)
        #expect(white.highlightRatio == 1)
        #expect(white.toneType == .highKey)
    }

    @Test("手算：黑白棋盘 → 对比度 100 → high-contrast（判定优先级最高）")
    func handComputedCheckerboard() {
        let result = ImageAnalysis.analyzeTone(.checkerboard(width: 8, height: 8))
        // 平均 127.5 → 亮度 50；标准差 127.5 → 对比度 100
        #expect(result.brightness == 50)
        #expect(result.contrast == 100)
        #expect(result.toneType == .highContrast)
    }

    @Test("手算：纯红 → 亮度 21、落入 low-key（Rec.709 系数下红的亮度很低）")
    func handComputedRed() {
        let result = ImageAnalysis.analyzeTone(.solid(width: 8, height: 8, r: 255, g: 0, b: 0))
        // round(0.2126 * 255) = round(54.2) = 54 → brightness = round(54/255*100) = 21
        #expect(result.brightness == 21)
        #expect(result.toneType == .lowKey, "红像素亮度 54 < 64，应算作暗部")
    }

    @Test("空缓冲返回 Web 端的默认值，而不是崩溃或 NaN")
    func emptyBufferDefaults() {
        let result = ImageAnalysis.analyzeTone(RGBABuffer(width: 0, height: 0, bytes: []))
        #expect(result.toneType == .normal)
        #expect(result.brightness == 50)
        #expect(result.contrast == 50)
        #expect(result.shadowRatio == 0.33)

        let histogram = ImageAnalysis.histogram(RGBABuffer(width: 0, height: 0, bytes: []))
        #expect(histogram.red.count == Histogram.binCount)
        #expect(histogram.maxValue == 0)
    }

    @Test("采样尺寸与 Web 公式一致（影调 200、直方图 300，且用 floor）")
    func sampledSizeMatchesWeb() {
        // 影调：4000×3000 → 200×150
        let tone = ImageAnalysis.sampledSize(width: 4000, height: 3000, maxSize: ImageAnalysis.toneSampleMaxSize)
        #expect(tone.width == 200)
        #expect(tone.height == 150)

        // 直方图：4000×3000 → 300×225
        let histogram = ImageAnalysis.sampledSize(width: 4000, height: 3000, maxSize: ImageAnalysis.histogramSampleMaxSize)
        #expect(histogram.width == 300)
        #expect(histogram.height == 225)

        // 竖图
        let portrait = ImageAnalysis.sampledSize(width: 3000, height: 4000, maxSize: 200)
        #expect(portrait.width == 150)
        #expect(portrait.height == 200)
    }
}

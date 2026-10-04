import Foundation
import SwiftUI
import Testing

@testable import PicImpactKit

/// T2 验证：**48 条令牌与 animal-island-ui 编译产物逐值对照**。
///
/// 基准文件 `Fixtures/animal-tokens.json` 不是手写的 —— 它由
/// `node_modules/animal-island-ui/dist/index.css` 里的 `--animal-*` 声明直接生成。
/// 所以这条测试真正在回答的问题是：「Swift 侧的令牌有没有和 ACNH 源库跑偏？」
@Suite("T2 · ACNH 设计令牌")
struct AnimalTokensTests {

    /// 从编译产物生成的基准
    static let baseline: [String: String] = {
        guard let url = Bundle.module.url(forResource: "animal-tokens", withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            Issue.record("找不到基准文件 animal-tokens.json —— 测试无法证明令牌与源库一致")
            return [:]
        }
        return json
    }()

    @Test("基准文件存在且为 48 条")
    func baselineLoaded() {
        #expect(Self.baseline.count == 48, "基准应有 48 条令牌，实际 \(Self.baseline.count)")
    }

    @Test("令牌键集合与编译产物完全一致（不多不少）")
    func keySetsMatch() {
        let expected = Set(Self.baseline.keys)
        let actual = Set(AnimalTokens.rawCSS.keys)
        #expect(actual.subtracting(expected).isEmpty, "Swift 侧多出的键：\(actual.subtracting(expected).sorted())")
        #expect(expected.subtracting(actual).isEmpty, "Swift 侧缺少的键：\(expected.subtracting(actual).sorted())")
    }

    @Test("每条令牌的值与编译产物逐字相同")
    func valuesMatchExactly() {
        for (key, expected) in Self.baseline.sorted(by: { $0.key < $1.key }) {
            let actual = AnimalTokens.raw(key)
            #expect(actual == expected, "令牌 \(key) 不一致：期望「\(expected)」，实际「\(actual ?? "nil")」")
        }
    }

    @Test("每个颜色 / 长度 / 时长令牌都能被解析出来")
    func allTokensParse() {
        for key in Self.baseline.keys {
            let value = Self.baseline[key] ?? ""
            if value.hasPrefix("#") || value.hasPrefix("rgb") {
                #expect(AnimalTokens.parseColor(key) != nil, "颜色令牌 \(key)=\(value) 解析失败")
            }
            if value.hasSuffix("px") {
                #expect(AnimalTokens.parseLength(key) != nil, "长度令牌 \(key)=\(value) 解析失败")
            }
            if value.hasSuffix("s") && !value.contains("cubic") && !value.contains("sans") {
                #expect(AnimalTokens.parseSeconds(key) != nil, "时长令牌 \(key)=\(value) 解析失败")
            }
        }
    }

    /// 语义关键项的字面断言。防的是"解析器把颜色解析错了"这类静默错误。
    @Test("关键令牌的值符合 ACNH 定义")
    func keyValuesAreCorrect() {
        // 主文字是深棕而非黑 —— 这条最容易被做成"黑色"而看不出问题
        #expect(AnimalTokens.raw("animal-text-color") == "#794f27")
        // 页面背景是暖白纸
        #expect(AnimalTokens.raw("animal-bg-color") == "#f8f8f0")
        #expect(AnimalTokens.raw("animal-primary-color") == "#19c8b9")
        #expect(AnimalTokens.raw("animal-text-color-secondary") == "#9f927d")
        #expect(AnimalTokens.raw("animal-border-color") == "#aaa69d")

        // 几何
        #expect(AnimalTokens.radius == 18)
        #expect(AnimalTokens.radiusSM == 16)
        #expect(AnimalTokens.radiusLG == 24)
        #expect(AnimalTokens.borderWidth == 2)
        #expect(AnimalTokens.fontSM == 12)
        #expect(AnimalTokens.fontSize == 14)
        #expect(AnimalTokens.fontLG == 16)
        #expect(AnimalTokens.spacingLG == 16)

        // 动效
        #expect(AnimalTokens.motionBase == 0.25)
        #expect(AnimalTokens.motionFast == 0.15)
        #expect(AnimalTokens.motionSlow == 0.35)
    }

    @Test("颜色解析能正确处理 #rrggbb 与带省略前导 0 的 rgba")
    func colorParsingHandlesCSSForms() {
        // 掩码色在 CSS 里写作 rgba(0, 0, 0, .35) —— alpha 没有前导 0，朴素解析会失败
        #expect(AnimalTokens.parseColor("animal-mask-bg") != nil)
        #expect(AnimalTokens.mask != Color.clear)
    }

    @Test("视觉签名值符合 ACNH 与项目实现")
    func signaturesAreCorrect() {
        // 岛屿卡的纸面色 == CardColor.default 的 rgb(247,243,223)
        #expect(AnimalSignatures.cardPaper == Color(red: 247 / 255, green: 243 / 255, blue: 223 / 255))
        #expect(AnimalSignatures.cardBorder == Color(red: 0xC4 / 255, green: 0xB8 / 255, blue: 0x9E / 255))
        #expect(AnimalSignatures.cardShadowHard == Color(red: 0xBD / 255, green: 0xAE / 255, blue: 0xA0 / 255))
        #expect(AnimalSignatures.cardCornerRadius == 18)
        #expect(AnimalSignatures.cardBorderWidth == 2)
        // 硬阴影的 3px 偏移是"贴纸厚度"的全部来源；radius 必须为 0（由构建器保证）
        #expect(AnimalSignatures.cardShadowOffsetY == 3)
    }
}

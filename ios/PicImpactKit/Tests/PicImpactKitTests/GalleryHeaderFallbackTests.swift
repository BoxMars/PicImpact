import Testing

@testable import PicImpactKit
/// 首页标题兜底值的"绊线"。
///
/// 首页标题取自站点配置，配置到达前用兜底值。两者长度不同会让 `ViewThatFits`
/// 在配置到达前后选到**不同字号** —— 用户看到的"主页标题会变化"就是这么来的
/// （曾经兜底写成短名 "Felina Gallery"，而生产配置是完整标题）。
/// 这条测试锁住那个字符串，改动它必须是有意识的。
@Suite("首页标题兜底值")
struct GalleryHeaderFallbackTests {
    @Test("兜底标题与生产配置一致（Web 的兜底也是完整标题）")
    func fallbackTitleMatchesProduction() {
        #expect(GalleryHeader.defaultTitle == "大福映画 Felina Gallery")
        #expect(!GalleryHeader.defaultTitle.isEmpty)
    }
}

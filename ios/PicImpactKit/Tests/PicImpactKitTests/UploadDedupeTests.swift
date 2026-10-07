import Foundation
import Testing

@testable import PicImpactKit

/// 判重规则：**拍摄时间 ±2 分钟**（用户明确要求：同一时间会拍好多照）。
///
/// 这里的边界值必须钉死 —— 规则宽松一点就会误判连拍，严格一点就漏判重复，
/// 两种错都会让用户多花流量或者丢照片。
@Suite("判重 · ±2 分钟规则")
struct DuplicateMatcherTests {

    private func fingerprint(
        digest: String = "hash-a",
        capturedAt: String? = "2026:10:07 16:26:04",
        width: Int = 4032,
        height: Int = 3024,
        model: String = "iPhone 17"
    ) -> UploadFingerprint {
        UploadFingerprint(
            digest: digest,
            capturedAt: EXIFDateParser.date(from: capturedAt),
            width: width,
            height: height,
            model: model
        )
    }

    private func known(_ fingerprint: UploadFingerprint, id: String = "clx1", title: String = "生日") -> [(fingerprint: UploadFingerprint, id: String, title: String)] {
        [(fingerprint, id, title)]
    }

    @Test("字节相同：直接判为重复（与拍摄时间无关）")
    func identicalBytesWins() {
        let candidate = fingerprint(digest: "same", capturedAt: nil)
        let match = DuplicateMatcher.match(candidate, in: known(fingerprint(digest: "same", capturedAt: nil)))
        #expect(match?.reason == .identicalBytes)
        #expect(match?.message.contains("完全相同") == true)
    }

    @Test("拍摄时间相差 119 秒 → 判为已上传（容差内）")
    func withinTolerance() {
        let candidate = fingerprint(digest: "b", capturedAt: "2026:10:07 16:27:00")
        let knownOne = fingerprint(digest: "a", capturedAt: "2026:10:07 16:25:01")
        let match = DuplicateMatcher.match(candidate, in: known(knownOne))
        #expect(match?.reason == .nearbyCapture(secondsApart: 119))
    }

    @Test("拍摄时间相差 121 秒 → 不判重（容差外）")
    func outsideTolerance() {
        let candidate = fingerprint(digest: "b", capturedAt: "2026:10:07 16:27:02")
        let knownOne = fingerprint(digest: "a", capturedAt: "2026:10:07 16:25:01")
        #expect(DuplicateMatcher.match(candidate, in: known(knownOne)) == nil)
    }

    @Test("相差 120 秒整 → 判为已上传（闭区间，含端点）")
    func exactlyOnTolerance() {
        let candidate = fingerprint(digest: "b", capturedAt: "2026:10:07 16:27:01")
        let knownOne = fingerprint(digest: "a", capturedAt: "2026:10:07 16:25:01")
        #expect(DuplicateMatcher.match(candidate, in: known(knownOne))?.reason == .nearbyCapture(secondsApart: 120))
    }

    @Test("尺寸或机型不同 → 不判重（哪怕同一秒拍的）")
    func dimensionsAndModelMustMatch() {
        let candidate = fingerprint(digest: "b")
        #expect(DuplicateMatcher.match(candidate, in: known(fingerprint(digest: "a", width: 3000, height: 2002))) == nil)
        #expect(DuplicateMatcher.match(candidate, in: known(fingerprint(digest: "a", model: "iPhone 15"))) == nil)
    }

    @Test("机型大小写不敏感")
    func modelIsCaseInsensitive() {
        let candidate = fingerprint(digest: "b", model: "iphone 17")
        #expect(DuplicateMatcher.match(candidate, in: known(fingerprint(digest: "a", model: "iPhone 17")))?.reason != nil)
    }

    @Test("没有拍摄时间（截图/微信导出图）→ 只有字节相同才判重，宁可不判")
    func withoutCaptureTimeOnlyBytesMatch() {
        let candidate = fingerprint(digest: "b", capturedAt: nil)
        #expect(DuplicateMatcher.match(candidate, in: known(fingerprint(digest: "a"))) == nil)
        // 服务端列表来的指纹没有字节（digest 为空），也不该被误判成"完全相同"
        let serverOnly = UploadFingerprint(digest: "", capturedAt: nil, width: 4032, height: 3024, model: "iPhone 17")
        #expect(DuplicateMatcher.match(candidate, in: known(serverOnly)) == nil)
    }

    @Test("提示文案说清是跟哪一张撞的、差了多少秒")
    func messageNamesTheOtherPhoto() {
        let candidate = fingerprint(digest: "b", capturedAt: "2026:10:07 16:26:30")
        let match = DuplicateMatcher.match(candidate, in: known(fingerprint(digest: "a", capturedAt: "2026:10:07 16:26:04"), title: "不想量身高"))
        let message = match?.message ?? ""
        #expect(message.contains("不想量身高"))
        #expect(message.contains("26 秒"))
    }

    @Test("EXIF 时间解析：标准形态能解，缺失/畸形返回 nil")
    func parsesEXIFDate() {
        #expect(EXIFDateParser.date(from: "2026:10:07 16:26:04") != nil)
        #expect(EXIFDateParser.date(from: "2026-10-07T16:26:04Z") == nil)
        #expect(EXIFDateParser.date(from: "") == nil)
        #expect(EXIFDateParser.date(from: nil) == nil)
        // 期望值本身也要对：解析出来的就是那一刻（UTC 约定，内部一致即可）
        let date = EXIFDateParser.date(from: "2026:10:07 16:26:04")
        #expect(date.map { Int($0.timeIntervalSince1970) } == 1791390364)  // = 2026-10-07 16:26:04 UTC
    }
}

/// 本地账本：落盘、去重、能读回来
@Suite("判重 · 本地账本")
struct UploadLedgerTests {

    private func makeLedger() -> UploadLedger {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString)")
        return UploadLedger(directory: directory)
    }

    @Test("记一笔之后能查到，重复记不会变两条")
    func recordsAndDeduplicates() async {
        let ledger = makeLedger()
        let fingerprint = UploadFingerprint(digest: "a", capturedAt: EXIFDateParser.date(from: "2026:10:07 16:26:04"), width: 4032, height: 3024, model: "iPhone 17")

        await ledger.record(fingerprint, imageID: "clx1", title: "生日")
        await ledger.record(fingerprint, imageID: "clx1", title: "生日")

        let known = await ledger.known()
        #expect(known.count == 1)
        #expect(known[0].id == "clx1")
        #expect(known[0].title == "生日")
        #expect(known[0].fingerprint == fingerprint)
    }

    @Test("写入后再开一个账本（模拟重启 App）还能读到")
    func survivesRestart() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString)")
        let fingerprint = UploadFingerprint(digest: "abc", capturedAt: nil, width: 100, height: 200, model: "iPhone 17")

        let first = UploadLedger(directory: directory)
        await first.record(fingerprint, imageID: "clx9", title: "t")

        let second = UploadLedger(directory: directory)
        let known = await second.known()
        #expect(known.count == 1)
        #expect(known[0].fingerprint.digest == "abc")
        #expect(known[0].fingerprint.width == 100)
        #expect(known[0].fingerprint.capturedAt == nil)
    }

    @Test("指纹编码往返（存储格式变了要能立刻发现）")
    func fingerprintEncodingRoundTrip() {
        let fingerprint = UploadFingerprint(digest: "d", capturedAt: Date(timeIntervalSince1970: 1_791_380_764), width: 4032, height: 3024, model: "iPhone 17")
        #expect(UploadFingerprint(encoded: fingerprint.encoded) == fingerprint)
        #expect(UploadFingerprint(encoded: "坏数据") == nil)
    }

    @Test("SHA-256：同字节同值、异字节异值")
    func digestIsStable() {
        let data = Data("hello".utf8)
        #expect(UploadFingerprint.digest(of: data) == UploadFingerprint.digest(of: Data("hello".utf8)))
        #expect(UploadFingerprint.digest(of: data) != UploadFingerprint.digest(of: Data("hello!".utf8)))
        #expect(UploadFingerprint.digest(of: data).count == 64)
    }
}

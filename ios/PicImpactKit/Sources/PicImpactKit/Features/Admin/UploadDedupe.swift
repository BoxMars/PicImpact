import CryptoKit
import Foundation

/// 一张照片的"指纹"：用来判断它是不是**已经上传过**。
///
/// ## 为什么不能只比字节
/// 选同一张照片拿到的是同一份字节，哈希能精确命中；但用户真正会遇到的重复是
/// "这张我刚才已经传过了"，而**跨设备/跨入口**（网页上传过、App 重装过）拿不到字节哈希。
/// 所以再补一层基于 EXIF 的指纹。
///
/// ## 为什么拍摄时间要留 ±2 分钟
/// 用户明确要求："因为我们会**在同一时间拍好多照**，可以同时比较拍摄时间 ±2min"。
/// 即：只要已上传的照片里有**拍摄时间相差不到 2 分钟**、且尺寸与机型都相同的一张，
/// 就认为这一张已经传过。
///
/// ⚠️ 这条规则**天然会误判连拍**：同一分钟内连拍的几张同尺寸照片本来就长得"指纹相同"，
/// 传过其中一张之后，其余几张也会被判定为已上传。所以：
/// 1. 命中的项**不是直接丢掉**，而是进入"已跳过"状态并写清"和哪一张撞了"；
/// 2. 界面上有"仍然上传"的入口，一键就能把被跳过的全部传上去。
/// 宁可默认少传（用户要的），也绝不默认多传或悄悄丢照片（不可接受）。
public struct UploadFingerprint: Sendable, Equatable {
    /// 原图字节的 SHA-256（同一个文件必然相同）
    public let digest: String
    /// EXIF 拍摄时间（`data_time`，精确到秒）
    public let capturedAt: Date?
    public let width: Int
    public let height: Int
    /// 机型（EXIF `model`），比较时大小写不敏感
    public let model: String

    public init(digest: String, capturedAt: Date?, width: Int, height: Int, model: String) {
        self.digest = digest
        self.capturedAt = capturedAt
        self.width = width
        self.height = height
        self.model = model
    }

    /// 指纹的稳定编码（存本地账本用；不参与网络）
    public var encoded: String {
        let time = capturedAt.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        return [digest, time, String(width), String(height), model].joined(separator: "|")
    }

    public init?(encoded: String) {
        let parts = encoded.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, !parts[0].isEmpty else { return nil }
        self.digest = parts[0]
        self.capturedAt = Int(parts[1]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        self.width = Int(parts[2]) ?? 0
        self.height = Int(parts[3]) ?? 0
        self.model = parts[4]
    }
}

/// EXIF 拍摄时间的解析：`2026:10:07 16:26:04`。
///
/// EXIF 不带时区，两边的比较也都来自同一个约定，所以固定按 UTC 解析 ——
/// 只用于"相差是否 ≤ 2 分钟"这种相对比较，绝对值没有意义。
public enum EXIFDateParser {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    public static func date(from string: String?) -> Date? {
        guard let string, string.count >= 19 else { return nil }
        return formatter.date(from: String(string.prefix(19)))
    }
}

public extension UploadFingerprint {
    /// 原图字节的 SHA-256（十六进制）。同一个文件必然得到同一个值。
    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 命中"已经传过"时的说明（要能告诉用户**和哪一张**撞了）
public struct DuplicateMatch: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// 字节完全一致（同一个文件）
        case identicalBytes
        /// 拍摄时间相差 ≤ 容差、且尺寸与机型相同
        case nearbyCapture(secondsApart: Int)
    }

    public let reason: Reason
    /// 撞上的那张已上传照片（列表里的标题或文件名，可能为空）
    public let existingTitle: String
    /// 撞上的那张的服务端 id（便于排查）
    public let existingID: String

    public var message: String {
        let name = existingTitle.isEmpty ? "已上传的另一张" : "「\(existingTitle)」"
        switch reason {
        case .identicalBytes:
            return "已经上传过这张（与\(name)完全相同）"
        case let .nearbyCapture(seconds):
            let apart = seconds <= 1 ? "几乎同一时刻" : "相差 \(seconds) 秒"
            return "拍摄时间与\(name)\(apart)，尺寸机型一致，已跳过"
        }
    }
}

/// 判定规则（纯函数，单测直接覆盖边界）。
public enum DuplicateMatcher {

    /// 拍摄时间容差：用户要求 ±2 分钟
    public static let captureTolerance: TimeInterval = 120

    /// - Parameters:
    ///   - candidate: 待上传的这张
    ///   - known: 已知"已上传"的指纹（本地账本 ∪ 服务端列表）
    ///   - titleFor: 把某个已知指纹映射回"它对应哪张照片"（用于提示文案）
    public static func match(
        _ candidate: UploadFingerprint,
        in known: [(fingerprint: UploadFingerprint, id: String, title: String)]
    ) -> DuplicateMatch? {
        // 1) 字节完全相同 —— 这是确定无疑的重复，优先报这个。
        //    服务端列表来的指纹没有字节（digest 为空），不能拿它去撞。
        if !candidate.digest.isEmpty,
           let hit = known.first(where: { !$0.fingerprint.digest.isEmpty && $0.fingerprint.digest == candidate.digest }) {
            return DuplicateMatch(
                reason: .identicalBytes,
                existingTitle: hit.title,
                existingID: hit.id
            )
        }

        // 2) 拍摄时间 ±2 分钟 + 尺寸一致 + 机型一致
        //    两边都必须有拍摄时间才比 —— 截图/微信导出的图根本没有 EXIF，宁可不判重
        guard let candidateTime = candidate.capturedAt else { return nil }
        for entry in known {
            guard let knownTime = entry.fingerprint.capturedAt else { continue }
            guard entry.fingerprint.width == candidate.width,
                  entry.fingerprint.height == candidate.height
            else { continue }
            guard entry.fingerprint.model.caseInsensitiveCompare(candidate.model) == .orderedSame
            else { continue }
            let delta = abs(knownTime.timeIntervalSince(candidateTime))
            guard delta <= captureTolerance else { continue }
            return DuplicateMatch(
                reason: .nearbyCapture(secondsApart: Int(delta.rounded())),
                existingTitle: entry.title,
                existingID: entry.id
            )
        }
        return nil
    }
}

/// "已上传过哪些照片"的本地账本。
///
/// 为什么本地也存一份：服务端列表接口只按页返回元数据，翻到底才能覆盖全部；
/// 而**这台设备传过的**照片是重复的主要来源，本地记一份最准也最快（离线也能判）。
/// 存在 Caches 目录：丢了最多是判重能力下降，不影响功能。
public actor UploadLedger {

    private struct Entry: Codable, Sendable {
        var fingerprint: String
        var imageID: String
        var title: String
    }

    private let fileURL: URL?
    private var entries: [Entry] = []
    private var loaded = false

    public init?(namespace: String = "PicImpactMetadata") {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        self.init(directory: base.appendingPathComponent(namespace, isDirectory: true))
    }

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("upload-ledger.json")
    }

    /// 已知指纹（含来自服务端列表的那些由调用方自己拼进去）
    public func known() -> [(fingerprint: UploadFingerprint, id: String, title: String)] {
        loadIfNeeded()
        return entries.compactMap { entry in
            guard let fingerprint = UploadFingerprint(encoded: entry.fingerprint) else { return nil }
            return (fingerprint, entry.imageID, entry.title)
        }
    }

    /// 上传成功后记一笔
    public func record(_ fingerprint: UploadFingerprint, imageID: String, title: String) {
        loadIfNeeded()
        guard !entries.contains(where: { $0.fingerprint == fingerprint.encoded }) else { return }
        entries.append(Entry(fingerprint: fingerprint.encoded, imageID: imageID, title: title))
        persist()
    }

    /// 清空（调试/换站点时用）
    public func clear() {
        entries = []
        loaded = true
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func persist() {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

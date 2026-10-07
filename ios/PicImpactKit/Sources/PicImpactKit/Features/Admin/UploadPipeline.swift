import Foundation
import Observation

/// 一张待上传的图（原图字节 + 元数据）。由界面从 `PhotosPickerItem` 装配出来。
///
/// 刻意不含 SwiftUI/PhotosUI 类型：这样上传状态机可以在 `swift test`（macOS）下直接测，
/// 不必起模拟器。
public struct UploadCandidate: Sendable, Equatable {
    public let filename: String
    public let contentType: String
    public let data: Data
    public let exif: [String: JSONValue]
    public let width: Int
    public let height: Int

    public init(
        filename: String,
        contentType: String,
        data: Data,
        exif: [String: JSONValue] = [:],
        width: Int = 0,
        height: Int = 0
    ) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
        self.exif = exif
        self.width = width
        self.height = height
    }

    public var byteCount: Int { data.count }
}

/// 上传队列里的一项，带**步骤级**状态。
public struct UploadItem: Identifiable, Sendable, Equatable {

    /// 失败/进行到哪一步。顺序与契约一致：签发 → 直传 → 登记。
    public enum Step: String, Sendable, Equatable, CaseIterable {
        case sign
        case upload
        case register

        public var label: String {
            switch self {
            case .sign: return "获取上传地址"
            case .upload: return "上传原图"
            case .register: return "登记信息"
            }
        }
    }

    public enum State: Sendable, Equatable {
        case queued
        case running(Step, fraction: Double)
        case done(imageID: String, url: String)
        case failed(Step, message: String)
        /// 判重命中"已经传过"，**没有**上传（原因见 UploadDedupe 的说明）。
        /// 与 `failed` 分开：这不是错误，界面上要给出"仍然上传"的出口。
        case skipped(reason: String)
    }

    public let id: UUID
    public let filename: String
    public let byteCount: Int
    public var state: State

    public init(id: UUID = UUID(), filename: String, byteCount: Int, state: State = .queued) {
        self.id = id
        self.filename = filename
        self.byteCount = byteCount
        self.state = state
    }

    public var isQueued: Bool { state == .queued }
    public var isFailed: Bool { if case .failed = state { return true }; return false }
    public var isDone: Bool { if case .done = state { return true }; return false }
    public var isSkipped: Bool { if case .skipped = state { return true }; return false }

    /// 被跳过（判定为已上传）的原因
    public var skipReason: String? {
        if case let .skipped(reason) = state { return reason }
        return nil
    }

    /// 失败发生在哪一步（界面要能一眼说清"哪一张、失败在哪一步"）
    public var failedStep: Step? {
        if case let .failed(step, _) = state { return step }
        return nil
    }

    public var failureMessage: String? {
        if case let .failed(_, message) = state { return message }
        return nil
    }

    /// 进行到哪一步（用于界面上显示步骤文字）
    public var runningStep: Step? {
        if case let .running(step, _) = state { return step }
        return nil
    }

    /// 直传阶段的字节进度（其他阶段为 nil —— 那是"不确定进度"）
    public var uploadFraction: Double? {
        if case let .running(step, fraction) = state, step == .upload { return fraction }
        return nil
    }

    public var byteDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(byteCount))
    }
}

/// 把一个文件 PUT 到预签名 URL。
///
/// 抽成协议的理由有两个：一是上传状态机的测试不该真的上网；二是进度回调需要一个
/// `URLSessionTaskDelegate`，把它隔离在这一处，状态机那边只看到一个 `Double`。
public protocol FileUploading: Sendable {
    func upload(
        _ data: Data,
        to url: URL,
        contentType: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
}

/// 真实现：`URLSession.upload(for:from:delegate:)` + 逐块回调 `didSendBodyData`。
public struct URLSessionFileUploader: FileUploading {

    private let session: URLSession

    public init(session: URLSession = URLSessionFileUploader.makeSession()) {
        self.session = session
    }

    /// 直传用的会话：不打 Cookie（预签名 URL 自带授权，带上 Cookie 反而可能触发别的规则）
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    public func upload(
        _ data: Data,
        to url: URL,
        contentType: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: request, from: data, delegate: delegate)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("响应不是 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, code: nil, message: nil)
        }
    }
}

/// 进度代理。URLSession 的回调发生在自己的队列上，所以这里是 `@unchecked Sendable` +
/// 一把锁：只保留"百分比变了才回调一次"，避免上万个回调把主线程淹掉。
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var lastPercent = -1

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        let percent = Int(fraction * 100)
        lock.lock()
        let changed = percent != lastPercent
        lastPercent = percent
        lock.unlock()
        if changed { onProgress(fraction) }
    }
}

/// 上传状态机：把"选中的若干张原图"逐张走完 签发 → 直传 → 登记，并保留每一步的失败原因。
///
/// ## 为什么逐张串行
/// 批量并发上传会把带宽与内存同时拉满（单张原图就可到十几 MB），而且失败时更难说清是哪一张。
/// 串行 + 每张独立状态，换来的是"失败能归因、能单独重试"。
@Observable
@MainActor
public final class UploadCoordinator {

    public private(set) var items: [UploadItem] = []
    public private(set) var isRunning = false
    /// 目标相册（形如 `/daily`）。为空时不能开始上传（服务端也会拒）。
    public var albumValue: String = ""

    private let api: any AdminImageAPI
    private let uploader: any FileUploading
    private let cookie: @MainActor () -> String?
    /// 这台设备传过哪些照片（本地账本，判重的主要依据）
    private let ledger: UploadLedger?
    /// 服务端已经有的照片指纹（管理列表那一条条元数据），判重时与账本合并
    private let serverFingerprints: @MainActor () -> [(fingerprint: UploadFingerprint, id: String, title: String)]
    /// 失败重试要用到原图字节，所以候选要留到成功或用户手动清掉为止
    private var candidates: [UUID: UploadCandidate] = [:]

    public init(
        api: any AdminImageAPI,
        uploader: any FileUploading = URLSessionFileUploader(),
        cookie: @escaping @MainActor () -> String?,
        ledger: UploadLedger? = nil,
        serverFingerprints: @escaping @MainActor () -> [(fingerprint: UploadFingerprint, id: String, title: String)] = { [] }
    ) {
        self.api = api
        self.uploader = uploader
        self.cookie = cookie
        self.ledger = ledger
        self.serverFingerprints = serverFingerprints
    }

    // MARK: - 队列

    /// 入队。只有在**没有上传在跑**时才允许，避免用户连点导致同一批被跑两遍。
    @discardableResult
    public func enqueue(_ newCandidates: [UploadCandidate]) -> [UUID] {
        var ids: [UUID] = []
        for candidate in newCandidates {
            let item = UploadItem(filename: candidate.filename, byteCount: candidate.byteCount)
            candidates[item.id] = candidate
            items.append(item)
            ids.append(item.id)
        }
        return ids
    }

    public func removeFinished() {
        items.removeAll { item in
            if item.isDone {
                candidates[item.id] = nil
                return true
            }
            return false
        }
    }

    public func clearAll() {
        guard !isRunning else { return }
        items.removeAll()
        candidates.removeAll()
    }

    public var pendingCount: Int { items.filter { !$0.isDone }.count }
    public var failedCount: Int { items.filter(\.isFailed).count }
    public var doneCount: Int { items.filter(\.isDone).count }
    /// 判定为"已经传过"而没上传的张数
    public var skippedCount: Int { items.filter(\.isSkipped).count }

    /// 是否还有"没跑完"的项（含等待与失败），供界面决定是否显示"重试失败项"
    public var hasRetryable: Bool { items.contains { $0.isQueued || $0.isFailed } }

    // MARK: - 执行

    /// 串行跑完所有"排队中"的项。失败**不中断**后续项（一张失败不该拖住整批）。
    public func runPending() async {
        guard !isRunning else { return }
        guard !albumValue.isEmpty else {
            markAllQueuedAsFailed(step: .sign, message: "请先选择相册")
            return
        }
        isRunning = true
        defer { isRunning = false }

        for id in items.filter(\.isQueued).map(\.id) {
            await run(id)
        }
    }

    /// 重试所有失败项（重新走完整的三步 —— 签发的 URL 可能已过期，重签最稳）
    ///
    /// - Parameter includingSkipped: 连"判定为已上传而跳过"的也一起上传。
    ///   这是判重规则的**安全出口**：连拍同尺寸照片可能被误判成重复，用户一键就能推翻。
    public func retryFailed(includingSkipped: Bool = false) async {
        guard !isRunning else { return }
        for index in items.indices where items[index].isFailed || (includingSkipped && items[index].isSkipped) {
            items[index].state = .queued
        }
        if includingSkipped {
            // 用户明确要求上传这些 → 本轮不再对它们判重（否则会立刻被再跳过一次）
            forcedIDs.formUnion(items.filter(\.isQueued).map(\.id))
        }
        await runPending()
    }

    /// 被用户强制放行的项（绕过判重）
    private var forcedIDs: Set<UUID> = []

    private func markAllQueuedAsFailed(step: UploadItem.Step, message: String) {
        for index in items.indices where items[index].isQueued {
            items[index].state = .failed(step, message: message)
        }
    }

    private func run(_ id: UUID) async {
        guard let candidate = candidates[id], let index = items.firstIndex(where: { $0.id == id }) else { return }

        guard let cookieHeader = cookie(), !cookieHeader.isEmpty else {
            items[index].state = .failed(.sign, message: "登录状态已失效，请重新登录")
            return
        }

        // 0) 判重：已经传过的不再传（用户要求"把已上传的挑出来"，规则见 UploadDedupe）
        let fingerprint = Self.fingerprint(for: candidate)
        if !forcedIDs.contains(id), let match = await duplicateMatch(for: fingerprint) {
            items[index].state = .skipped(reason: match.message)
            return
        }

        // 1) 签发
        items[index].state = .running(.sign, fraction: 0)
        let signed: SignedUpload
        do {
            signed = try await api.signUpload(
                filename: candidate.filename,
                contentType: candidate.contentType,
                albumValue: albumValue,
                size: candidate.byteCount,
                cookie: cookieHeader
            )
        } catch {
            items[index].state = .failed(.sign, message: Self.failureMessage(error))
            return
        }
        guard let uploadURL = signed.uploadURL else {
            items[index].state = .failed(.sign, message: "服务端返回的上传地址无效")
            return
        }

        // 2) 直传 R2（进度在这里产生）
        items[index].state = .running(.upload, fraction: 0)
        do {
            try await uploader.upload(candidate.data, to: uploadURL, contentType: candidate.contentType) { fraction in
                Task { @MainActor [weak self] in
                    self?.updateUploadProgress(id: id, fraction: fraction)
                }
            }
        } catch {
            items[index].state = .failed(.upload, message: Self.failureMessage(error))
            return
        }

        // 3) 登记（预览图/blurhash/宽高由服务端算，这里只报原图信息）
        items[index].state = .running(.register, fraction: 1)
        do {
            let registered = try await api.registerImage(
                AdminRegisterInput(
                    albumValue: albumValue,
                    url: signed.publicUrl,
                    imageName: candidate.filename,
                    exif: candidate.exif,
                    width: candidate.width,
                    height: candidate.height
                ),
                cookie: cookieHeader
            )
            items[index].state = .done(imageID: registered.id, url: registered.url)
            // 记账：下次再选到这张（或差 2 分钟内的同尺寸同机型）就能判出来
            await ledger?.record(fingerprint, imageID: registered.id, title: candidate.filename)
        } catch {
            // 这一步失败＝R2 里已经留下一个**已上传但未登记**的对象（孤儿）。
            // 提示里必须说清楚，用户/开发者才知道去桶里按 key 找：key 就是 signed.key。
            items[index].state = .failed(
                .register,
                message: "\(Self.failureMessage(error))（原图已上传到存储，但未登记；对象 key：\(signed.key)）"
            )
        }
    }

    /// 判重：本地账本 ∪ 服务端列表
    private func duplicateMatch(for fingerprint: UploadFingerprint) async -> DuplicateMatch? {
        var known = serverFingerprints()
        if let ledger {
            known.append(contentsOf: await ledger.known())
        }
        guard !known.isEmpty else { return nil }
        return DuplicateMatcher.match(fingerprint, in: known)
    }

    /// 由候选算出指纹。EXIF 时间读不出来（截图/微信导出图）时只有字节哈希能用来判重。
    static func fingerprint(for candidate: UploadCandidate) -> UploadFingerprint {
        UploadFingerprint(
            digest: UploadFingerprint.digest(of: candidate.data),
            capturedAt: EXIFDateParser.date(from: candidate.exif["data_time"]?.stringValue),
            width: candidate.width,
            height: candidate.height,
            model: candidate.exif["model"]?.stringValue ?? ""
        )
    }

    private func updateUploadProgress(id: UUID, fraction: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // 已经跑到登记/结束的进度回调（迟到的）不能覆盖最终状态
        guard case let .running(step, _) = items[index].state, step == .upload else { return }
        items[index].state = .running(.upload, fraction: fraction)
    }

    // MARK: - 错误 → 界面文案

    /// 优先显示**服务端说的话**（例如 `authentication failed` / `unknown_album`），
    /// 拿不到再退回网络层文案，最后兜底一句产品文案。
    /// 与 `AuthStore` 的取舍一致：技术描述（带状态码）只进日志，不进界面。
    public static func failureMessage(_ error: Error) -> String {
        guard let apiError = error as? APIError else { return error.localizedDescription }
        if let serverMessage = apiError.serverMessage, !serverMessage.isEmpty {
            return serverMessage
        }
        switch apiError {
        case let .transport(detail) where !detail.isEmpty:
            return detail
        case .invalidURL:
            return "上传地址无效"
        default:
            return "上传失败，请稍后重试"
        }
    }
}

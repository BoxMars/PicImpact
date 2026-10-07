import Foundation
import Testing

@testable import PicImpactKit

/// 上传状态机：签发 → 直传 → 登记，以及**失败在哪一步**。
///
/// 这是本轮改动里最该被钉死的逻辑：界面上要能说出"哪一张、失败在哪一步"，
/// 一旦状态机把失败归错步，用户拿到的提示就是误导。
@Suite("上传状态机")
@MainActor
struct UploadCoordinatorTests {

    // MARK: - 测试替身

    /// 记录调用、按需抛错的假管理接口
    final class FakeAdminAPI: AdminImageAPI, @unchecked Sendable {
        var signResults: [Result<SignedUpload, APIError>] = []
        var registerResult: Result<RegisteredImage, APIError>
        var deleted: [String] = []
        var signCalls: [(filename: String, contentType: String, albumValue: String, size: Int)] = []
        var registerCalls: [AdminRegisterInput] = []

        init(
            sign: [Result<SignedUpload, APIError>] = [.success(FakeAdminAPI.signed)],
            register: Result<RegisteredImage, APIError> = .success(FakeAdminAPI.registered)
        ) {
            self.signResults = sign
            self.registerResult = register
        }

        static let signed = SignedUpload(
            key: "images/daily/key.jpg",
            uploadUrl: "https://r2.example.com/images/daily/key.jpg?X=1",
            publicUrl: "https://felina-asset.boxz.dev/images/daily/key.jpg",
            contentType: "image/jpeg",
            expiresInSeconds: 900
        )

        static let registered = RegisteredImage(
            id: "clx1",
            url: "https://felina-asset.boxz.dev/images/daily/key.jpg",
            previewUrl: "https://felina-asset.boxz.dev/images/daily/preview/key.webp",
            width: 1600,
            height: 1000,
            blurhash: "hash",
            albumValue: "/daily",
            show: 0,
            showOnMainpage: 0
        )

        func signUpload(filename: String, contentType: String, albumValue: String, size: Int, cookie: String) async throws -> SignedUpload {
            signCalls.append((filename, contentType, albumValue, size))
            let result = signResults.isEmpty ? .success(Self.signed) : signResults.removeFirst()
            return try result.get()
        }

        func registerImage(_ input: AdminRegisterInput, cookie: String) async throws -> RegisteredImage {
            registerCalls.append(input)
            return try registerResult.get()
        }

        func listImages(page: Int, pageSize: Int, album: String?, cookie: String) async throws -> AdminImagePage {
            AdminImagePage(page: page, pageSize: pageSize, total: 0, hasMore: false, items: [])
        }

        func deleteImage(id: String, cookie: String) async throws {
            deleted.append(id)
        }

        // 上传状态机用不到编辑，给空实现即可（协议要求）
        func updateImage(_ update: AdminImageUpdate, cookie: String) async throws {}
        func updateImageShow(id: String, show: Int, cookie: String) async throws {}
        func updateImageAlbum(imageId: String, albumId: String, cookie: String) async throws {}
    }

    /// 记录上传、按需抛错的假上传器；可以回调几次进度
    final class FakeUploader: FileUploading, @unchecked Sendable {
        var error: APIError?
        var progressSteps: [Double] = [0.5, 1.0]
        var uploads: [(bytes: Int, url: String, contentType: String)] = []

        init(error: APIError? = nil) { self.error = error }

        func upload(_ data: Data, to url: URL, contentType: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
            uploads.append((data.count, url.absoluteString, contentType))
            for step in progressSteps { onProgress(step) }
            if let error { throw error }
        }
    }

    private func makeCoordinator(
        api: FakeAdminAPI,
        uploader: FakeUploader = FakeUploader(),
        cookie: String? = "session=abc"
    ) -> UploadCoordinator {
        let coordinator = UploadCoordinator(api: api, uploader: uploader, cookie: { cookie })
        coordinator.albumValue = "/daily"
        return coordinator
    }

    private func candidate(_ name: String = "a.jpg", bytes: Int = 12 * 1024 * 1024) -> UploadCandidate {
        UploadCandidate(filename: name, contentType: "image/jpeg", data: Data(repeating: 7, count: bytes))
    }

    // MARK: - 正常路径

    @Test("张张走完三步：签发 → 直传 → 登记，最终带 id 与 url")
    func runsAllThreeSteps() async {
        let api = FakeAdminAPI()
        let uploader = FakeUploader()
        let coordinator = makeCoordinator(api: api, uploader: uploader)

        coordinator.enqueue([candidate()])
        await coordinator.runPending()

        let item = coordinator.items[0]
        #expect(item.isDone)
        if case let .done(imageID, url) = item.state {
            #expect(imageID == "clx1")
            #expect(url.hasSuffix("/key.jpg"))
        } else {
            Issue.record("状态应为 done，实际 \(item.state)")
        }

        // 签发请求带的是**真实字节数**与相册值
        #expect(api.signCalls.count == 1)
        #expect(api.signCalls[0].size == 12 * 1024 * 1024)
        #expect(api.signCalls[0].albumValue == "/daily")
        #expect(uploader.uploads.count == 1)
        #expect(uploader.uploads[0].bytes == 12 * 1024 * 1024)
        #expect(api.registerCalls.count == 1)
        #expect(api.registerCalls[0].url == FakeAdminAPI.signed.publicUrl)
        // 登记时把原图信息带上（预览图/宽高/blurhash 由服务端算）
        #expect(api.registerCalls[0].imageName == "a.jpg")
    }

    @Test("多张按顺序逐张处理（不并发，失败也不静默）")
    func processesSequentially() async {
        let api = FakeAdminAPI()
        let coordinator = makeCoordinator(api: api)

        coordinator.enqueue([candidate("a.jpg"), candidate("b.jpg"), candidate("c.jpg")])
        await coordinator.runPending()

        #expect(coordinator.items.count == 3)
        #expect(coordinator.doneCount == 3)
        #expect(api.registerCalls.count == 3)
    }

    // MARK: - 失败归因

    @Test("签发失败：归到 sign 步，且不再直传、不登记")
    func failsAtSign() async {
        let api = FakeAdminAPI(sign: [.failure(.http(status: 400, code: nil, message: "unknown_album"))])
        let uploader = FakeUploader()
        let coordinator = makeCoordinator(api: api, uploader: uploader)

        coordinator.enqueue([candidate()])
        await coordinator.runPending()

        let item = coordinator.items[0]
        #expect(item.failedStep == .sign)
        #expect(item.failureMessage == "unknown_album", "要显示服务端原话")
        #expect(uploader.uploads.isEmpty)
        #expect(api.registerCalls.isEmpty)
    }

    @Test("直传失败：归到 upload 步，且不登记")
    func failsAtUpload() async {
        let api = FakeAdminAPI()
        let uploader = FakeUploader(error: .http(status: 403, code: nil, message: nil))
        let coordinator = makeCoordinator(api: api, uploader: uploader)

        coordinator.enqueue([candidate()])
        await coordinator.runPending()

        #expect(coordinator.items[0].failedStep == .upload)
        #expect(api.registerCalls.isEmpty)
    }

    @Test("登记失败：归到 register 步，提示里带 object key（那是 R2 里的孤儿对象）")
    func failsAtRegisterMentionsOrphanKey() async {
        let api = FakeAdminAPI(register: .failure(.http(status: 500, code: nil, message: "register_failed")))
        let coordinator = makeCoordinator(api: api)

        coordinator.enqueue([candidate()])
        await coordinator.runPending()

        let item = coordinator.items[0]
        #expect(item.failedStep == .register)
        let message = item.failureMessage ?? ""
        #expect(message.contains("register_failed"))
        #expect(message.contains(FakeAdminAPI.signed.key), "必须告诉用户/开发者孤儿对象是哪个 key：\(message)")
    }

    @Test("一张失败不影响后续张")
    func failureDoesNotBlockOthers() async {
        let api = FakeAdminAPI(sign: [.failure(.transport("断网")), .success(FakeAdminAPI.signed)])
        let coordinator = makeCoordinator(api: api)

        coordinator.enqueue([candidate("bad.jpg"), candidate("good.jpg")])
        await coordinator.runPending()

        #expect(coordinator.items[0].failedStep == .sign)
        #expect(coordinator.items[1].isDone)
        #expect(coordinator.doneCount == 1)
        #expect(coordinator.failedCount == 1)
    }

    @Test("会话失效（没有 cookie）：不发出任何请求，直接归到 sign 步")
    func missingSessionFailsFast() async {
        let api = FakeAdminAPI()
        let coordinator = makeCoordinator(api: api, cookie: nil)

        coordinator.enqueue([candidate()])
        await coordinator.runPending()

        #expect(coordinator.items[0].failedStep == .sign)
        #expect(coordinator.items[0].failureMessage?.contains("登录状态已失效") == true)
        #expect(api.signCalls.isEmpty)
    }

    @Test("没选相册时不发请求（服务端也会拒，这里先拦）")
    func missingAlbumFailsFast() async {
        let api = FakeAdminAPI()
        let coordinator = UploadCoordinator(api: api, uploader: FakeUploader(), cookie: { "session=abc" })

        coordinator.enqueue([candidate()])
        await coordinator.runPending()

        #expect(coordinator.items[0].failedStep == .sign)
        #expect(coordinator.items[0].failureMessage == "请先选择相册")
        #expect(api.signCalls.isEmpty)
    }

    // MARK: - 重试与状态清理

    @Test("重试失败项：重新走完整三步并成功")
    func retryFailed() async {
        let api = FakeAdminAPI(sign: [.failure(.transport("断网")), .success(FakeAdminAPI.signed)])
        let coordinator = makeCoordinator(api: api)

        coordinator.enqueue([candidate()])
        await coordinator.runPending()
        #expect(coordinator.items[0].failedStep == .sign)

        await coordinator.retryFailed()

        #expect(coordinator.items[0].isDone)
        #expect(api.signCalls.count == 2, "重试要重新签发（旧 URL 可能已过期）")
        #expect(coordinator.failedCount == 0)
    }

    @Test("进度只落在 upload 步，且不会覆盖最终状态")
    func progressOnlyDuringUpload() async {
        let api = FakeAdminAPI()
        let uploader = FakeUploader()
        uploader.progressSteps = [0.25, 0.5, 0.75, 1.0]
        let coordinator = makeCoordinator(api: api, uploader: uploader)

        coordinator.enqueue([candidate()])
        await coordinator.runPending()

        // 结束后不允许还是 running；且 done 状态里没有 fraction
        #expect(coordinator.items[0].isDone)
        #expect(coordinator.items[0].uploadFraction == nil)
    }

    @Test("入队后是 queued；清空只在空闲时生效")
    func queueLifecycle() async {
        let coordinator = makeCoordinator(api: FakeAdminAPI())
        #expect(coordinator.enqueue([candidate(), candidate()]).count == 2)
        #expect(coordinator.items.allSatisfy { $0.isQueued })
        #expect(coordinator.pendingCount == 2)

        await coordinator.runPending()
        #expect(coordinator.doneCount == 2)

        coordinator.removeFinished()
        #expect(coordinator.items.isEmpty)
    }

    // MARK: - 判重（拍摄时间 ±2 分钟那一套）

    private func makeLedger() -> UploadLedger {
        UploadLedger(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-ledger-\(UUID().uuidString)"))
    }

    @Test("判重命中：直接跳过，签发/直传/登记一个请求都不发")
    func skipsAlreadyUploaded() async {
        let ledger = makeLedger()
        let candidate = candidate()
        // 先把这张"记成已上传"（等价于用户上次传过）
        await ledger.record(UploadCoordinator.fingerprint(for: candidate), imageID: "clx-old", title: "老照片")

        let api = FakeAdminAPI()
        let uploader = FakeUploader()
        let coordinator = UploadCoordinator(api: api, uploader: uploader, cookie: { "session=abc" }, ledger: ledger)
        coordinator.albumValue = "/daily"

        coordinator.enqueue([candidate])
        await coordinator.runPending()

        #expect(coordinator.items[0].isSkipped)
        #expect(coordinator.items[0].skipReason?.contains("完全相同") == true)
        #expect(api.signCalls.isEmpty, "跳过就不该签发")
        #expect(uploader.uploads.isEmpty, "跳过就不该直传")
        #expect(api.registerCalls.isEmpty)
        #expect(coordinator.skippedCount == 1)
        #expect(coordinator.doneCount == 0)
    }

    @Test("用户点「仍然上传」：绕过判重，照常走完三步")
    func forcedUploadBypassesDedupe() async {
        let ledger = makeLedger()
        let candidate = candidate()
        await ledger.record(UploadCoordinator.fingerprint(for: candidate), imageID: "clx-old", title: "老照片")

        let api = FakeAdminAPI()
        let coordinator = UploadCoordinator(api: api, uploader: FakeUploader(), cookie: { "session=abc" }, ledger: ledger)
        coordinator.albumValue = "/daily"

        coordinator.enqueue([candidate])
        await coordinator.runPending()
        #expect(coordinator.items[0].isSkipped)

        await coordinator.retryFailed(includingSkipped: true)
        #expect(coordinator.items[0].isDone, "强制上传必须真的传上去（连拍被误判的出口）")
        #expect(api.registerCalls.count == 1)
    }

    @Test("上传成功后记账：同一张再选一次会被判重")
    func recordsAfterSuccessfulUpload() async {
        let ledger = makeLedger()
        let api = FakeAdminAPI()
        let coordinator = UploadCoordinator(api: api, uploader: FakeUploader(), cookie: { "session=abc" }, ledger: ledger)
        coordinator.albumValue = "/daily"

        let candidate = candidate()
        coordinator.enqueue([candidate])
        await coordinator.runPending()
        #expect(coordinator.items[0].isDone)

        // 再选一次同一张：这次应当直接跳过（账本里已经有它了）
        coordinator.removeFinished()
        coordinator.enqueue([candidate])
        await coordinator.runPending()
        #expect(coordinator.items[0].isSkipped)
        #expect(api.registerCalls.count == 1, "第二次不该再登记一遍")
    }

    @Test("服务端列表来的指纹（只有元数据、没有字节）也能判重")
    func matchesServerMetadataFingerprint() async {
        let api = FakeAdminAPI()
        // 候选带 EXIF：拍摄时间 16:26:04、4032×3024、iPhone 17
        let withEXIF = UploadCandidate(
            filename: "a.jpg", contentType: "image/jpeg", data: Data(repeating: 3, count: 1024),
            exif: ["data_time": .string("2026:10:07 16:26:04"), "model": .string("iPhone 17")],
            width: 4032, height: 3024
        )
        let coordinator = UploadCoordinator(
            api: api,
            uploader: FakeUploader(),
            cookie: { "session=abc" },
            ledger: nil,
            serverFingerprints: {
                [(UploadFingerprint(digest: "", capturedAt: EXIFDateParser.date(from: "2026:10:07 16:25:30"), width: 4032, height: 3024, model: "iPhone 17"), "clx-server", "服务器上的那张")]
            }
        )
        coordinator.albumValue = "/daily"

        coordinator.enqueue([withEXIF])
        await coordinator.runPending()

        #expect(coordinator.items[0].isSkipped)
        #expect(coordinator.items[0].skipReason?.contains("服务器上的那张") == true, "要告诉用户是跟哪一张撞了")
        #expect(api.signCalls.isEmpty)
    }

    @Test("失败文案优先级：服务端原话 → 网络文案 → 通用文案")
    func failureMessagePriority() {
        #expect(UploadCoordinator.failureMessage(APIError.http(status: 401, code: nil, message: "authentication failed")) == "authentication failed")
        #expect(UploadCoordinator.failureMessage(APIError.transport("似乎已断开与互联网的连接")) == "似乎已断开与互联网的连接")
        #expect(UploadCoordinator.failureMessage(APIError.decoding("x")) == "上传失败，请稍后重试")
        #expect(UploadCoordinator.failureMessage(APIError.http(status: 500, code: nil, message: nil)) == "上传失败，请稍后重试")
    }
}

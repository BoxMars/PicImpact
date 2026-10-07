import SwiftUI

#if os(iOS)
import PhotosUI
#endif

/// 管理页：账号信息 + 上传（选图 → 直传 → 登记）+ 图片列表（删除）。
///
/// ## 这一页在做什么（以及为什么不写"提示文字"）
/// 它是登录后的唯一后台界面。按用户要求，界面上**不出现**任何"连点三次""功能开发中"
/// 之类的说明文字 —— 每个控件要么有用，要么不显示。
///
/// ## 上传为什么是"逐张 + 三步可见"
/// 单张原图可达十几 MB，失败点可能在三个完全不同的地方（签发 / 直传 / 登记），
/// 所以每一张都单独显示"进行到哪一步、失败在哪一步、失败原因是什么"。
public struct AdminHomeView: View {

    private let user: AuthUser
    private let images: AdminImageListStore
    private let uploads: UploadCoordinator
    private let loader: ImageLoader
    private let isBusy: Bool
    /// 凭证持久化失败时的告警（本次会话可用，重启后要重新登录）
    private let storageWarning: String?
    private let onSignOut: () -> Void
    private let onClose: () -> Void
    /// 图库变了（上传成功 / 删除）之后通知外面刷新公开画廊
    private let onLibraryChanged: () async -> Void

    public init(
        user: AuthUser,
        images: AdminImageListStore,
        uploads: UploadCoordinator,
        loader: ImageLoader,
        isBusy: Bool = false,
        storageWarning: String? = nil,
        onSignOut: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onLibraryChanged: @escaping () async -> Void = {}
    ) {
        self.user = user
        self.images = images
        self.uploads = uploads
        self.loader = loader
        self.isBusy = isBusy
        self.storageWarning = storageWarning
        self.onSignOut = onSignOut
        self.onClose = onClose
        self.onLibraryChanged = onLibraryChanged
    }

    public var body: some View {
        ScrollView {
            AdminHomeContent(
                user: user,
                images: images,
                uploads: uploads,
                loader: loader,
                isBusy: isBusy,
                storageWarning: storageWarning,
                onSignOut: onSignOut,
                onClose: onClose,
                onLibraryChanged: onLibraryChanged
            )
        }
        .background(AnimalTokens.bg)
        .task {
            await images.loadAlbums()
            await images.loadFirstPage()
        }
    }
}

/// 管理页**除滚动容器以外**的全部内容。
///
/// 与登录页拆开的理由相同：`ImageRenderer` 渲染不出 `ScrollView` 里的东西，
/// 而"纸卡/主色/危险色画出来了没有"必须能断言。
struct AdminHomeContent: View {

    let user: AuthUser
    let images: AdminImageListStore
    let uploads: UploadCoordinator
    let loader: ImageLoader
    let isBusy: Bool
    /// 凭证持久化失败时的告警（本次会话可用，重启后要重新登录）
    let storageWarning: String?
    let onSignOut: () -> Void
    let onClose: () -> Void
    let onLibraryChanged: () async -> Void

    @State private var pendingDelete: AdminImageSummary?
    @State private var pendingEdit: AdminImageSummary?
    @State private var isSavingEdit = false

    var body: some View {
        VStack(spacing: AnimalTokens.spacingLG) {
            HStack {
                IslandBackButton(label: "关闭", action: onClose)
                Spacer()
            }

            accountCard
            uploadCard
            imageListCard

            IslandActionButton("登出", tone: .danger, isEnabled: !isBusy, action: onSignOut)
                .accessibilityIdentifier("admin-sign-out")

            Spacer(minLength: 0)
        }
        .padding(AnimalTokens.spacingLG)
        .alert(
            "删除这张图片？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { image in
            Button("删除", role: .destructive) {
                pendingDelete = nil
                Task {
                    await images.delete(id: image.id)
                    await onLibraryChanged()
                }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { image in
            Text(image.title.isEmpty ? "删除后网页端也会立刻看不到。" : "「\(image.title)」删除后网页端也会立刻看不到。")
        }
        .sheet(item: $pendingEdit) { image in
            AdminImageEditView(
                image: image,
                albums: images.albums,
                isSaving: isSavingEdit,
                errorMessage: images.errorMessage,
                onCancel: { pendingEdit = nil },
                onSave: { draft in Task { await save(image: image, draft: draft) } }
            )
        }
    }

    /// 保存编辑：**只发改过的那几个请求**（三个接口对应三件事）。
    /// 任一失败就停在编辑页并把服务端原话显示出来，用户可以直接重试。
    private func save(image: AdminImageSummary, draft: AdminImageEditDraft) async {
        isSavingEdit = true
        defer { isSavingEdit = false }

        var saved = true
        if draft.title != image.title || draft.detail != image.detail || draft.labels != image.labels {
            saved = await images.saveMetadata(
                id: image.id, title: draft.title, detail: draft.detail, labels: draft.labels
            ) && saved
        }
        if draft.show != image.show {
            saved = await images.setVisibility(id: image.id, show: draft.show) && saved
        }
        if draft.albumValue != image.albumValue,
           let album = images.albums.first(where: { $0.value == draft.albumValue }) {
            saved = await images.moveToAlbum(
                id: image.id, albumId: album.id, albumValue: album.value, albumName: album.name
            ) && saved
        }

        if saved {
            pendingEdit = nil
            await onLibraryChanged()
        }
    }

    // MARK: - 账号

    private var accountCard: some View {
        IslandCard {
            VStack(alignment: .leading, spacing: AnimalTokens.spacingMD) {
                IslandPageTitle("管理后台")
                IslandRow(label: "邮箱", value: user.email)
                if user.displayName != user.email {
                    IslandRow(label: "昵称", value: user.displayName)
                }
                if images.total > 0 {
                    IslandRow(label: "图片", value: "\(images.total) 张")
                }
                if let errorMessage = images.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AnimalTokens.error)
                        .fixedSize(horizontal: false, vertical: true)
                    if images.sessionExpired {
                        // 会话失效必须有出口：否则用户只会看到"没有图片"，不知道该怎么办
                        IslandActionButton("重新登录", tone: .danger, isEnabled: !isBusy, action: onSignOut)
                            .accessibilityIdentifier("admin-relogin")
                    }
                }

                if let warning = storageWarning {
                    Text(warning)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AnimalTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(AnimalTokens.spacingLG)
        }
    }

    // MARK: - 上传

    private var uploadCard: some View {
        IslandCard {
            VStack(alignment: .leading, spacing: AnimalTokens.spacingMD) {
                IslandSectionTitle("上传")

                if images.albums.count > 1 {
                    albumPicker
                }

                if !uploads.items.isEmpty {
                    uploadRows
                }

                PhotoPickerButton(title: "选择照片", isEnabled: !uploads.isRunning) { candidates in
                    uploads.albumValue = images.albumValue
                    uploads.enqueue(candidates)
                    Task {
                        // 判重要对着"服务端已有的全部照片"比，所以先把列表翻完（有上限，见实现）
                        await images.loadAllRemainingPages()
                        await runUploads()
                    }
                }

                if uploads.failedCount > 0 {
                    IslandActionButton("重试失败项", isEnabled: !uploads.isRunning) {
                        Task { await runUploads(isRetry: true) }
                    }
                    .accessibilityIdentifier("admin-retry-uploads")
                }

                // 判重规则（拍摄时间 ±2 分钟）可能把连拍里的兄弟照片也判成"已上传"，
                // 所以必须给一个一键推翻的出口 —— 否则就成了"照片被悄悄丢掉"。
                if uploads.skippedCount > 0 {
                    IslandActionButton("仍然上传这 \(uploads.skippedCount) 张", isEnabled: !uploads.isRunning) {
                        Task { await runUploads(isRetry: true, includingSkipped: true) }
                    }
                    .accessibilityIdentifier("admin-force-upload-skipped")
                }

                if uploads.doneCount > 0 && !uploads.isRunning && uploads.failedCount == 0 {
                    IslandActionButton("完成", isEnabled: true) {
                        uploads.clearAll()
                    }
                    .accessibilityIdentifier("admin-finish-uploads")
                }
            }
            .padding(AnimalTokens.spacingLG)
        }
    }

    private var albumPicker: some View {
        HStack(spacing: AnimalTokens.spacingSM) {
            Text("相册")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AnimalTokens.textSecondary)
            Spacer(minLength: 0)
            Menu {
                ForEach(images.albums) { album in
                    Button(album.name) {
                        uploads.albumValue = album.value
                        Task { await images.select(album: album.value) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentAlbumName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AnimalSignatures.cardText)
                    Chevron(direction: .up)
                        .stroke(
                            AnimalSignatures.cardText,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 12, height: 7)
                        .rotationEffect(.degrees(180))
                }
                .accessibilityIdentifier("admin-album-picker")
            }
        }
    }

    private var currentAlbumName: String {
        images.albums.first { $0.value == images.albumValue }?.name ?? images.albumValue
    }

    @ViewBuilder
    private var uploadRows: some View {
        VStack(spacing: AnimalTokens.spacingSM) {
            ForEach(uploads.items) { item in
                AdminUploadStatusRow(item: item)
            }
        }
    }

    private func runUploads(isRetry: Bool = false, includingSkipped: Bool = false) async {
        if isRetry {
            await uploads.retryFailed(includingSkipped: includingSkipped)
        } else {
            await uploads.runPending()
        }
        if uploads.doneCount > 0 {
            await images.refreshAfterUpload()
            await onLibraryChanged()
        }
    }

    // MARK: - 列表

    private var imageListCard: some View {
        IslandCard {
            VStack(alignment: .leading, spacing: AnimalTokens.spacingMD) {
                IslandSectionTitle("图片")

                if images.isLoading && images.images.isEmpty {
                    Text("加载中…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AnimalTokens.textSecondary)
                } else if images.images.isEmpty, let errorMessage = images.errorMessage {
                    // 之前这里无论什么原因都只说"这个相册还没有图片" —— 真机上会话失效时
                    // 用户看到的就是这一句，完全查不出问题。现在把真正的原因放在这里。
                    VStack(alignment: .leading, spacing: AnimalTokens.spacingSM) {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AnimalTokens.error)
                            .fixedSize(horizontal: false, vertical: true)
                        IslandActionButton("重试", isEnabled: !images.isLoading) {
                            Task { await images.loadFirstPage() }
                        }
                        .accessibilityIdentifier("admin-list-retry")
                    }
                } else if images.images.isEmpty {
                    Text("这个相册还没有图片")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AnimalTokens.textSecondary)
                } else {
                    VStack(spacing: AnimalTokens.spacingMD) {
                        ForEach(images.images) { image in
                            AdminImageRow(
                                image: image,
                                loader: loader,
                                isDeleting: images.deletingIDs.contains(image.id),
                                onEdit: { pendingEdit = image },
                                onDelete: { pendingDelete = image }
                            )
                        }
                    }
                }

                if images.hasMore {
                    IslandActionButton("加载更多", isEnabled: !images.isLoadingMore) {
                        Task { await images.loadNextPage() }
                    }
                    .accessibilityIdentifier("admin-load-more")
                }
            }
            .padding(AnimalTokens.spacingLG)
        }
    }
}

/// 一张图的**当前状态**（进行到哪一步 / 失败在哪一步）
struct AdminUploadStatusRow: View {

    let item: UploadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: AnimalTokens.spacingSM) {
                Text(item.filename)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AnimalSignatures.cardText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(statusColor)
                    .fixedSize()
            }

            if let fraction = item.uploadFraction {
                ProgressView(value: fraction)
                    .tint(AnimalTokens.primary)
            }

            if let message = item.failureMessage {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AnimalTokens.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let reason = item.skipReason {
                Text(reason)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AnimalTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AnimalTokens.spacingSM + 2)
        .islandSurface(borderWidth: 1.5, cornerRadius: 12, shadowOffsetY: 2)
    }

    private var statusText: String {
        switch item.state {
        case .queued:
            return "等待中"
        case .skipped:
            return "已跳过"
        case let .running(step, fraction):
            if step == .upload {
                return "上传中 \(Int(fraction * 100))%"
            }
            return "\(step.label)…"
        case .done:
            return "已完成"
        case let .failed(step, _):
            return "失败于「\(step.label)」"
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .done: return AnimalTokens.success
        case .failed: return AnimalTokens.error
        // 跳过不是错误：用次要色，避免"红色＝出错"的误导
        case .skipped: return AnimalTokens.textSecondary
        default: return AnimalTokens.textSecondary
        }
    }
}

/// 列表里的一行：缩略图 + 标题/日期 + 删除
struct AdminImageRow: View {

    let image: AdminImageSummary
    let loader: ImageLoader
    let isDeleting: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: AnimalTokens.spacingMD) {
            CachedAsyncImage(url: image.thumbnailURL, loader: loader, contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .circular))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .circular)
                        .strokeBorder(AnimalSignatures.cardBorder, lineWidth: 1.5)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AnimalSignatures.cardText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AnimalTokens.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: onEdit) {
                Text("编辑")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(AnimalTokens.primary)
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
            .accessibilityIdentifier("admin-edit-\(image.id)")

            Button(action: onDelete) {
                Text("删除")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(isDeleting ? AnimalTokens.textDisabled : AnimalTokens.error)
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
            .accessibilityIdentifier("admin-delete-\(image.id)")
        }
    }

    private var displayTitle: String {
        if !image.title.isEmpty { return image.title }
        if let name = URL(string: image.url)?.lastPathComponent, !name.isEmpty { return name }
        return image.id
    }

    private var subtitle: String {
        var parts: [String] = []
        if image.show != 0 {
            parts.append("已隐藏")
        }
        if let createdAt = image.createdAt {
            parts.append(AdminImageRow.dateFormatter.string(from: createdAt))
        }
        if image.width > 0, image.height > 0 {
            parts.append("\(image.width)×\(image.height)")
        }
        if !image.albumName.isEmpty {
            parts.append(image.albumName)
        }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// `PhotosPicker` 的 ACNH 外观按钮。
///
/// `PhotosPicker` 自己就是交互控件，套不进 `Button`，所以复用 `IslandActionLabel` 的**外观**
/// （配色只有那一处定义）。
struct PhotoPickerButton: View {

    let title: String
    let isEnabled: Bool
    let onPicked: ([UploadCandidate]) -> Void

    #if os(iOS)
    @State private var selection: [PhotosPickerItem] = []
    #endif

    var body: some View {
        #if os(iOS)
        // ⚠️ 不要传 `photoLibrary: .shared()`：那会走"读相册"的权限路径，而本 App 的 Info.plist
        // 只有 `NSPhotoLibraryAddUsageDescription`（存图权限），没有读权限 ——
        // 实测结果是**App 被系统直接终止**（界面表现为 sheet 莫名消失）。
        // 不传这个参数时用的是进程外的 PHPicker，不需要任何相册权限。
        PhotosPicker(
            selection: $selection,
            maxSelectionCount: 30,
            matching: .images
        ) {
            IslandActionLabel(title, icon: .camera, isEnabled: isEnabled)
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier("admin-pick-photos")
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let candidates = await PhotoPickerLoader.candidates(from: items)
                selection = []
                if !candidates.isEmpty { onPicked(candidates) }
            }
        }
        #else
        // macOS 上没有 PhotosPicker（App 只在 iOS 上跑，macOS 只是 swift test 的宿主）
        IslandActionLabel(title, icon: .camera, isEnabled: false)
        #endif
    }
}

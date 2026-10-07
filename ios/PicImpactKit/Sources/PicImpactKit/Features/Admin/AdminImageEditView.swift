import SwiftUI

/// 编辑一张图的标题 / 详情 / 标签 / 显示状态 / 所属相册。
///
/// ## 为什么用 `.sheet(item:)` 独立一层，而不是在列表里就地编辑
/// 列表是瀑布式的一堆行，就地编辑会让"改哪一行"和"列表滚到哪"耦合在一起；
/// 独立一层还能顺手把「取消」做成无损操作（草稿留在这一层，取消就是丢掉）。
///
/// ## 为什么会发多个请求
/// 服务端把三件事拆成了三个接口（`/images/update`、`/update-show`、`/update-Album`），
/// 这里按"改了什么才发什么"来调 —— 只改标题就只发一个请求。
public struct AdminImageEditView: View {

    private let image: AdminImageSummary
    private let albums: [AlbumDTO]
    private let isSaving: Bool
    private let errorMessage: String?
    private let onCancel: () -> Void
    private let onSave: (AdminImageEditDraft) -> Void

    public init(
        image: AdminImageSummary,
        albums: [AlbumDTO],
        isSaving: Bool,
        errorMessage: String?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (AdminImageEditDraft) -> Void
    ) {
        self.image = image
        self.albums = albums
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.onCancel = onCancel
        self.onSave = onSave
    }

    public var body: some View {
        ScrollView {
            AdminImageEditContent(
                image: image,
                albums: albums,
                isSaving: isSaving,
                errorMessage: errorMessage,
                onCancel: onCancel,
                onSave: onSave
            )
        }
        .background(AnimalTokens.bg)
    }
}

/// 编辑页**除滚动容器以外**的全部内容（`ImageRenderer` 渲染不出 `ScrollView` 里的东西）。
struct AdminImageEditContent: View {

    let image: AdminImageSummary
    let albums: [AlbumDTO]
    let isSaving: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onSave: (AdminImageEditDraft) -> Void

    @State private var title: String
    @State private var detail: String
    @State private var labelsText: String
    @State private var show: Int
    @State private var albumValue: String

    init(
        image: AdminImageSummary,
        albums: [AlbumDTO],
        isSaving: Bool,
        errorMessage: String?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (AdminImageEditDraft) -> Void
    ) {
        self.image = image
        self.albums = albums
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: image.title)
        _detail = State(initialValue: image.detail)
        _labelsText = State(initialValue: AdminImageEditDraft.formatLabels(image.labels))
        _show = State(initialValue: image.show)
        _albumValue = State(initialValue: image.albumValue)
    }

    private var draft: AdminImageEditDraft {
        AdminImageEditDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: detail,
            labels: AdminImageEditDraft.parseLabels(labelsText),
            show: show,
            albumValue: albumValue
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AnimalTokens.spacingLG) {
            HStack {
                IslandBackButton(label: "取消", action: onCancel)
                Spacer()
                IslandPageTitle("编辑图片")
            }

            IslandCard {
                VStack(alignment: .leading, spacing: AnimalTokens.spacingMD) {
                    IslandSectionTitle("内容")

                    field("标题", text: $title, identifier: "edit-title")
                    field("详情", text: $detail, identifier: "edit-detail", lines: 3)
                    field("标签", text: $labelsText, identifier: "edit-labels")
                    Text("多个标签用逗号分隔")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AnimalTokens.textSecondary)
                }
                .padding(AnimalTokens.spacingLG)
            }

            IslandCard {
                VStack(alignment: .leading, spacing: AnimalTokens.spacingMD) {
                    IslandSectionTitle("展示")

                    IslandRow(label: "状态", value: show == 0 ? "在站点显示" : "已从站点隐藏")
                    IslandActionButton(
                        show == 0 ? "从站点隐藏" : "恢复显示",
                        tone: show == 0 ? .danger : .primary,
                        isEnabled: !isSaving
                    ) {
                        show = show == 0 ? 1 : 0
                    }
                    .accessibilityIdentifier("edit-toggle-show")

                    if albums.count > 1 {
                        albumPicker
                    } else if let album = albums.first {
                        IslandRow(label: "相册", value: album.name)
                    }
                }
                .padding(AnimalTokens.spacingLG)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AnimalTokens.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: AnimalTokens.spacingMD) {
                IslandActionButton("取消", tone: .danger, isEnabled: !isSaving, action: onCancel)
                IslandActionButton("保存", isEnabled: !isSaving) {
                    onSave(draft)
                }
                .accessibilityIdentifier("edit-save")
            }

            Spacer(minLength: 0)
        }
        .padding(AnimalTokens.spacingLG)
    }

    private var albumPicker: some View {
        HStack(spacing: AnimalTokens.spacingSM) {
            Text("相册")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AnimalTokens.textSecondary)
            Spacer(minLength: 0)
            Menu {
                ForEach(albums) { album in
                    Button(album.name) { albumValue = album.value }
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
                .accessibilityIdentifier("edit-album-picker")
            }
        }
    }

    private var currentAlbumName: String {
        albums.first { $0.value == albumValue }?.name ?? albumValue
    }

    private func field(_ label: String, text: Binding<String>, identifier: String, lines: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AnimalTokens.textSecondary)
            TextField(label, text: text, axis: lines > 1 ? .vertical : .horizontal)
                .lineLimit(lines...lines)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AnimalSignatures.cardText)
                .tint(AnimalTokens.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .islandSurface(fill: AnimalTokens.bg, borderWidth: 1.5, cornerRadius: 14, shadowOffsetY: 2)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// 编辑页的草稿。纯值 + 纯函数，规则可以脱离界面单测。
public struct AdminImageEditDraft: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var labels: [String]
    /// 0＝显示，1＝隐藏（与接口一致）
    public var show: Int
    public var albumValue: String

    public init(title: String, detail: String, labels: [String], show: Int, albumValue: String) {
        self.title = title
        self.detail = detail
        self.labels = labels
        self.show = show
        self.albumValue = albumValue
    }

    /// 标签输入框 ↔ 数组。中英文逗号都认；去空白、去空项、保序去重。
    public static func parseLabels(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" }) {
            let label = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seen.insert(label).inserted else { continue }
            result.append(label)
        }
        return result
    }

    public static func formatLabels(_ labels: [String]) -> String {
        labels.joined(separator: ", ")
    }
}

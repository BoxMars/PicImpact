import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 把"用户选的图"整理成上传候选：读 EXIF、必要时把 HEIC 转成 JPEG。
///
/// ## 为什么 HEIC 要转
/// 服务端的缩略图用 sharp（libvips）生成，**不保证**那个构建里编进了 HEIF 解码器；
/// 一旦解不了，`attachManagedImageMetadata` 会打日志并继续入库，结果是这张图的
/// `preview_url` 为空 → web 与 App 的列表都会去加载 3~12MB 的原图（正是评审要点 3 说的病症）。
/// Web 上传页早就这么做了（`multiple-file-upload.tsx` 先用 `heic-to` 转 JPEG 再传），
/// 这里保持同一策略：**不赌服务端能解 HEIC**。
///
/// 转换用系统能力（`UIImage` 解 HEIC + `jpegData` 重编码），不引第三方依赖。
public enum UploadPreparation {

    /// 需要转 JPEG 的内容类型
    public static func needsJPEGConversion(contentType: String) -> Bool {
        let lower = contentType.lowercased()
        return lower.contains("heic") || lower.contains("heif")
    }

    /// `IMG_0001.HEIC` → `IMG_0001.jpg`
    public static func jpegFilename(from filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return "\(filename).jpg" }
        return "\(filename[filename.startIndex..<dot]).jpg"
    }

    /// 组装候选。EXIF **必须从原图读**（转码后 EXIF 会丢）。
    ///
    /// - Returns: 转换失败时返回 nil（宁可让这一张失败，也不要上传一个解不开的文件）
    public static func candidate(from data: Data, filename: String, contentType: String) -> UploadCandidate? {
        guard !data.isEmpty else { return nil }

        let metadata = ImageEXIFReader.metadata(from: data)

        if needsJPEGConversion(contentType: contentType) {
            guard let jpeg = jpegData(from: data) else { return nil }
            return UploadCandidate(
                filename: jpegFilename(from: filename),
                contentType: "image/jpeg",
                data: jpeg,
                exif: metadata.exif,
                width: metadata.width,
                height: metadata.height
            )
        }

        return UploadCandidate(
            filename: filename,
            contentType: contentType,
            data: data,
            exif: metadata.exif,
            width: metadata.width,
            height: metadata.height
        )
    }

    /// HEIC/HEIF → JPEG。非 iOS 平台（`swift test` 跑在 macOS）返回 nil，
    /// 所以纯逻辑的测试要避开这个分支。
    public static func jpegData(from data: Data, quality: CGFloat = 0.95) -> Data? {
        #if canImport(UIKit)
        return UIImage(data: data)?.jpegData(compressionQuality: quality)
        #else
        return nil
        #endif
    }
}

#if os(iOS)
// ⚠️ `PhotosPickerItem` 需要 **同时** import SwiftUI 与 PhotosUI（只 import PhotosUI 找不到该类型，实测）
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// PhotoPicker → 上传候选。
///
/// 为什么单独一层：`PhotosPickerItem` 是 SwiftUI/PhotosUI 类型，放进上传状态机就没法在
/// `swift test`（macOS）下编译；这里只负责"取值 + 起名"，然后交给纯逻辑的 `UploadPreparation`。
enum PhotoPickerLoader {

    static func candidates(from items: [PhotosPickerItem]) async -> [UploadCandidate] {
        var result: [UploadCandidate] = []
        for item in items {
            // Data.self 拿到的就是**原图字节**（不是缩略图），这是"绕过 serverless 请求体上限"
            // 这条设计目标的前提 —— 大于 10MB 的原图必须原样 PUT 到 R2。
            guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else { continue }
            let type = item.supportedContentTypes.first
            let contentType = type?.preferredMIMEType ?? "image/jpeg"
            let ext = type?.preferredFilenameExtension ?? "jpg"
            guard let candidate = UploadPreparation.candidate(
                from: data,
                filename: defaultFilename(extension: ext),
                contentType: contentType
            ) else { continue }
            result.append(candidate)
        }
        return result
    }

    /// PhotoPicker 不提供原始文件名，这里生成一个可读且不重复的：
    /// `photo-20261007-174500-ab12.jpg`
    private static func defaultFilename(extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "photo-\(formatter.string(from: Date()))-\(suffix).\(ext)"
    }
}
#endif

import Foundation

#if os(iOS)
import Photos
#endif

/// 原图下载（对应 Web 端的「下载原图」）。
///
/// 与 Web 的差别：Web 走 `/api/public/download/:id` 让服务端代取并带上
/// `Content-Disposition` 文件名；iOS 直接取资产域原图后写入相册，
/// 少一跳、也避免把服务端当文件中转。文件名仍用 DTO 的 `imageName`。
///
/// **接入方注意**：iOS 需要 Info.plist 里的 `NSPhotoLibraryAddUsageDescription`
/// （仅新增权限，不需要完整相册读取权限）。
public protocol DownloadService: Sendable {
    func download(_ image: ImageDTO) async throws
}

public struct DefaultDownloadService: DownloadService {

    public enum DownloadError: Error, LocalizedError, Sendable {
        case missingOriginalURL
        case notAuthorized
        case saveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingOriginalURL: return "这张图没有可下载的原图"
            case .notAuthorized: return "没有相册写入权限"
            case let .saveFailed(detail): return "保存失败：\(detail)"
            }
        }
    }

    private let loader: ImageLoader

    public init(loader: ImageLoader) {
        self.loader = loader
    }

    public func download(_ image: ImageDTO) async throws {
        guard let url = image.originalURL else { throw DownloadError.missingOriginalURL }
        let data = try await loader.data(for: url)

        #if os(iOS)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw DownloadError.notAuthorized
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                // 用 DTO 的原始文件名，与 Web 的下载文件名保持一致
                let options = PHAssetResourceCreationOptions()
                if !image.imageName.isEmpty {
                    options.originalFilename = image.imageName
                }
                request.addResource(with: .photo, data: data, options: options)
            }
        } catch {
            throw DownloadError.saveFailed(error.localizedDescription)
        }
        #else
        // macOS：写入下载目录，便于在测试与开发机上验证
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let filename = image.imageName.isEmpty ? "\(image.id).jpg" : image.imageName
        do {
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        } catch {
            throw DownloadError.saveFailed(error.localizedDescription)
        }
        #endif
    }
}

/// 测试用的假实现：只记录被下载了哪些图，不碰系统相册。
public actor RecordingDownloadService: DownloadService {
    private var downloadedIDs: [String] = []
    private let shouldFail: Bool

    public init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    public func download(_ image: ImageDTO) async throws {
        if shouldFail { throw DefaultDownloadService.DownloadError.notAuthorized }
        downloadedIDs.append(image.id)
    }

    public func recorded() -> [String] { downloadedIDs }
}

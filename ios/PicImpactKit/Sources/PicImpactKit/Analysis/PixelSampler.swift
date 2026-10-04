import CoreGraphics
import Foundation

/// 把平台图片转成 `RGBABuffer`，并按 Web 端的规则先缩放。
///
/// 为什么要缩放：Web 端把图先画到 200/300px 的 canvas 再读像素，
/// 移植时若不缩放，大图（4000×3000 = 1200 万像素）的统计结果虽然趋势相同，
/// 但直方图的分箱分布与影调占比会和 Web **不一致** —— 那就违背了"两端结论一致"。
///
/// 注意：这里不关心上下翻转。统计量与方向无关（直方图、均值、标准差都不变），
/// 所以读到的行序是正序还是倒序都不影响结果。
public enum PixelSampler {

    public static func buffer(from image: PlatformImage, maxSize: Int) -> RGBABuffer? {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return nil }
        #elseif canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        return nil
        #endif

        let target = ImageAnalysis.sampledSize(width: cgImage.width, height: cgImage.height, maxSize: maxSize)
        guard target.width > 0, target.height > 0 else { return nil }

        let width = target.width
        let height = target.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)

        let ok: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // 缩放到目标尺寸（对应 Web 的 ctx.drawImage(img, 0, 0, w, h)）
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        return RGBABuffer(width: width, height: height, bytes: bytes)
    }

    /// 便捷：直接做影调分析（影调采样上限 200，与 Web 一致）
    public static func analyzeTone(from image: PlatformImage) -> ToneAnalysis {
        guard let buffer = buffer(from: image, maxSize: ImageAnalysis.toneSampleMaxSize) else {
            return .empty
        }
        return ImageAnalysis.analyzeTone(buffer)
    }

    /// 便捷：直接算直方图（直方图采样上限 300，与 Web 一致）
    public static func histogram(from image: PlatformImage) -> Histogram? {
        guard let buffer = buffer(from: image, maxSize: ImageAnalysis.histogramSampleMaxSize) else {
            return nil
        }
        return ImageAnalysis.histogram(buffer)
    }
}

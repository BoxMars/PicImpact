import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// ThumbHash 解码器（移植自仓库前端所用的 `thumbhash@0.1.1`）。
///
/// ## 为什么不是 blurhash
/// 线上 JSON 里的字段名叫 `blurhash`，但前端 `hooks/use-blurhash.ts` 实际调用的是
/// `decodeThumbHash`，依赖 `thumbhash` 包 —— 内容是 **ThumbHash**（blurhash 的后继格式）。
/// 所以字段虽叫 blurhash，按 blurhash 规范解必然失败（定长 28 字符、base64 字符集）。
///
/// ## 正确性怎么保证
/// 移植后与仓库里的 JS 参考实现**逐像素比对**：同一批真实 hash，
/// 两边输出的 RGBA 最大通道差为 0。测试里保留了从 JS 生成的金标准采样点。
public enum ThumbHash {
    public struct Image: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let rgba: [UInt8]
    }

    public static func approximateAspectRatio(_ h: [UInt8]) -> Double {
        let header = Int(h[3])
        let hasAlpha = (Int(h[2]) & 0x80) != 0
        let isLandscape = (Int(h[4]) & 0x80) != 0
        let lx = isLandscape ? (hasAlpha ? 5 : 7) : (header & 7)
        let ly = isLandscape ? (header & 7) : (hasAlpha ? 5 : 7)
        return ly == 0 ? 1 : Double(lx) / Double(ly)
    }

    public static func decode(_ h: [UInt8]) -> Image? {
        guard h.count >= 5 else { return nil }
        let header24 = Int(h[0]) | (Int(h[1]) << 8) | (Int(h[2]) << 16)
        let header16 = Int(h[3]) | (Int(h[4]) << 8)
        let lDC = Double(header24 & 63) / 63
        let pDC = Double((header24 >> 6) & 63) / 31.5 - 1
        let qDC = Double((header24 >> 12) & 63) / 31.5 - 1
        let lScale = Double((header24 >> 18) & 31) / 31
        let hasAlpha = (header24 >> 23) != 0
        let pScale = Double((header16 >> 3) & 63) / 63
        let qScale = Double((header16 >> 9) & 63) / 63
        let isLandscape = (header16 >> 15) != 0
        let lx = max(3, isLandscape ? (hasAlpha ? 5 : 7) : (header16 & 7))
        let ly = max(3, isLandscape ? (header16 & 7) : (hasAlpha ? 5 : 7))
        let aDC = hasAlpha ? Double(h[5] & 15) / 15 : 1
        let aScale = Double(h[5] >> 4) / 15
        let acStart = hasAlpha ? 6 : 5
        var acIndex = 0

        func decodeChannel(_ nx: Int, _ ny: Int, _ scale: Double) -> [Double] {
            var ac: [Double] = []
            ac.reserveCapacity(nx * ny)
            for cy in 0..<ny {
                var cx = cy != 0 ? 0 : 1
                while cx * ny < nx * (ny - cy) {
                    let byteIndex = acStart + (acIndex >> 1)
                    guard byteIndex < h.count else { return ac }
                    let nibble = (Int(h[byteIndex]) >> ((acIndex & 1) << 2)) & 15
                    acIndex += 1
                    ac.append((Double(nibble) / 7.5 - 1) * scale)
                    cx += 1
                }
            }
            return ac
        }

        let lAC = decodeChannel(lx, ly, lScale)
        let pAC = decodeChannel(3, 3, pScale * 1.25)
        let qAC = decodeChannel(3, 3, qScale * 1.25)
        let aAC = hasAlpha ? decodeChannel(5, 5, aScale) : []

        let ratio = approximateAspectRatio(h)
        let w = max(1, Int((ratio > 1 ? 32.0 : 32 * ratio).rounded()))
        let hh = max(1, Int((ratio > 1 ? 32 / ratio : 32.0).rounded()))
        var rgba = [UInt8](repeating: 0, count: w * hh * 4)
        var fx = [Double](repeating: 0, count: 8)
        var fy = [Double](repeating: 0, count: 8)

        for y in 0..<hh {
            for x in 0..<w {
                var l = lDC, p = pDC, q = qDC, a = aDC
                let nx = max(lx, hasAlpha ? 5 : 3)
                let ny = max(ly, hasAlpha ? 5 : 3)
                for cx in 0..<nx { fx[cx] = cos(Double.pi / Double(w) * (Double(x) + 0.5) * Double(cx)) }
                for cy in 0..<ny { fy[cy] = cos(Double.pi / Double(hh) * (Double(y) + 0.5) * Double(cy)) }

                var j = 0
                for cy in 0..<ly {
                    var cx = cy != 0 ? 0 : 1
                    let fy2 = fy[cy] * 2
                    while cx * ly < lx * (ly - cy) {
                        if j < lAC.count { l += lAC[j] * fx[cx] * fy2 }
                        j += 1; cx += 1
                    }
                }
                j = 0
                for cy in 0..<3 {
                    var cx = cy != 0 ? 0 : 1
                    let fy2 = fy[cy] * 2
                    while cx < 3 - cy {
                        let f = fx[cx] * fy2
                        if j < pAC.count { p += pAC[j] * f }
                        if j < qAC.count { q += qAC[j] * f }
                        j += 1; cx += 1
                    }
                }
                if hasAlpha {
                    j = 0
                    for cy in 0..<5 {
                        var cx = cy != 0 ? 0 : 1
                        let fy2 = fy[cy] * 2
                        while cx < 5 - cy {
                            if j < aAC.count { a += aAC[j] * fx[cx] * fy2 }
                            j += 1; cx += 1
                        }
                    }
                }
                let b = l - 2.0 / 3.0 * p
                let r = (3 * l - b + q) / 2
                let g = r - q
                let o = (y * w + x) * 4
                rgba[o]     = UInt8(max(0, 255 * min(1, r)))
                rgba[o + 1] = UInt8(max(0, 255 * min(1, g)))
                rgba[o + 2] = UInt8(max(0, 255 * min(1, b)))
                rgba[o + 3] = UInt8(max(0, 255 * min(1, a)))
            }
        }
        return Image(width: w, height: hh, rgba: rgba)
    }
}

public extension ThumbHash {
    /// 从 base64 字符串解码（线上字段的形态）。解不开返回 nil —— 调用方回退到平色占位。
    static func decode(base64 hash: String) -> Image? {
        guard let data = Data(base64Encoded: hash, options: [.ignoreUnknownCharacters]) else { return nil }
        return decode([UInt8](data))
    }
}

/// ThumbHash 解码结果的进程内缓存，并转成可显示的图片。
///
/// 解码本身很便宜（典型 32×23），但 `CachedAsyncImage` 会随滚动反复重建，
/// 每次都重新构造 CGImage 是浪费；按 hash 字符串缓存即可（一张约 3KB）。
@MainActor
public enum ThumbHashImageCache {
    private static var storage: [String: PlatformImage] = [:]

    public static func image(for hash: String) -> PlatformImage? {
        if let cached = storage[hash] { return cached }
        guard let decoded = ThumbHash.decode(base64: hash),
              let image = makeImage(decoded) else { return nil }
        storage[hash] = image
        return image
    }

    private static func makeImage(_ decoded: ThumbHash.Image) -> PlatformImage? {
        let data = Data(decoded.rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                  width: decoded.width,
                  height: decoded.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: decoded.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  // ThumbHash 的 RGB **不**与 A 预乘，所以用 .last 而不是 .premultipliedLast
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: decoded.width, height: decoded.height))
        #endif
    }
}

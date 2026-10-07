import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PicImpactKit

/// EXIF 读取与**形态对齐**。
///
/// 形态基准是生产库里 Web（ExifReader）写进去的样子：
/// `"f_number": "f/1.6"`、`"exposure_time": "1/39"`、`"focal_length": "5.96 mm"`、
/// `"iso_speed_rating": 640`（数字）。App 若写成别的形态，同一张图在两端显示会不一样。
@Suite("EXIF · 读取与形态")
struct ImageEXIFReaderTests {

    // MARK: - 纯格式化（不依赖真实图片）

    @Test("曝光时间用「1/N」的展示形态")
    func exposureTimeFormat() {
        #expect(ImageEXIFReader.exposureTime(1.0 / 39) == "1/39")
        #expect(ImageEXIFReader.exposureTime(0.0256) == "1/39")
        #expect(ImageEXIFReader.exposureTime(2) == "2")
        #expect(ImageEXIFReader.exposureTime(0) == nil)
        #expect(ImageEXIFReader.exposureTime(-1) == nil)
    }

    @Test("光圈带 f/ 前缀，焦距带单位")
    func apertureAndFocal() {
        #expect(ImageEXIFReader.fNumber(1.6) == "f/1.6")
        #expect(ImageEXIFReader.fNumber(0) == nil)
        #expect(ImageEXIFReader.focalLength(5.96) == "5.96 mm")
        #expect(ImageEXIFReader.focalLength(6) == "6 mm")
    }

    @Test("镜头规格：焦距区间 + 光圈")
    func lensSpecificationFormat() {
        #expect(ImageEXIFReader.lensSpecification([5.96, 5.96, 1.6, 1.6]) == "5.96-5.96 mm f/1.6")
        #expect(ImageEXIFReader.lensSpecification([4.25, 17, 1.8, 2.8]) == "4.25-17 mm f/1.8-2.8")
        #expect(ImageEXIFReader.lensSpecification([1, 2]) == nil, "长度不对时不要瞎拼")
    }

    @Test("枚举名与 ExifReader 的英文描述一致")
    func enumNames() {
        #expect(ImageEXIFReader.exposureProgramName(2) == "Normal program")
        #expect(ImageEXIFReader.exposureProgramName(99) == nil)
        #expect(ImageEXIFReader.exposureModeName(0) == "Auto exposure")
        #expect(ImageEXIFReader.whiteBalanceName(0) == "Auto white balance")
        #expect(ImageEXIFReader.colorSpaceName(65535) == "Uncalibrated")
        #expect(ImageEXIFReader.colorSpaceName(1) == "sRGB")
    }

    // MARK: - 真实图片

    /// 造一张带 EXIF 的 JPEG（用 ImageIO 写，不引第三方库）
    private func jpegWithEXIF(width: Int = 400, height: Int = 300, orientation: Int = 1) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: "iPhone 15",
                "BitsPerSample": 8,
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:06 15:42:40",
                kCGImagePropertyExifExposureTime: 0.0256,
                kCGImagePropertyExifFNumber: 1.6,
                kCGImagePropertyExifExposureProgram: 2,
                kCGImagePropertyExifISOSpeedRatings: [640],
                kCGImagePropertyExifFocalLength: 5.96,
                kCGImagePropertyExifLensSpecification: [5.96, 5.96, 1.6, 1.6],
                kCGImagePropertyExifLensModel: "iPhone 15 back dual wide camera 5.96mm f/1.6",
                kCGImagePropertyExifExposureMode: 0,
                kCGImagePropertyExifWhiteBalance: 0,
                kCGImagePropertyExifColorSpace: 65535,
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("从真实 JPEG 里读出的形状与生产库里的既有数据一致")
    func readsRealJPEG() throws {
        let exif = ImageEXIFReader.read(from: try jpegWithEXIF())

        #expect(exif["make"] == .string("Apple"))
        #expect(exif["model"] == .string("iPhone 15"))
        #expect(exif["bits"] == .string("8"))
        #expect(exif["data_time"] == .string("2026:10:06 15:42:40"))
        #expect(exif["f_number"] == .string("f/1.6"))
        #expect(exif["exposure_time"] == .string("1/39"))
        #expect(exif["focal_length"] == .string("5.96 mm"))
        #expect(exif["lens_specification"] == .string("5.96-5.96 mm f/1.6"))
        #expect(exif["exposure_program"] == .string("Normal program"))
        #expect(exif["iso_speed_rating"] == .int(640), "ISO 必须是数字（Web 存的就是数字）")
        #expect(exif["exposure_mode"] == .string("Auto exposure"))
        #expect(exif["white_balance"] == .string("Auto white balance"))
        // 注：合成图里写不进 EXIF ColorSpace（ImageIO 会把该键丢掉，实测），
        // 所以这里不对文件断言 color_space —— 映射本身由上面的 `enumNames` 覆盖
        #expect(exif["color_space"] == nil)
    }

    @Test("metadata 同时给尺寸；方向 5~8 要交换宽高")
    func metadataSizeRespectsOrientation() throws {
        let upright = ImageEXIFReader.metadata(from: try jpegWithEXIF(width: 400, height: 300, orientation: 1))
        #expect(upright.width == 400)
        #expect(upright.height == 300)

        let rotated = ImageEXIFReader.metadata(from: try jpegWithEXIF(width: 400, height: 300, orientation: 6))
        #expect(rotated.width == 300, "方向 6（顺时针 90°）显示时宽高要对调")
        #expect(rotated.height == 400)
    }

    @Test("没有 EXIF 的图返回空字典而不是失败（截图、微信导出图都要能传）")
    func noEXIFIsFine() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let exif = ImageEXIFReader.read(from: data as Data)
        #expect(exif["model"] == nil)
        #expect(ImageEXIFReader.metadata(from: data as Data).width == 10)

        // 完全不是图片的字节也不该崩
        #expect(ImageEXIFReader.read(from: Data("not an image".utf8)).isEmpty)
    }
}

/// HEIC → JPEG 的决策（转换本身依赖 UIKit，只在 iOS 上跑）
@Suite("上传准备 · 扩展名与转码决策")
struct UploadPreparationTests {

    @Test("HEIC/HEIF 才需要转码（web 上传页同样先转 HEIC）")
    func conversionDecision() {
        #expect(UploadPreparation.needsJPEGConversion(contentType: "image/heic"))
        #expect(UploadPreparation.needsJPEGConversion(contentType: "image/HEIF"))
        #expect(UploadPreparation.needsJPEGConversion(contentType: "image/jpeg") == false)
        #expect(UploadPreparation.needsJPEGConversion(contentType: "image/png") == false)
    }

    @Test("转码后文件名换扩展名")
    func jpegFilename() {
        #expect(UploadPreparation.jpegFilename(from: "IMG_0001.HEIC") == "IMG_0001.jpg")
        #expect(UploadPreparation.jpegFilename(from: "no-extension") == "no-extension.jpg")
        #expect(UploadPreparation.jpegFilename(from: ".heic") == ".heic.jpg")
    }

    @Test("空数据不成候选（避免把 0 字节 PUT 上去）")
    func emptyDataRejected() {
        #expect(UploadPreparation.candidate(from: Data(), filename: "a.jpg", contentType: "image/jpeg") == nil)
    }

    @Test("JPEG 原样保留字节与文件名（不做无谓重编码）")
    func jpegPassThrough() throws {
        let data = Data(repeating: 1, count: 128)
        let candidate = try #require(UploadPreparation.candidate(from: data, filename: "a.JPG", contentType: "image/jpeg"))
        #expect(candidate.data == data)
        #expect(candidate.filename == "a.JPG")
        #expect(candidate.contentType == "image/jpeg")
    }
}

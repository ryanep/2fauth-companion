import Foundation
import ImageIO

#if canImport(UIKit)
    import UIKit
#endif

struct AccountIconRasterProcessor: Sendable {
    let policy: AccountIconCachePolicy

    func isSVGData(_ data: Data, from url: URL) -> Bool {
        if isRasterImageData(data) {
            return false
        }

        if url.pathExtension.localizedLowercase == "svg" {
            return true
        }

        let prefix = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return prefix.hasPrefix("<svg") || prefix.hasPrefix("<?xml") && prefix.contains("<svg")
    }

    func isRasterImageData(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || data.starts(with: [0xFF, 0xD8, 0xFF])
            || data.starts(with: [0x47, 0x49, 0x46, 0x38])
            || data.starts(with: [0x52, 0x49, 0x46, 0x46]) && data.dropFirst(8).starts(with: [0x57, 0x45, 0x42, 0x50])
    }

    func hasValidRasterMetadata(_ data: Data) -> Bool {
        guard isRasterImageData(data),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return false
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
            && width > 0
            && height > 0
            && width <= policy.maximumSourceDimension
            && height <= policy.maximumSourceDimension
            && width <= policy.maximumSourcePixels / height
    }

    func hasVisibleRasterContent(_ data: Data) -> Bool {
        #if canImport(UIKit)
            guard let image = UIImage(data: data), let cgImage = image.cgImage else {
                return false
            }

            let width = cgImage.width
            let height = cgImage.height
            guard width > 0, height > 0 else {
                return false
            }

            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            guard
                let context = CGContext(
                    data: &pixels,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else {
                return false
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 0 {
                return true
            }
            return false
        #else
            return true
        #endif
    }

    func normalizedRasterData(_ data: Data) -> Data? {
        #if canImport(UIKit)
            guard !data.isEmpty, data.count <= policy.maximumSourceBytes,
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                width > 0,
                height > 0,
                width <= policy.maximumSourceDimension,
                height <= policy.maximumSourceDimension,
                width <= policy.maximumSourcePixels / height,
                let image = UIImage(data: data),
                image.cgImage != nil
            else {
                return nil
            }

            let target = CGFloat(policy.normalizedDimension)
            let scale = min(target / image.size.width, target / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let drawOrigin = CGPoint(x: (target - drawSize.width) / 2, y: (target - drawSize.height) / 2)
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = 1
            return UIGraphicsImageRenderer(
                size: CGSize(width: target, height: target),
                format: format
            ).pngData { _ in
                image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
            }
        #else
            return data
        #endif
    }
}

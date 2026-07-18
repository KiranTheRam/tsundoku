import CoreGraphics
import ImageIO
import UIKit

enum ImageProcessor {
    static func thumbnail(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    static func image(from data: Data, segment: PageSegment, cropPolicy: CropPolicy) -> UIImage? {
        guard let source = UIImage(data: data), let cgImage = source.cgImage else { return nil }
        var rect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        if cropPolicy == .automatic, let detected = detectedContentRect(in: cgImage) { rect = detected }
        let segmentRect = CGRect(
            x: rect.minX + rect.width * segment.normalizedCrop.minX,
            y: rect.minY + rect.height * segment.normalizedCrop.minY,
            width: rect.width * segment.normalizedCrop.width,
            height: rect.height * segment.normalizedCrop.height
        ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let cropped = cgImage.cropping(to: segmentRect) else { return source }
        return UIImage(cgImage: cropped, scale: source.scale, orientation: source.imageOrientation)
    }

    private static func detectedContentRect(in image: CGImage) -> CGRect? {
        let sampleWidth = min(image.width, 256)
        let sampleHeight = min(image.height, 384)
        let bytesPerRow = sampleWidth * 4
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
        guard let context = CGContext(data: &pixels, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        let corners = [(0, 0), (sampleWidth - 1, 0), (0, sampleHeight - 1), (sampleWidth - 1, sampleHeight - 1)]
        let samples = corners.map { point in
            pixel(pixels, x: point.0, y: point.1, bytesPerRow: bytesPerRow)
        }
        var red = 0
        var green = 0
        var blue = 0
        for sample in samples {
            red += sample.0
            green += sample.1
            blue += sample.2
        }
        let base: (Int, Int, Int) = (red / samples.count, green / samples.count, blue / samples.count)
        func rowHasContent(_ y: Int) -> Bool { stride(from: 0, to: sampleWidth, by: 3).contains { different(pixel(pixels, x: $0, y: y, bytesPerRow: bytesPerRow), base) } }
        func columnHasContent(_ x: Int) -> Bool { stride(from: 0, to: sampleHeight, by: 3).contains { different(pixel(pixels, x: x, y: $0, bytesPerRow: bytesPerRow), base) } }
        guard let top = (0..<sampleHeight).first(where: rowHasContent),
              let bottom = (0..<sampleHeight).reversed().first(where: rowHasContent),
              let left = (0..<sampleWidth).first(where: columnHasContent),
              let right = (0..<sampleWidth).reversed().first(where: columnHasContent) else { return nil }
        let scaleX = CGFloat(image.width) / CGFloat(sampleWidth)
        let scaleY = CGFloat(image.height) / CGFloat(sampleHeight)
        let rect = CGRect(x: CGFloat(left) * scaleX, y: CGFloat(top) * scaleY, width: CGFloat(right - left + 1) * scaleX, height: CGFloat(bottom - top + 1) * scaleY)
        guard rect.width < CGFloat(image.width) * 0.99 || rect.height < CGFloat(image.height) * 0.99 else { return nil }
        return rect.insetBy(dx: -4, dy: -4).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    private static func pixel(_ bytes: [UInt8], x: Int, y: Int, bytesPerRow: Int) -> (Int, Int, Int) {
        let offset = y * bytesPerRow + x * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private static func different(_ pixel: (Int, Int, Int), _ base: (Int, Int, Int)) -> Bool {
        abs(pixel.0 - base.0) + abs(pixel.1 - base.1) + abs(pixel.2 - base.2) > 72
    }
}

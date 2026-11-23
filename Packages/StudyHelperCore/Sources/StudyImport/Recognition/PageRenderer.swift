import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PDFKit
import StudyCore
import UniformTypeIdentifiers

/// Renders PDF pages to images and encodes images for storage.
public enum PageRenderer {
    /// Size of a page in points (media box, rotation applied: 90/270° swap width and height).
    public static func pageSize(of page: PDFPage) -> PageSize {
        let box = page.bounds(for: .mediaBox)
        let swapped = page.rotation % 180 != 0
        return PageSize(width: swapped ? box.height : box.width, height: swapped ? box.width : box.height)
    }

    /// Largest side of an image the pipeline renders, in pixels.
    public static let maxSide = 12_000.0
    /// Largest pixel count of a rendered image.
    public static let maxPixels = 60_000_000.0

    /// `scale` reduced so that neither side exceeds `maxSide` and the image has at most `maxPixels` pixels.
    public static func clampedScale(_ scale: Double, for size: PageSize) -> Double {
        guard scale > 0, scale.isFinite, size.width > 0, size.height > 0 else { return scale }
        var result = scale
        result = min(result, maxSide / max(size.width, size.height))
        result = min(result, (maxPixels / (size.width * size.height)).squareRoot())
        return result
    }

    /// Renders a page on white at `scale` pixels per point. With `includeAnnotations: false` the page's
    /// annotations (Goodnotes strokes, text boxes, shapes) are left out and only the page content is drawn.
    /// Returns nil if the page is empty or the bitmap cannot be created.
    public static func render(page: PDFPage, scale: Double, includeAnnotations: Bool = true) -> CGImage? {
        let size = pageSize(of: page)
        guard scale > 0, scale.isFinite else { return nil }
        let scale = clampedScale(scale, for: size)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)

        // PDFPage.draw(with:to:) draws annotations (appearance streams) unless the page is told not to.
        let previous = page.displaysAnnotations
        page.displaysAnnotations = includeAnnotations
        defer { page.displaysAnnotations = previous }

        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// Decodes image data (JPEG, HEIC, PNG, ...) and reads its EXIF/TIFF orientation. The pixels are returned as
    /// stored; pass both to `upright(_:orientation:)` (or `DigitizationPipeline.digitizeImage`).
    public static func decodeImage(data: Data) -> (image: CGImage, orientation: CGImagePropertyOrientation)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (image, CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }

    /// The image with its pixels turned (and mirrored) so that it is displayed upright, as camera photos with an
    /// orientation tag need. Returns `image` unchanged for `.up`.
    public static func upright(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return image }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.createCGImage(oriented, from: oriented.extent, format: .RGBA8, colorSpace: space) ?? image
    }

    /// JPEG data (e.g. for the stored page image).
    public static func jpegData(from image: CGImage, quality: Double = 0.85) -> Data? {
        encode(image, type: UTType.jpeg, quality: quality)
    }

    /// PNG data (lossless).
    public static func pngData(from image: CGImage) -> Data? {
        encode(image, type: UTType.png, quality: nil)
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A copy of `image` scaled by `factor` (used for the second pass of multi-pass recognition).
    public static func scaled(_ image: CGImage, by factor: Double) -> CGImage? {
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

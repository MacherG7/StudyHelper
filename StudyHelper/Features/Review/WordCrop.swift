import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import StudyCore
import StudyImport
import UIKit

/// Cuts one word (its band of the page plus a small margin) out of the original and renders it sharp: photos are
/// cropped from the stored image and scaled up if needed, PDF pages are drawn again at a scale that gives the crop
/// enough pixels (no blurry enlargement of a low-resolution page image).
nonisolated enum WordCrop {
    /// Pixel width the crop should have at least (about 3× the width of the picture on a phone).
    static let targetPixelWidth = 1_000
    /// Largest enlargement of a photo crop (beyond that more pixels add nothing).
    static let maximumUpscale = 4.0
    /// Largest scale (pixels per point) for PDF pages.
    static let maximumPDFScale = 12.0
    /// Margin around the word, as a fraction of the word band's height.
    static let marginFactor = 0.35

    /// The area to show: the band with its margin on every side, as a fraction of the page.
    static func region(band: NormalizedRect, pageAspect: Double) -> NormalizedRect {
        guard !band.isEmpty, pageAspect > 0 else { return band }
        // Margin in page fractions: vertical from the band's height, horizontal the same distance in points.
        let marginY = band.height * marginFactor
        let marginX = marginY / pageAspect
        let x0 = max(0, band.minX - marginX), y0 = max(0, band.minY - marginY)
        let x1 = min(1, band.maxX + marginX), y1 = min(1, band.maxY + marginY)
        return NormalizedRect(x: x0, y: y0, width: max(x1 - x0, 0), height: max(y1 - y0, 0))
    }

    @concurrent
    static func image(background: DigitalPageInput.Background, band: NormalizedRect) async -> UIImage? {
        switch background {
        case .image(let data): return photoCrop(data: data, band: band)
        case .pdf(let data, let pageIndex, _): return pdfCrop(data: data, pageIndex: pageIndex, band: band)
        }
    }

    static func photoCrop(data: Data, band: NormalizedRect, targetWidth: Int = targetPixelWidth) -> UIImage? {
        guard let decoded = PageRenderer.decodeImage(data: data) else { return nil }
        let image = PageRenderer.upright(decoded.image, orientation: decoded.orientation)
        let width = Double(image.width), height = Double(image.height)
        guard width > 0, height > 0 else { return nil }
        let area = region(band: band, pageAspect: width / height)
        let rect = CGRect(
            x: area.x * width, y: area.y * height, width: area.width * width, height: area.height * height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 2, rect.height >= 2, let cropped = image.cropping(to: rect) else { return nil }
        let factor = min(max(Double(targetWidth) / rect.width, 1), maximumUpscale)
        guard factor > 1.01 else { return UIImage(cgImage: cropped) }
        let outWidth = Int((rect.width * factor).rounded()), outHeight = Int((rect.height * factor).rounded())
        guard let context = CGContext(
            data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return UIImage(cgImage: cropped) }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        return context.makeImage().map { UIImage(cgImage: $0) } ?? UIImage(cgImage: cropped)
    }

    static func pdfCrop(data: Data, pageIndex: Int, band: NormalizedRect, targetWidth: Int = targetPixelWidth) -> UIImage? {
        guard let document = PDFDocument(data: data), pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { return nil }
        let size = PageRenderer.pageSize(of: page)
        guard size.width > 0, size.height > 0 else { return nil }
        let area = region(band: band, pageAspect: size.width / size.height)
        // The crop in page points, origin top left.
        let cropX = area.x * size.width, cropY = area.y * size.height
        let cropWidth = area.width * size.width, cropHeight = area.height * size.height
        guard cropWidth >= 1, cropHeight >= 1 else { return nil }
        let scale = min(max(Double(targetWidth) / cropWidth, 1), maximumPDFScale)
        let outWidth = Int((cropWidth * scale).rounded()), outHeight = Int((cropHeight * scale).rounded())
        guard outWidth > 0, outHeight > 0, outWidth * outHeight < 40_000_000,
              let context = CGContext(
                data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        context.scaleBy(x: scale, y: scale)
        // PDF space has its origin at the bottom left of the page.
        context.translateBy(x: -cropX, y: -(size.height - cropY - cropHeight))
        page.draw(with: .mediaBox, to: context)
        return context.makeImage().map { UIImage(cgImage: $0) }
    }
}

import CoreGraphics
import Foundation
import StudyCore

/// Pen color clustering and the per-color ink layer rendering behind `InkLayerRenderer`.
enum InkLayerRendering {
    /// Two pen colors closer than this (Euclidean distance in RGB, 0…√3) are the same layer.
    /// Goodnotes pens of one color are identical; the tolerance only absorbs rounding and gray-vs-RGB noise,
    /// while distinct pen colors (black, red, blue, green, …) are at least ~0.5 apart.
    static let clusterThreshold = 0.12

    struct Cluster {
        var representative: RGBColor
        var strokeIndices: [Int]
    }

    /// Clusters the pen strokes (highlighters excluded) by color; order = first occurrence on the page.
    static func clusters(of page: GoodnotesPage) -> [Cluster] {
        var clusters: [Cluster] = []
        let highlighters = page.highlighterFlags
        for (index, stroke) in page.strokes.enumerated() where !highlighters[index] {
            if let i = clusters.firstIndex(where: { $0.representative.distance(to: stroke.color) < clusterThreshold }) {
                clusters[i].strokeIndices.append(index)
            } else {
                clusters.append(Cluster(representative: stroke.color, strokeIndices: [index]))
            }
        }
        return clusters
    }

    static func render(page: GoodnotesPage, color: RGBColor, scale: Double) -> CGImage? {
        guard scale > 0, scale.isFinite, page.size.width > 0, page.size.height > 0 else { return nil }
        // An oversized page or scale is clamped instead of failing; normalized coordinates stay valid.
        let scale = PageRenderer.clampedScale(scale, for: page.size)
        let width = Int((page.size.width * scale).rounded(.up))
        let height = Int((page.size.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        let highlighters = page.highlighterFlags

        // Which strokes belong to the layer: the cluster nearest to `color`, if it is close enough.
        let clusters = clusters(of: page)
        var selected: [Int]
        if let nearest = clusters.min(by: { $0.representative.distance(to: color) < $1.representative.distance(to: color) }),
           nearest.representative.distance(to: color) < clusterThreshold {
            selected = nearest.strokeIndices
        } else {
            selected = page.strokes.indices.filter {
                !highlighters[$0] && page.strokes[$0].color.distance(to: color) < clusterThreshold
            }
        }

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // PDF user space (origin bottom-left, points) maps straight onto the bitmap (origin bottom-left).
        context.scaleBy(x: Double(width) / page.size.width, y: Double(height) / page.size.height)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setFillColor(gray: 0, alpha: 1)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for index in selected {
            let stroke = page.strokes[index]
            guard let first = stroke.points.first else { continue }
            let lineWidth = max(stroke.width, 0.25)
            if stroke.points.count == 1 {
                let r = lineWidth / 2
                context.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: lineWidth, height: lineWidth))
                continue
            }
            context.setLineWidth(lineWidth)
            context.beginPath()
            context.move(to: CGPoint(x: first.x, y: first.y))
            for p in stroke.points.dropFirst() { context.addLine(to: CGPoint(x: p.x, y: p.y)) }
            context.strokePath()
        }
        return context.makeImage()
    }
}

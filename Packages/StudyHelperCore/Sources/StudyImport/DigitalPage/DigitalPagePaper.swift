import CoreGraphics
import Foundation
import StudyCore

/// Hides handwriting that cannot be left out (photos, scans, flattened PDFs) by painting it in the paper color.
///
/// Per line, only the ink inside the (padded) line area is painted: pixels clearly darker than the paper around the
/// area (median of a thin ring; highlighter and ruled lines are lighter than any pen). When the line's ink is colored,
/// only ink of that color counts (a black circle around a blue word stays). Each ink pixel takes the color
/// interpolated between the nearest non-ink pixels left and right of it in its row, so that highlighter, lined paper
/// and colored paper show through. Ink that runs through the whole area (underlines, table and frame lines crossing
/// the line) is kept, and so are thin horizontal bars such as a short underline below one word (`isHorizontalLine`).
enum DigitalPagePaper {
    /// Padding of the painted area in line heights (ascenders, descenders and pen width reach beyond Vision's boxes).
    static let horizontalPadding = 0.25
    static let verticalPadding = 0.2
    /// Thickness of the sampled ring in line heights (at least 2 pixels).
    static let ringThickness = 0.15
    /// At most this many ring pixels are sampled per line.
    static let maximumSamples = 4000
    /// A pixel is ink if it is this much darker than the paper (luma, 0…1).
    static let inkLuma = 0.35
    /// Ink whose median has at least this spread between its channels is colored.
    static let coloredSpread = 0.2
    /// Colored ink: a pixel belongs to it if it lies this close to the line from paper to ink color (RGB distance).
    static let colorTolerance = 0.25
    /// Ink runs at least this long (share of the area's width or height) are lines, not writing, and are kept.
    static let horizontalLineShare = 0.6
    static let verticalLineShare = 0.9
    /// Shorter horizontal lines (`isHorizontalLine`), in line heights: long-ish runs up to `lineThickness` thick, and
    /// thin bars (short underlines) from `thinBarLength` long.
    static let longLineHeights = 1.5
    static let lineThickness = 0.25
    static let thinBarThickness = 0.15
    static let thinBarLength = 0.6
    /// The ink mask grows by this share of the line height (at least 1 pixel) to catch anti-aliased edges.
    static let growth = 0.04

    struct RGB {
        var r: Double, g: Double, b: Double
        var luma: Double { 0.299 * r + 0.587 * g + 0.114 * b }
        func distance(to o: RGB) -> Double { ((r - o.r) * (r - o.r) + (g - o.g) * (g - o.g) + (b - o.b) * (b - o.b)).squareRoot() }
    }

    /// Removes the ink of `lines` from the rendered page in `bitmap`. Paper colors are taken before anything changes.
    static func paint(over lines: [RecognizedLine], in bitmap: Bitmap, size: PageSize) {
        guard let data = bitmap.context.data else { return }
        let bytesPerRow = bitmap.context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * bitmap.height)
        let image = Image(pixels: pixels, width: bitmap.width, height: bitmap.height, bytesPerRow: bytesPerRow)
        let sx = bitmap.scale, sy = bitmap.scale
        let areas: [CGRect] = lines.map { line in
            let r = paddedRect(line.rect, size: size)
            return CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
        }
        let papers = areas.map { paperColor(around: $0, image: image) }
        for ((area, paper), line) in zip(zip(areas, papers), lines) {
            let lineHeight = line.rect.height * size.height * sy
            let box = CGRect(x: line.rect.x * size.width * sx, y: line.rect.y * size.height * sy,
                             width: line.rect.width * size.width * sx, height: lineHeight)
            let ink = inkColor(in: box, paper: paper, image: image)
            removeInk(in: area, paper: paper, ink: ink, lineHeight: lineHeight, image: image)
        }
    }

    /// The line rect grown by the padding, in page units with origin top-left.
    static func paddedRect(_ rect: NormalizedRect, size: PageSize) -> CGRect {
        let r = CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.width * size.width,
                       height: rect.height * size.height)
        return r.insetBy(dx: -horizontalPadding * r.height, dy: -verticalPadding * r.height)
    }

    /// RGBA pixels, row 0 at the top.
    struct Image {
        let pixels: UnsafeMutablePointer<UInt8>
        let width: Int
        let height: Int
        let bytesPerRow: Int

        func color(_ x: Int, _ y: Int) -> RGB {
            let o = y * bytesPerRow + x * 4
            return RGB(r: Double(pixels[o]) / 255, g: Double(pixels[o + 1]) / 255, b: Double(pixels[o + 2]) / 255)
        }

        func set(_ x: Int, _ y: Int, _ c: RGB) {
            let o = y * bytesPerRow + x * 4
            pixels[o] = UInt8((min(1, max(0, c.r)) * 255).rounded())
            pixels[o + 1] = UInt8((min(1, max(0, c.g)) * 255).rounded())
            pixels[o + 2] = UInt8((min(1, max(0, c.b)) * 255).rounded())
        }

        /// Pixel bounds of `rect` (pixels, origin top-left) clamped to the image.
        func bounds(_ rect: CGRect) -> (x: Range<Int>, y: Range<Int>) {
            let x0 = max(0, Int(rect.minX.rounded(.down))), x1 = min(width, Int(rect.maxX.rounded(.up)))
            let y0 = max(0, Int(rect.minY.rounded(.down))), y1 = min(height, Int(rect.maxY.rounded(.up)))
            return (x0..<max(x0, x1), y0..<max(y0, y1))
        }
    }

    /// Per-channel median of the ring around `area` (pixels, origin top-left); white if nothing can be sampled.
    static func paperColor(around area: CGRect, image: Image) -> RGB {
        let thickness = max(2, ringThickness * area.height)
        let outer = image.bounds(area.insetBy(dx: -thickness, dy: -thickness))
        let ringArea = Double(outer.x.count * outer.y.count) - Double(area.width * area.height)
        let step = max(1, Int((max(1, ringArea) / Double(maximumSamples)).squareRoot().rounded(.up)))
        var red: [Double] = [], green: [Double] = [], blue: [Double] = []
        for y in stride(from: outer.y.lowerBound, to: outer.y.upperBound, by: step) {
            for x in stride(from: outer.x.lowerBound, to: outer.x.upperBound, by: step) {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                if px > area.minX, px < area.maxX, py > area.minY, py < area.maxY { continue }
                let c = image.color(x, y)
                red.append(c.r); green.append(c.g); blue.append(c.b)
            }
        }
        guard !red.isEmpty else { return RGB(r: 1, g: 1, b: 1) }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return RGB(r: median(red), g: median(green), b: median(blue))
    }

    static func isInk(_ c: RGB, paper: RGB) -> Bool {
        paper.luma - c.luma >= inkLuma
    }

    /// The colored ink of the line (median of its ink pixels), nil for black or gray ink or if there is none.
    static func inkColor(in box: CGRect, paper: RGB, image: Image) -> RGB? {
        let bounds = image.bounds(box)
        var red: [Double] = [], green: [Double] = [], blue: [Double] = []
        for y in bounds.y {
            for x in bounds.x {
                let c = image.color(x, y)
                if isInk(c, paper: paper) { red.append(c.r); green.append(c.g); blue.append(c.b) }
            }
        }
        guard !red.isEmpty else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let ink = RGB(r: median(red), g: median(green), b: median(blue))
        return max(ink.r, ink.g, ink.b) - min(ink.r, ink.g, ink.b) >= coloredSpread ? ink : nil
    }

    /// Ink of the line's own color: close to the straight line from the paper color to the ink color.
    static func isWriting(_ c: RGB, paper: RGB, ink: RGB?) -> Bool {
        guard isInk(c, paper: paper) else { return false }
        guard let ink else { return true }
        let d = (ink.r - paper.r, ink.g - paper.g, ink.b - paper.b)
        let v = (c.r - paper.r, c.g - paper.g, c.b - paper.b)
        let length = d.0 * d.0 + d.1 * d.1 + d.2 * d.2
        guard length > 0 else { return true }
        let t = (v.0 * d.0 + v.1 * d.1 + v.2 * d.2) / length
        let e = ((v.0 - t * d.0) * (v.0 - t * d.0) + (v.1 - t * d.1) * (v.1 - t * d.1) + (v.2 - t * d.2) * (v.2 - t * d.2)).squareRoot()
        return t > 0 && e <= colorTolerance
    }

    /// A horizontal ink run (pixels) belongs to a line (rule, underline), not to writing:
    /// - it spans `horizontalLineShare` of the area (rules and long underlines, any thickness), or
    /// - it is long-ish (`longLineHeights` line heights, or `horizontalLineShare` of a narrow area) and not thicker
    ///   than `lineThickness` line heights, or
    /// - it is a thin bar (at most `thinBarThickness` line heights thick) at least 3 times as long as thick and at
    ///   least `thinBarLength` line heights long (shorter bars are hyphens and t-bars).
    /// `thickness` (vertical extent in pixels) is only evaluated when needed.
    static func isHorizontalLine(
        length: Int, areaWidth: Int, lineHeight: Double, thickness: () -> Double
    ) -> Bool {
        let length = Double(length), width = Double(areaWidth)
        if length >= max(2, (horizontalLineShare * width).rounded(.down)) { return true }
        guard length >= thinBarLength * lineHeight || length >= min(horizontalLineShare * width, longLineHeights * lineHeight)
        else { return false }
        let t = thickness()
        if length >= min(horizontalLineShare * width, longLineHeights * lineHeight), t <= lineThickness * lineHeight {
            return true
        }
        return t <= max(1, thinBarThickness * lineHeight) && length >= 3 * t && length >= thinBarLength * lineHeight
    }

    /// Replaces the ink pixels inside `area` by the background interpolated along their row.
    static func removeInk(in area: CGRect, paper: RGB, ink inkColor: RGB?, lineHeight: Double, image: Image) {
        let bounds = image.bounds(area)
        let w = bounds.x.count, h = bounds.y.count
        guard w > 0, h > 0 else { return }
        let x0 = bounds.x.lowerBound, y0 = bounds.y.lowerBound
        var ink = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where isWriting(image.color(x0 + x, y0 + y), paper: paper, ink: inkColor) { ink[y * w + x] = true }
        }
        // Lines through the area (rules, underlines, frames) are kept, and thin horizontal bars such as a short
        // underline below a single word.
        var keep = [Bool](repeating: false, count: w * h)
        /// Vertical extent of the ink through (x, y), in pixels.
        func thickness(_ x: Int, _ y: Int) -> Int {
            var top = y, bottom = y
            while top > 0, ink[(top - 1) * w + x] { top -= 1 }
            while bottom < h - 1, ink[(bottom + 1) * w + x] { bottom += 1 }
            return bottom - top + 1
        }
        for y in 0..<h {
            var x = 0
            while x < w {
                guard ink[y * w + x] else { x += 1; continue }
                let start = x
                while x < w, ink[y * w + x] { x += 1 }
                if isHorizontalLine(length: x - start, areaWidth: w, lineHeight: lineHeight, thickness: {
                    // Median thickness over up to 16 columns (letters crossing the bar do not count).
                    let step = max(1, (x - start) / 16)
                    let values = stride(from: start, to: x, by: step).map { thickness($0, y) }.sorted()
                    return Double(values[values.count / 2])
                }) {
                    for k in start..<x { keep[y * w + k] = true }
                }
            }
        }
        let minimumColumn = max(2, Int(verticalLineShare * Double(h)))
        for x in 0..<w {
            var y = 0
            while y < h {
                guard ink[y * w + x] else { y += 1; continue }
                let start = y
                while y < h, ink[y * w + x] { y += 1 }
                if y - start >= minimumColumn { for k in start..<y { keep[k * w + x] = true } }
            }
        }
        // Writing = ink that is not kept, grown a little (anti-aliased edges), separably: rows, then columns.
        let grow = max(1, Int((growth * lineHeight).rounded()))
        var rows = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where ink[y * w + x] && !keep[y * w + x] {
                for xx in max(0, x - grow)...min(w - 1, x + grow) { rows[y * w + xx] = true }
            }
        }
        var writing = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where rows[y * w + x] {
                for yy in max(0, y - grow)...min(h - 1, y + grow) where !keep[yy * w + x] { writing[yy * w + x] = true }
            }
        }
        // Background next to a run: the pixel beyond it (inside or just outside the area); ink there counts as paper.
        func background(_ x: Int, _ y: Int) -> RGB? {
            guard x >= 0, x < image.width else { return nil }
            let c = image.color(x, y)
            return isInk(c, paper: paper) ? paper : c
        }
        for y in 0..<h {
            var x = 0
            while x < w {
                guard writing[y * w + x] else { x += 1; continue }
                let start = x
                while x < w, writing[y * w + x] { x += 1 }
                let left = background(x0 + start - 1, y0 + y), right = background(x0 + x, y0 + y)
                let a = left ?? right ?? paper, b = right ?? left ?? paper
                let count = Double(x - start + 1)
                for k in start..<x {
                    let t = Double(k - start + 1) / count
                    image.set(x0 + k, y0 + y, RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t))
                }
            }
        }
    }
}

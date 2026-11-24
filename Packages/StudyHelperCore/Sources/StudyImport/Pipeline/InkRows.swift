import CoreGraphics
import Foundation

/// Geometry of handwritten text rows: which strokes sit on one row of writing, and where a row falls apart
/// into separate pieces. Works on stroke bounding boxes in page points with the origin top-left.
///
/// Rows are found by a projection of the boxes onto the vertical axis. Only the middle of each box is
/// projected (ascenders, descenders and tall strokes would otherwise bridge neighbouring rows of dense
/// handwriting); small leftovers (i-dots, accents) are joined to the nearest row.
enum InkRows {
    /// Each box contributes its middle half to the projection, at most this tall (in line heights).
    static let maxBandHalfHeight = 0.3
    /// Projections closer than this (in line heights) are one row.
    static let touchGap = 0.05
    /// A row band thinner than this (in line heights) is a leftover (dot, accent) …
    static let thinBand = 0.2
    /// … and joins the neighbouring row if that is at most this close (in line heights).
    static let joinGap = 0.4
    /// Pieces of a row further apart than this (in line heights) are separate segments.
    static let segmentGap = 2.0

    /// A row: its member boxes (indices) and the vertical extent of its projection (page points, top-left origin).
    struct Row {
        var members: [Int]
        var lo: Double
        var hi: Double
    }

    /// Indices of `boxes` grouped into rows, top to bottom.
    static func rows(of boxes: [CGRect], lineHeight: Double) -> [[Int]] {
        bands(of: boxes, lineHeight: lineHeight).map(\.members)
    }

    /// Rows with their projection extent, top to bottom.
    static func bands(of boxes: [CGRect], lineHeight: Double) -> [Row] {
        guard !boxes.isEmpty else { return [] }
        let h = max(1, lineHeight)
        typealias Band = Row
        let items: [(index: Int, lo: Double, hi: Double)] = boxes.indices.map { index in
            let box = boxes[index]
            let half = min(0.25 * box.height, maxBandHalfHeight * h)
            return (index, box.midY - half, box.midY + half)
        }.sorted { $0.lo < $1.lo }

        var bands: [Band] = []
        for item in items {
            if var last = bands.last, item.lo <= last.hi + touchGap * h {
                last.hi = max(last.hi, item.hi)
                last.members.append(item.index)
                bands[bands.count - 1] = last
            } else {
                bands.append(Band(members: [item.index], lo: item.lo, hi: item.hi))
            }
        }

        // Leftovers (thin bands) join the nearest band if it is close enough.
        var changed = true
        while changed, bands.count > 1 {
            changed = false
            for i in bands.indices where bands[i].hi - bands[i].lo < thinBand * h {
                let above = i > 0 ? bands[i].lo - bands[i - 1].hi : Double.infinity
                let below = i + 1 < bands.count ? bands[i + 1].lo - bands[i].hi : Double.infinity
                let target: Int
                if above <= below, above <= joinGap * h { target = i - 1 }
                else if below <= joinGap * h { target = i + 1 }
                else { continue }
                bands[target].lo = min(bands[target].lo, bands[i].lo)
                bands[target].hi = max(bands[target].hi, bands[i].hi)
                bands[target].members += bands[i].members
                bands.remove(at: i)
                changed = true
                break
            }
        }
        return bands.flatMap { splitTall($0, boxes: boxes, lineHeight: h) }
    }

    /// A projection that is taller than this (in line heights) may hold several tightly packed rows.
    static let tallBand = 1.3
    /// A valley splits it if its depth is below this share of the lower neighbouring peak …
    static let valleyDepth = 0.4
    /// … and each side keeps at least this height (in line heights).
    static let minimumSide = 0.3

    /// Splits a projection band that is too tall for one row at the deepest valley of the ink profile (rows of
    /// small writing are packed closer than the page's typical line height), recursively.
    private static func splitTall(_ row: Row, boxes: [CGRect], lineHeight h: Double) -> [Row] {
        guard row.hi - row.lo > tallBand * h, row.members.count >= 4 else { return [row] }
        let bin = max(0.5, h / 20)
        let count = Int(((row.hi - row.lo) / bin).rounded(.up)) + 1
        var profile = [Double](repeating: 0, count: count)
        for index in row.members {
            let box = boxes[index]
            let half = min(0.25 * box.height, maxBandHalfHeight * h)
            let weight = max(1, min(box.width, h))
            let from = max(0, Int(((box.midY - half - row.lo) / bin).rounded(.down)))
            let to = min(count - 1, Int(((box.midY + half - row.lo) / bin).rounded(.up)))
            if from <= to { for b in from...to { profile[b] += weight } }
        }
        // Moving average over about a tenth of a line height on each side.
        let radius = max(1, Int((h / 10 / bin).rounded()))
        let smooth = profile.indices.map { i -> Double in
            let lo = max(0, i - radius), hi = min(count - 1, i + radius)
            return profile[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        let side = Int((minimumSide * h / bin).rounded(.up))
        guard count > 2 * side + 1 else { return [row] }
        var best: (index: Int, ratio: Double)?
        for i in side..<(count - side) {
            let left = smooth[..<i].max() ?? 0, right = smooth[(i + 1)...].max() ?? 0
            let peak = min(left, right)
            guard peak > 0 else { continue }
            let ratio = smooth[i] / peak
            if ratio < valleyDepth, ratio < (best?.ratio ?? .infinity) { best = (i, ratio) }
        }
        guard let split = best else { return [row] }
        let cut = row.lo + (Double(split.index) + 0.5) * bin
        let upper = row.members.filter { boxes[$0].midY < cut }, lower = row.members.filter { boxes[$0].midY >= cut }
        guard !upper.isEmpty, !lower.isEmpty else { return [row] }
        func extent(_ members: [Int], fallback: (Double, Double)) -> (Double, Double) {
            let bands = members.map { index -> (Double, Double) in
                let box = boxes[index]
                let half = min(0.25 * box.height, maxBandHalfHeight * h)
                return (box.midY - half, box.midY + half)
            }
            return (bands.map(\.0).min() ?? fallback.0, bands.map(\.1).max() ?? fallback.1)
        }
        let a = extent(upper, fallback: (row.lo, cut)), b = extent(lower, fallback: (cut, row.hi))
        return splitTall(Row(members: upper, lo: a.0, hi: a.1), boxes: boxes, lineHeight: h)
            + splitTall(Row(members: lower, lo: b.0, hi: b.1), boxes: boxes, lineHeight: h)
    }

    /// Splits the strokes of one row (`indices` into `boxes`) into horizontal segments: pieces separated by
    /// a gap of more than `segmentGap` line heights. Each segment is sorted left to right.
    static func segments(of indices: [Int], boxes: [CGRect], lineHeight: Double) -> [[Int]] {
        let sorted = indices.sorted { boxes[$0].minX < boxes[$1].minX }
        guard let first = sorted.first else { return [] }
        var result: [[Int]] = [[first]]
        var maxX = boxes[first].maxX
        for index in sorted.dropFirst() {
            if boxes[index].minX - maxX > segmentGap * max(1, lineHeight) {
                result.append([index])
            } else {
                result[result.count - 1].append(index)
            }
            maxX = max(maxX, boxes[index].maxX)
        }
        return result
    }

    /// Union of the boxes.
    static func union(of indices: [Int], boxes: [CGRect]) -> CGRect {
        indices.dropFirst().reduce(boxes[indices[0]]) { $0.union(boxes[$1]) }
    }

    /// Number of rows that carry real writing (a row needs a width of one line height and a height of 0.4);
    /// used to tell a recognized line that swallowed two rows.
    static func substantialRowCount(of boxes: [CGRect], lineHeight: Double) -> Int {
        let h = max(1, lineHeight)
        return rows(of: boxes, lineHeight: lineHeight).filter { row in
            let box = union(of: row, boxes: boxes)
            return box.width >= h && box.height >= 0.4 * h
        }.count
    }
}

import Foundation

/// A rectangle in normalized page coordinates.
///
/// Convention used throughout StudyHelper: values are fractions of the page
/// (0…1), **origin top-left**, y grows downwards (like SwiftUI). Converters
/// for bottom-left coordinate systems (PDF user space, Vision) are provided.
public struct NormalizedRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = NormalizedRect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Creates a normalized rect from a rect in a bottom-left coordinate space
    /// (PDF user space in points, or Vision's normalized space with size 1×1).
    public static func fromBottomLeft(
        x: Double, y: Double, width: Double, height: Double,
        spaceWidth: Double, spaceHeight: Double
    ) -> NormalizedRect {
        guard spaceWidth > 0, spaceHeight > 0 else { return .zero }
        return NormalizedRect(
            x: x / spaceWidth,
            y: 1 - (y + height) / spaceHeight,
            width: width / spaceWidth,
            height: height / spaceHeight
        )
    }

    /// Converts back into a bottom-left space of the given size: (x, y, width, height).
    public func toBottomLeft(spaceWidth: Double, spaceHeight: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        (x * spaceWidth, (1 - maxY) * spaceHeight, width * spaceWidth, height * spaceHeight)
    }

    public func intersection(_ other: NormalizedRect) -> NormalizedRect {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return .zero }
        return NormalizedRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func union(_ other: NormalizedRect) -> NormalizedRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        let x1 = max(maxX, other.maxX), y1 = max(maxY, other.maxY)
        return NormalizedRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Intersection over union, 0…1.
    public func iou(_ other: NormalizedRect) -> Double {
        let inter = intersection(other).area
        let unionArea = area + other.area - inter
        return unionArea > 0 ? inter / unionArea : 0
    }

    /// Fraction of *this* rect's area covered by `other`, 0…1.
    public func coverage(by other: NormalizedRect) -> Double {
        area > 0 ? intersection(other).area / area : 0
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= minX && px <= maxX && py >= minY && py <= maxY
    }

    public func insetBy(dx: Double, dy: Double) -> NormalizedRect {
        NormalizedRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }
}

/// Size of a page or image in its native unit (PDF points or pixels).
public struct PageSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// True if both dimensions match within `tolerance` (same unit).
    public func matches(_ other: PageSize, tolerance: Double = 1.0) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

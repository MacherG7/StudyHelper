import Foundation

/// An sRGB color with components in 0…1. Used for pen colors, highlighter
/// colors and colored embedded text.
public struct RGBColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// Parses "#RRGGBB" or "RRGGBB". Returns nil for anything else.
    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    public static let black = RGBColor(red: 0, green: 0, blue: 0)
    public static let white = RGBColor(red: 1, green: 1, blue: 1)

    /// "#RRGGBB", uppercase.
    public var hex: String {
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Euclidean distance in RGB space (0 … √3).
    public func distance(to other: RGBColor) -> Double {
        let dr = red - other.red, dg = green - other.green, db = blue - other.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// Rough check for highlighter yellow: bright red and green, low blue.
    public var isYellowish: Bool {
        red > 0.75 && green > 0.65 && blue < 0.5
    }

    /// True for black or very dark gray, i.e. the default pen color.
    public var isNearlyBlack: Bool {
        max(red, green, blue) < 0.2
    }
}

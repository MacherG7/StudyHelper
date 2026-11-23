import Foundation

/// Small procedurally generated RGB image (8 bit per component, uncompressed).
struct RasterImage {
    let width: Int
    let height: Int
    let rgb: Data

    /// Simplified plant cell (cell wall, membrane, nucleus, vacuole, chloroplasts, mitochondria). No text.
    static func cellDiagram() -> RasterImage {
        let w = 160, h = 120
        var data = Data(capacity: w * h * 3)

        // Signed distance helpers (pixel units).
        func roundedRect(_ x: Double, _ y: Double, cx: Double, cy: Double, hw: Double, hh: Double, r: Double) -> Double {
            let qx = abs(x - cx) - (hw - r), qy = abs(y - cy) - (hh - r)
            let ox = max(qx, 0), oy = max(qy, 0)
            return (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
        }
        func ellipse(_ x: Double, _ y: Double, cx: Double, cy: Double, rx: Double, ry: Double) -> Double {
            let dx = (x - cx) / rx, dy = (y - cy) / ry
            return ((dx * dx + dy * dy).squareRoot() - 1) * min(rx, ry)
        }

        let chloroplasts: [(Double, Double)] = [(30, 28), (48, 20), (112, 24), (128, 36), (126, 92), (34, 88)]
        let mitochondria: [(Double, Double)] = [(40, 62), (104, 98), (78, 22)]

        for py in 0..<h {
            for px in 0..<w {
                let x = Double(px) + 0.5, y = Double(py) + 0.5
                var color: (UInt8, UInt8, UInt8) = (247, 250, 244) // background

                let outer = roundedRect(x, y, cx: 80, cy: 60, hw: 74, hh: 54, r: 14)
                if outer < 0 {
                    color = (46, 125, 50) // cell wall
                    if outer < -4 {
                        color = (129, 199, 132) // membrane
                        if outer < -6 {
                            color = (232, 245, 233) // cytoplasm
                            if ellipse(x, y, cx: 98, cy: 62, rx: 22, ry: 28) < 0 {
                                color = (144, 202, 249) // vacuole
                            }
                            if ellipse(x, y, cx: 60, cy: 58, rx: 18, ry: 18) < 0 {
                                color = (149, 117, 205) // nucleus
                                if ellipse(x, y, cx: 56, cy: 54, rx: 6, ry: 6) < 0 { color = (94, 53, 177) }
                            }
                            for (cx, cy) in chloroplasts where ellipse(x, y, cx: cx, cy: cy, rx: 9, ry: 5) < 0 {
                                color = (56, 142, 60)
                            }
                            for (cx, cy) in mitochondria where ellipse(x, y, cx: cx, cy: cy, rx: 8, ry: 4.5) < 0 {
                                color = (239, 108, 0)
                            }
                        }
                    }
                }
                data.append(contentsOf: [color.0, color.1, color.2])
            }
        }
        return RasterImage(width: w, height: h, rgb: data)
    }
}

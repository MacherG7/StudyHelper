import Foundation

/// Hand-assembled PDFs for tests (rotation, transparency, images, huge pages). Object numbers are 1-based in
/// the order given; object 1 must be the catalog.
enum MiniObject {
    case plain(String)
    case stream(dictionary: String, data: Data)
}

enum MiniPDF {
    static func build(_ objects: [MiniObject]) -> Data {
        var out = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n".utf8))
            switch object {
            case .plain(let body):
                out.append(Data(body.utf8))
            case .stream(let dictionary, let data):
                out.append(Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8))
                out.append(data)
                out.append(Data("\nendstream".utf8))
            }
            out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return out
    }

    /// One page. `annotations` are object bodies appended after the standard objects (page = 3, content = 4,
    /// annotations from 5 on); `extra` objects follow the annotations.
    static func page(
        width: Double, height: Double, rotate: Int = 0, content: String = "", resources: String = "<< >>",
        annotations: [String] = [], extra: [MiniObject] = []
    ) -> Data {
        let annotationRefs = annotations.indices.map { "\(5 + $0) 0 R" }.joined(separator: " ")
        var objects: [MiniObject] = [
            .plain("<< /Type /Catalog /Pages 2 0 R >>"),
            .plain("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            .plain("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)]"
                + (rotate != 0 ? " /Rotate \(rotate)" : "")
                + " /Contents 4 0 R /Resources \(resources)"
                + (annotations.isEmpty ? "" : " /Annots [\(annotationRefs)]") + " >>"),
            .stream(dictionary: "", data: Data(content.utf8)),
        ]
        objects += annotations.map { .plain($0) }
        objects += extra
        return build(objects)
    }

    /// An Ink annotation. `points` are (x, y) pairs in unrotated user space.
    static func ink(_ points: [(Double, Double)], color: (Double, Double, Double) = (0, 0, 0), width: Double = 2, extra: String = "") -> String {
        let list = points.map { "\($0.0) \($0.1)" }.joined(separator: " ")
        let xs = points.map(\.0), ys = points.map(\.1)
        let rect = "\(xs.min()! - width) \(ys.min()! - width) \(xs.max()! + width) \(ys.max()! + width)"
        return "<< /Type /Annot /Subtype /Ink /Rect [\(rect)] /InkList [[\(list)]] /C [\(color.0) \(color.1) \(color.2)] /BS << /W \(width) >> \(extra) >>"
    }

    static func freeText(_ text: String, rect: (Double, Double, Double, Double)) -> String {
        "<< /Type /Annot /Subtype /FreeText /Rect [\(rect.0) \(rect.1) \(rect.2) \(rect.3)] /Contents (\(text)) >>"
    }
}

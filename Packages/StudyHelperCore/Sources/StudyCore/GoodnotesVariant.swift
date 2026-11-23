import Foundation

/// Goodnotes export variant of a PDF (SPEC §1). Raw values are storage keys.
public enum GoodnotesVariant: String, Codable, Hashable, Sendable {
    /// "bearbeitbar": Ink/FreeText/Stamp annotations are separate objects.
    case editable
    /// "reduziert": flattened, no annotations, recognized handwriting as text layer.
    case reduced
    /// Any other PDF.
    case other
}

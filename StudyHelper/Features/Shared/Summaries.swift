import StudyCore
import StudyData

/// Review state of one page, read from its current digitization. Reading decodes the stored JSON blobs,
/// so views cache it with `DerivedValue`.
struct PageSummary: Equatable {
    /// Lines that still need the user's attention (0 if the data is unreadable).
    var open = 0
    /// A stored blob of the current digitization cannot be read; the page must not count as "geprüft".
    var unreadable = false

    init(_ source: Source) {
        guard let digitization = source.currentDigitization else { return }
        if digitization.hasUnreadableData {
            unreadable = true
        } else {
            open = digitization.lines.filter(\.needsReview).count
        }
    }
}

/// Counts for one import (row in the subject screen).
struct BatchSummary: Equatable {
    var pages = 0
    var open = 0
    var unreadablePages = 0
    var waiting = 0
    var failed = 0

    init(_ batch: ImportBatch) {
        let sources = batch.sources
        pages = sources.count
        for source in sources {
            let page = PageSummary(source)
            open += page.open
            if page.unreadable { unreadablePages += 1 }
            switch source.digitizationState {
            case .pending: waiting += 1
            case .failed: failed += 1
            default: break
            }
        }
    }
}

/// Counts for one subject (row in the subject list).
struct SubjectSummary: Equatable {
    var imports = 0
    var open = 0
    var unreadablePages = 0

    init(_ subject: Subject) {
        imports = subject.imports.count
        for batch in subject.imports {
            for source in batch.sources {
                let page = PageSummary(source)
                open += page.open
                if page.unreadable { unreadablePages += 1 }
            }
        }
    }
}

/// Platform-independent core logic of StudyHelper.
///
/// This module depends on Foundation only. Later phases add the word-level
/// completeness check for the sorted text version, the compact context format,
/// context assembly with token budgets, Leitner scheduling and prompt templates.
public enum StudyCore {
    /// Version of the core module, shown in the app for diagnostics.
    public static let version = "0.1.0"
}

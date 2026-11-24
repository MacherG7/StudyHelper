import Foundation

/// The app version as shown in the settings: "A.B.C.D" = version (CFBundleShortVersionString) plus build
/// (CFBundleVersion), both from project.yml (docs/DECISIONS.md D-027).
enum AppVersion {
    static func display(info: [String: Any]?) -> String {
        let version = (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unbekannt"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version).\(build)"
    }

    static var current: String { display(info: Bundle.main.infoDictionary) }

    /// Short git commit the app was built from (written by scripts/embed-commit.sh, D-029); a trailing "+" means
    /// the build had uncommitted changes.
    static func commit(info: [String: Any]?) -> String {
        guard let value = info?["StudyHelperCommit"] as? String, !value.isEmpty, value != "unbekannt" else {
            return "unbekannt"
        }
        return value.hasSuffix("+") ? "\(value.dropLast())*" : value
    }

    /// The build contained uncommitted changes (shown as "*" after the commit).
    static func hasLocalChanges(info: [String: Any]?) -> Bool {
        (info?["StudyHelperCommit"] as? String)?.hasSuffix("+") ?? false
    }

    static var currentCommit: String { commit(info: Bundle.main.infoDictionary) }
}

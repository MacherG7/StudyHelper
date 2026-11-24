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
}

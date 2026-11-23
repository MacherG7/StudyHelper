import Foundation

/// Where a recognition ran (SPEC §2: "Vision-Revision, iOS-Version und Gerät pro Erkennung speichern").
/// Vision results depend on the OS version and on the device (simulator vs. real hardware), so every
/// digitization records this. Injectable so tests get deterministic metadata.
public struct RecognitionEnvironment: Hashable, Sendable {
    /// "iOS 27.2" / "macOS 27.0"
    public var osVersion: String
    /// Hardware identifier, e.g. "iPhone17,1" (iOS), "Mac16,1" (macOS). In the iOS simulator the simulated model.
    public var deviceModel: String

    public init(osVersion: String, deviceModel: String) {
        self.osVersion = osVersion
        self.deviceModel = deviceModel
    }

    /// The environment this process runs in.
    public static var current: RecognitionEnvironment {
        RecognitionEnvironment(osVersion: currentOSVersion(), deviceModel: currentDeviceModel())
    }

    static func osName() -> String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "OS"
        #endif
    }

    /// "iOS 27.2" (patch version only if non-zero, "macOS 27.0").
    static func currentOSVersion(_ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        formatOSVersion(name: osName(), version: version)
    }

    static func formatOSVersion(name: String, version: OperatingSystemVersion) -> String {
        var text = "\(name) \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 { text += ".\(version.patchVersion)" }
        return text
    }

    static func currentDeviceModel(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        #if os(iOS) || os(visionOS)
        // In the simulator `hw.machine` is the host architecture; the simulated device is in the environment.
        if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty { return simulated }
        return sysctlString("hw.machine") ?? "unknown"
        #else
        return sysctlString("hw.model") ?? "unknown"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

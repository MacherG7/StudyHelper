import Foundation
import Testing

extension Tag {
    /// Tests that run the real Apple Vision framework. Their results depend on the OS version and the device.
    @Tag static var vision: Self
}

enum VisionTestSupport {
    /// `SKIP_VISION_TESTS=1 swift test` skips every test that needs the real Vision framework.
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["SKIP_VISION_TESTS"] != "1" }
}

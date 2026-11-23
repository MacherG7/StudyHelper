// swift-tools-version: 6.0
// StudyHelperCore: platform-independent core logic of StudyHelper plus test fixtures.
// macOS is listed only so that `swift test` runs quickly on the development Mac;
// the app itself targets iOS 18+.

import PackageDescription

let package = Package(
    name: "StudyHelperCore",
    defaultLocalization: "de",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "StudyCore", targets: ["StudyCore"]),
        // Test-only: synthetic Goodnotes PDFs and their ground truth. Never linked into the app.
        .library(name: "TestFixtures", targets: ["TestFixtures"]),
        .executable(name: "make-fixtures", targets: ["make-fixtures"]),
    ],
    targets: [
        .target(name: "StudyCore"),
        .target(
            name: "TestFixtures",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "make-fixtures",
            dependencies: ["TestFixtures"]
        ),
        .testTarget(
            name: "StudyCoreTests",
            dependencies: ["StudyCore"]
        ),
        .testTarget(
            name: "TestFixturesTests",
            dependencies: ["TestFixtures"]
        ),
    ]
)

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
        .library(name: "StudyImport", targets: ["StudyImport"]),
        .library(name: "StudyData", targets: ["StudyData"]),
        // AI providers behind one protocol (Claude, OpenAI, OpenAI-compatible, Apple), keys in the Keychain.
        .library(name: "StudyAI", targets: ["StudyAI"]),
        // Test-only: synthetic Goodnotes PDFs and their ground truth. Never linked into the app.
        .library(name: "TestFixtures", targets: ["TestFixtures"]),
        .executable(name: "make-fixtures", targets: ["make-fixtures"]),
        // Dev tool: digitizes a local PDF and dumps the lines for scripts/score-recognition.py.
        .executable(name: "recognition-bench", targets: ["recognition-bench"]),
    ],
    targets: [
        .target(name: "StudyCore"),
        // PDF/Goodnotes parsing, Vision recognition, digitization pipeline.
        .target(
            name: "StudyImport",
            dependencies: ["StudyCore"]
        ),
        // SwiftData models and persistence operations.
        .target(
            name: "StudyData",
            dependencies: ["StudyCore"]
        ),
        .target(
            name: "StudyAI",
            dependencies: ["StudyCore"]
        ),
        .target(
            name: "TestFixtures",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "make-fixtures",
            dependencies: ["TestFixtures"]
        ),
        .executableTarget(
            name: "recognition-bench",
            dependencies: ["StudyCore", "StudyImport"]
        ),
        .testTarget(
            name: "StudyCoreTests",
            dependencies: ["StudyCore"]
        ),
        .testTarget(
            name: "StudyImportTests",
            dependencies: ["StudyImport", "TestFixtures"]
        ),
        .testTarget(
            name: "StudyDataTests",
            dependencies: ["StudyData"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "StudyAITests",
            dependencies: ["StudyAI"]
        ),
        .testTarget(
            name: "TestFixturesTests",
            dependencies: ["TestFixtures"]
        ),
    ]
)

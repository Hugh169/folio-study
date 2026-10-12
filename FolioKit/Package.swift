// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FolioKit",
    defaultLocalization: "en",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "FolioKit", targets: ["FolioKit"]),
    ],
    targets: [
        // Everything behind the UI: settings, reading files, choosing subjects, planning.
        // The curriculum packs and shared subject areas ship as JSON resources;
        // the reasons and messages shown to students are in a String Catalog.
        .target(name: "FolioKit", resources: [.copy("Resources/Packs"), .copy("Resources/Topics.json"), .process("Resources/Localizable.xcstrings")]),
        // Renders realistic test documents. Used by the tests and folio-testset, not the app.
        .target(name: "FolioTestSupport"),
        // `swift run folio-eval <folder>`: measures sorting accuracy on a labelled folder.
        .executableTarget(name: "folio-eval", dependencies: ["FolioKit"]),
        // `swift run folio-testset <samples.json> <output>`: builds the labelled test files.
        .executableTarget(name: "folio-testset", dependencies: ["FolioTestSupport"]),
        .testTarget(name: "FolioKitTests", dependencies: ["FolioKit", "FolioTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version:6.0
import PackageDescription

// Self-contained fuzzing package. Kept separate from the library manifests so it never affects
// consumers or CI of the main package. Build/run with AddressSanitizer, e.g.:
//   swift run --package-path Fuzz --sanitize=address ZIPFuzz <corpusDir> <iterations> <seed> <crashOut>
let package = Package(
    name: "ZIPFuzz",
    platforms: [.macOS(.v10_15)],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "ZIPFuzz",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")])
    ]
)

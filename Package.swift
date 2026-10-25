// swift-tools-version:6.0
import PackageDescription

var products: [Product] = [
    .library(name: "MelaCore", targets: ["MelaCore"]),
    .executable(name: "importer-eval", targets: ["importer-eval"]),
]

var targets: [Target] = [
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
    .target(
        name: "MelaCore",
        dependencies: [
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            "CSQLite",
        ]
    ),
    .executableTarget(name: "importer-eval", dependencies: ["MelaCore"]),
    .testTarget(name: "MelaCoreTests", dependencies: ["MelaCore"]),
]

#if os(macOS)
// The app only builds on macOS 26 with SwiftUI and WebKit.
products.append(.executable(name: "MelaImporter", targets: ["MelaImporter"]))
targets.append(.executableTarget(name: "MelaImporter", dependencies: ["MelaCore"], path: "App/MelaImporter"))
#endif

let package = Package(
    name: "MelaImporter",
    platforms: [.macOS("26.0")],
    products: products,
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: targets
)

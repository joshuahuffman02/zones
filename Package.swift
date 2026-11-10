// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Zones",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Zone geometry and editing: no AppKit. Unit-tested.
        .target(name: "ZonesCore"),
        // The menu bar app: drag-to-snap, gap handles, editor, shortcuts, updates.
        .executableTarget(
            name: "Zones",
            dependencies: ["ZonesCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .linkedFramework("Carbon"), .linkedFramework("ApplicationServices"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "ZonesCoreTests", dependencies: ["ZonesCore"]),
    ],
    swiftLanguageModes: [.v5]
)

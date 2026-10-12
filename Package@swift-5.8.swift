// swift-tools-version: 5.8
import PackageDescription

// Manifiesto para toolchains de Swift 5.8 a 5.10 (macOS 13). Las de Swift 6 usan Package.swift.

let package = Package(
    name: "AIUsageBar",
    platforms: [.macOS(.v13)],
    targets: [
        // Toda la lógica vive aquí para que sea testeable; el ejecutable sólo arranca AppKit.
        .target(name: "UsageCore"),
        .executableTarget(name: "AIUsageBar", dependencies: ["UsageCore"]),
        // Dibuja las láminas de estados del README. No se envía con la app.
        .executableTarget(name: "GenerateDocs", dependencies: ["UsageCore"]),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OrbPeek",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Fork of sindresorhus/KeyboardShortcuts 2.4.0 with a resilient
        // resource-bundle lookup: the SwiftPM-generated Bundle.module accessor
        // for executable targets only probes the .app root (rejected by
        // codesign as unsealed) and the build machine's .build dir, crashing
        // hand-packaged apps when the settings window opens (Recorder).
        .package(url: "https://github.com/zhiyozhao/KeyboardShortcuts", branch: "2.4.0-resilient-resource-bundle"),
    ],
    targets: [
        .executableTarget(
            name: "OrbPeek",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources",
            resources: [.process("Resources")]
        ),
    ]
)

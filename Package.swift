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
        // Coordinate math and the per-window state machine, isolated from AX
        // and ScreenCaptureKit so regression tests need no privacy permissions.
        .target(
            name: "OrbPeekCore",
            path: "Sources/OrbPeekCore"
        ),
        .executableTarget(
            name: "OrbPeek",
            dependencies: [
                "OrbPeekCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/OrbPeek",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OrbPeekCoreTests",
            dependencies: ["OrbPeekCore"],
            path: "Tests/OrbPeekCoreTests"
        ),
        .testTarget(
            name: "OrbPeekAppTests",
            dependencies: [
                "OrbPeek",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Tests/OrbPeekAppTests"
        ),
    ]
)

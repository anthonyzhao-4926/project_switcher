// swift-tools-version: 5.9
import PackageDescription

// 有完整 Xcode 时可用 `swift test` / `swift build`。
// 仅安装 Command Line Tools 且 SwiftPM 损坏时，请用 Makefile（swiftc）。
let package = Package(
    name: "ProjectSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ProjectSwitcher",
            path: "Sources/ProjectSwitcher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)

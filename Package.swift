// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MenuLauncher",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "MenuLauncher", path: "Sources/MenuLauncher",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MenuLauncherTests", dependencies: ["MenuLauncher"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)

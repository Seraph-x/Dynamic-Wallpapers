// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "DynamicWallpaperEditor",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DynamicWallpaperEditor", targets: ["EditorApp"])],
    dependencies: [.package(name: "DynamicWallpaperShared", path: "..")],
    targets: [.executableTarget(name: "EditorApp", dependencies: [
        .product(name: "WallpaperCore", package: "DynamicWallpaperShared"),
        .product(name: "WallpaperEditorCore", package: "DynamicWallpaperShared"),
        .product(name: "WebWallpaperBridge", package: "DynamicWallpaperShared")
    ], resources: [.copy("Resources/EditorWeb"), .process("Resources/en.lproj"), .process("Resources/zh-Hans.lproj"),
                    .process("Resources/es.lproj"), .process("Resources/ja.lproj"), .process("Resources/fr.lproj")])],
    swiftLanguageModes: [.v5]
)

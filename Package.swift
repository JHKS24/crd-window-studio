// swift-tools-version: 5.9
import PackageDescription

// The settings app (CRDWindowStudio) and the settings core it shares with its tests (CRDSettingsCore).
// The core bundles the settings schema and the Korean and English string catalogs.
let package = Package(
    name: "CRDWindowPatch",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CRDWindowStudio", targets: ["CRDWindowStudio"])],
    targets: [
        .target(name: "CRDSettingsCore", resources: [.copy("Resources/SettingsSchema.json"), .copy("Resources/Localization")]),
        .executableTarget(name: "CRDWindowStudio", dependencies: ["CRDSettingsCore"]),
        .testTarget(name: "CRDSettingsCoreTests", dependencies: ["CRDSettingsCore"]),
        .testTarget(name: "CRDWindowStudioTests", dependencies: ["CRDWindowStudio"])
    ]
)

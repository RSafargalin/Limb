// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LimbInspectorFixture",
    platforms: [.macOS(.v26)],
    traits: [
        .trait(name: "FoundationJSON", description: "Exercise Limb's Foundation JSON codec."),
    ],
    dependencies: [
        .package(name: "Limb", path: "../../..", traits: [
            .trait(name: "FoundationJSON", condition: .when(traits: ["FoundationJSON"])),
        ]),
    ],
    targets: [
        .executableTarget(
            name: "LimbInspectorFixture",
            dependencies: [.product(name: "Limb", package: "Limb")]),
    ]
)

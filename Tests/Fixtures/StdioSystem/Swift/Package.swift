// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StdioSystemPeer",
    platforms: [.macOS("26.0")],
    traits: [.trait(name: "FoundationJSON")],
    dependencies: [
        .package(name: "Limb", path: "../../../..", traits: [
            .trait(name: "FoundationJSON", condition: .when(traits: ["FoundationJSON"])),
        ]),
    ],
    targets: [
        .executableTarget(
            name: "StdioSystemPeer",
            dependencies: [.product(name: "Limb", package: "Limb")]),
    ]
)

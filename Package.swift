// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Limb",
    platforms: [
        .macOS("26.0"), .iOS("26.0"), .tvOS("26.0"), .watchOS("26.0"), .visionOS("26.0"),
    ],
    products: [
        .library(name: "Limb", targets: ["Limb"]),
        .library(name: "LimbTesting", targets: ["LimbTesting"]),
    ],
    traits: [
        .trait(
            name: "FoundationJSON",
            description: """
                Parse JSON and escape strings with Foundation instead of Limb's own codec. \
                A fallback for a defect in the default codec: slower and less strict.
                """),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        // A wide range on purpose: other macro packages in a consumer's graph pin their own.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        // JSON, JSON-RPC, revisions, errors, framing, schema validation. No dependencies.
        .target(name: "LimbCore", swiftSettings: settings),
        // @Tool and @Schema. A compiler plugin: built for the build machine, never linked into the app.
        .macro(
            name: "LimbMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]),
        // Registry, dispatcher, admission, both eras, MRTR, subscriptions.
        .target(
            name: "LimbServer",
            dependencies: [
                "LimbCore",
                "LimbMacros",
                // CryptoKit everywhere else. Darwin and Linux (glibc or Musl) are the platforms
                // the code has branches for.
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: settings),
        // stdio transport: dedicated reader and writer threads.
        .target(name: "LimbStdio", dependencies: ["LimbCore", "LimbServer"], swiftSettings: settings),
        // Umbrella: `import Limb`.
        .target(name: "Limb", dependencies: ["LimbCore", "LimbServer", "LimbStdio"], swiftSettings: settings),
        // In-memory harness for user tests.
        .target(name: "LimbTesting", dependencies: ["Limb"], swiftSettings: settings),
    ]
)

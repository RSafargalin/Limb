// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

let importSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]
let settings = importSettings + [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]

#if compiler(<6.3)
// Swift Testing 6.2 cannot run exit-test closures compiled with this feature.
let testSettings = importSettings
#else
let testSettings = settings
#endif

#if compiler(<6.4)
// swift-crypto 5 uses compiler attributes unavailable in older toolchains.
let cryptoVersions: Range<Version> = "3.0.0"..<"5.0.0"
#else
let cryptoVersions: Range<Version> = "3.0.0"..<"6.0.0"
#endif

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
        .package(url: "https://github.com/apple/swift-crypto.git", cryptoVersions),
        // A wide range on purpose: other macro packages in a consumer's graph pin their own.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        // JSON, JSON-RPC, revisions, errors, framing, schema validation.
        .target(name: "LimbCore", dependencies: [.target(name: "CLimbPosix", condition: .when(platforms: [.linux]))], swiftSettings: settings),
        .target(name: "CLimbPosix"),
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
        .target(
            name: "LimbStdio",
            dependencies: ["LimbCore", "LimbServer", .target(name: "CLimbPosix", condition: .when(platforms: [.linux]))],
            swiftSettings: settings),
        // Umbrella: `import Limb`.
        .target(name: "Limb", dependencies: ["LimbCore", "LimbServer", "LimbStdio"], swiftSettings: settings),
        // In-memory harness for user tests.
        .target(name: "LimbTesting", dependencies: ["Limb"], swiftSettings: settings),

        .testTarget(name: "LimbCoreTests", dependencies: ["LimbCore"], swiftSettings: testSettings),
        .testTarget(name: "LimbServerTests", dependencies: ["Limb", "LimbTesting"], swiftSettings: testSettings),
        .testTarget(
            name: "LimbStdioTests",
            dependencies: [
                "Limb", "LimbTesting",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: testSettings),
        .testTarget(
            name: "LimbMacrosTests",
            dependencies: [
                "Limb", "LimbTesting",
                // For asserting expansions and diagnostics of the macros themselves.
                "LimbMacros",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: testSettings),
    ]
)

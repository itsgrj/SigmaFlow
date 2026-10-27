// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SigmaFlow",
    platforms: [.macOS(.v26)],
    products: [
        // The MediaRemote bridge that /usr/bin/perl loads at runtime (Core/MediaPauser.swift).
        // A dynamic library on purpose: the app never links it, perl dlopen()s it.
        .library(name: "SigmaFlowMediaHost", type: .dynamic, targets: ["SigmaFlowMediaHost"]),
    ],
    dependencies: [
        // Parakeet TDT as CoreML on the Neural Engine. Optional at runtime — Apple's
        // SpeechTranscriber remains the default and needs no dependency at all.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
        // Gemma 4 E2B describes conversation photos (Search/PictureDescriber.swift). Pinned
        // exactly: mlx-swift 0.32.3 is MLX 0.32.2, and the app loads that version's prebuilt
        // GPU kernels at runtime, since SwiftPM on the command line cannot build them.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // Plain C, no dependencies. Hosted inside /usr/bin/perl because MediaRemote only
        // answers Apple-signed processes since macOS 15.4 — see the file header.
        .target(
            name: "SigmaFlowMediaHost",
            path: "Sources/SigmaFlowMediaHost"
        ),
        // The dictionary is its own target so it can be tested directly. It is platform-neutral
        // on purpose: CI runs its vectors on a runner that cannot build the app target.
        .target(
            name: "SigmaFlowDictionary",
            path: "Sources/SigmaFlowDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SigmaFlow",
            dependencies: [
                "SigmaFlowDictionary",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/SigmaFlow",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // The MCP helper Claude Desktop launches. Its own executable on purpose: it runs
        // headless, speaks JSON-RPC on stdio, and depends on no AppKit and no FluidAudio.
        .executableTarget(
            name: "SigmaFlowMCP",
            path: "Sources/SigmaFlowMCP",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SigmaFlowDictionaryTests",
            dependencies: ["SigmaFlowDictionary"],
            path: "Tests/SigmaFlowDictionaryTests",
            resources: [.copy("dictionary-test-vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

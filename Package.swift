// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Scrollback",
    platforms: [
        .macOS(.v15) // Sequoia floor — see docs/decisions.md (WhisperKit, AX capture)
    ],
    products: [
        .library(name: "ScrollbackCore", targets: ["ScrollbackCore"]),
        .executable(name: "scrollbackd", targets: ["scrollbackd"]),
    ],
    targets: [
        // Shared domain types + the RetrievalStore seam. No external deps yet;
        // llama.cpp / sqlite-vec / WhisperKit arrive in later M1 increments.
        .target(name: "ScrollbackCore"),

        // The capture + index daemon. Links NO networking — all egress goes
        // through scrollback-courier. Currently a versioned stub.
        .executableTarget(
            name: "scrollbackd",
            dependencies: ["ScrollbackCore"]
        ),

        .testTarget(
            name: "ScrollbackCoreTests",
            dependencies: ["ScrollbackCore"]
        ),
    ]
)

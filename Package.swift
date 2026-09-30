// swift-tools-version: 6.0
import PackageDescription

// libtdjson.dylib is built by vendor/tdlib/build.sh (git-ignored artifact). Its install name
// is the absolute path below, so binaries find it at runtime without DYLD_LIBRARY_PATH.
// Headers reach the compiler through the committed symlink Sources/CTDLib/include/td.
let tdlibLib = "\(Context.packageDirectory)/vendor/tdlib/lib"

let package = Package(
    name: "telegram-gateway",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TDLibClient", targets: ["TDLibClient"]),
        .library(name: "QRCode", targets: ["QRCode"]),
        .executable(name: "tgw", targets: ["tgw"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Raw C interface: td_create_client_id / td_send / td_receive / td_execute.
        .target(
            name: "CTDLib",
            path: "Sources/CTDLib",
            linkerSettings: [
                .unsafeFlags(["-L", tdlibLib]),
                .linkedLibrary("tdjson"),
            ]
        ),
        // One actor per TDLib client: request/response correlation, updates, auth state.
        .target(
            name: "TDLibClient",
            dependencies: ["CTDLib"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Small QR encoder (byte mode) used to show the tg://login link in the terminal.
        .target(
            name: "QRCode",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "tgw",
            dependencies: [
                "TDLibClient",
                "QRCode",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TDLibClientTests",
            dependencies: ["TDLibClient"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QRCodeTests",
            dependencies: ["QRCode"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

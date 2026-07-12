// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GmailReader",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "GmailReaderApp", targets: ["GmailReaderApp"]),
    ],
    targets: [
        .target(
            name: "CurlShim",
            path: "Sources/CurlShim",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-Wno-deprecated-declarations"])],
            linkerSettings: [.linkedLibrary("curl")]
        ),
        .executableTarget(
            name: "GmailReaderApp",
            dependencies: ["CurlShim"],
            path: "Sources/GmailReaderApp",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "GmailReaderAppTests",
            dependencies: ["GmailReaderApp"],
            path: "Tests/GmailReaderAppTests"
        ),
    ]
)

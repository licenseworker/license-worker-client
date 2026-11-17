// swift-tools-version:5.9
//
// LicenseWorkerKit: the License Worker client in Swift, for macOS and iOS
// apps. No dependencies beyond Foundation, CryptoKit and Security.
// In Xcode: File > Add Package Dependencies, this repository's URL, then
// `import LicenseWorkerKit`. See swift/README.md.
//
// The C interface (capi/) is not in this package: its XCFramework is a
// download on each GitHub Release, so Swift users never fetch it.
import PackageDescription

let package = Package(
    name: "LicenseWorkerKit",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "LicenseWorkerKit", targets: ["LicenseWorkerKit"]),
        // Test doubles (scripted server, test signer, movable clock): for test targets only.
        .library(name: "LicenseWorkerKitTesting", targets: ["LicenseWorkerKitTesting"]),
    ],
    targets: [
        .target(name: "LicenseWorkerKit", path: "swift/Sources/LicenseWorkerKit"),
        .target(name: "LicenseWorkerKitTesting", dependencies: ["LicenseWorkerKit"], path: "swift/Sources/LicenseWorkerKitTesting"),
        .testTarget(
            name: "LicenseWorkerKitTests",
            dependencies: ["LicenseWorkerKit", "LicenseWorkerKitTesting"],
            path: "swift/Tests/LicenseWorkerKitTests"
        ),
    ]
)

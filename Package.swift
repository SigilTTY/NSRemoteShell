// swift-tools-version: 5.5

import PackageDescription

let package = Package(
    name: "NSRemoteShell",
    products: [
        .library(
            name: "NSRemoteShell",
            targets: ["NSRemoteShell"]
        ),
    ],
    targets: [
        // Patched libssh2 (webauthn-sk security-key signing) from the
        // SigilTTY/Libssh2Prebuild fork. The -nested asset keeps every
        // slice's headers under Headers/CSSH/ so the sources' path-style
        // includes (#import <CSSH/libssh2.h>) resolve; it is byte-identical
        // to the flat asset otherwise.
        .binaryTarget(
            name: "CSSH",
            url: "https://github.com/SigilTTY/Libssh2Prebuild/releases/download/1.11.0-OpenSSL-1-1-1w-webauthn1/CSSH-1.11.0-OpenSSL-1-1-1w-webauthn1-nested.xcframework.zip",
            checksum: "b86ea0d5d8903dfeb00e0b0008e82015cb900409be1ecc4b2ae527a2a79bafe7"
        ),
        .target(
            name: "NSRemoteShell",
            dependencies: ["CSSH"],
            publicHeadersPath: "include"
        ),
        // Dead-connection detection regression tests (real sshd + cuttable
        // TCP proxy). Run with `swift test` in this package; macOS only.
        .testTarget(
            name: "NSRemoteShellNetworkTests",
            dependencies: ["NSRemoteShell"]
        ),
    ]
)

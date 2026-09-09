// swift-tools-version: 5.9
// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import PackageDescription

let package = Package(
    name: "transmission-remote-mac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TransmissionRemoteMac", targets: ["TransmissionRemoteMac"])
    ],
    targets: [
        .executableTarget(
            name: "TransmissionRemoteMac"
        ),
        .testTarget(
            name: "TransmissionRemoteMacTests",
            dependencies: ["TransmissionRemoteMac"]
        )
    ]
)

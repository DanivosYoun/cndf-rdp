// swift-tools-version: 5.10

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let freeRDPInstall = "\(packageRoot)/Vendor/FreeRDP/install"

let package = Package(
    name: "RDPMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "rdp-mac", targets: ["RDPMacApp"]),
        .library(name: "RDPClientCore", targets: ["RDPClientCore"]),
        .library(name: "ClipboardBridge", targets: ["ClipboardBridge"]),
        .library(name: "FileTransferStaging", targets: ["FileTransferStaging"]),
        .library(name: "FreeRDPBridge", targets: ["FreeRDPBridge"])
    ],
    targets: [
        .executableTarget(
            name: "RDPMacApp",
            dependencies: ["RDPClientCore"]
        ),
        .target(
            name: "RDPClientCore",
            dependencies: ["FreeRDPBridge", "ClipboardBridge", "FileTransferStaging"]
        ),
        .target(
            name: "ClipboardBridge",
            dependencies: ["FreeRDPBridge", "FileTransferStaging"]
        ),
        .target(
            name: "FileTransferStaging"
        ),
        .target(
            name: "FreeRDPBridge",
            publicHeadersPath: "include",
            cSettings: [
                .define("RDP_FREERDP_REAL", to: "1"),
                .unsafeFlags([
                    "-I\(freeRDPInstall)/include/freerdp3",
                    "-I\(freeRDPInstall)/include/winpr3"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(freeRDPInstall)/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(freeRDPInstall)/lib",
                    "-lfreerdp-client3",
                    "-lfreerdp3",
                    "-lwinpr3"
                ])
            ]
        ),
        .testTarget(
            name: "ClipboardBridgeTests",
            dependencies: ["ClipboardBridge"]
        ),
        .testTarget(
            name: "FileTransferStagingTests",
            dependencies: ["FileTransferStaging"]
        ),
        .testTarget(
            name: "RDPClientCoreTests",
            dependencies: ["RDPClientCore"]
        )
    ]
)

// swift-tools-version: 5.10

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let freeRDPInstall = "\(packageRoot)/Vendor/FreeRDP/install"
// Built by Scripts/build-ironrdp.sh (aarch64-apple-darwin static library, design D1).
let ironRDPInstall = "\(packageRoot)/Vendor/IronRDP/install"

let package = Package(
    name: "RDPMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "rdp-mac", targets: ["RDPMacApp"]),
        .executable(name: "window-close-stress-test", targets: ["WindowCloseStressTest"]),
        .executable(name: "rdp-engine-harness", targets: ["RDPEngineHarness"]),
        .library(name: "RDPClientCore", targets: ["RDPClientCore"]),
        .library(name: "RDPMacView", targets: ["RDPMacView"]),
        .library(name: "ClipboardBridge", targets: ["ClipboardBridge"]),
        .library(name: "FileTransferStaging", targets: ["FileTransferStaging"]),
        .library(name: "FreeRDPBridge", targets: ["FreeRDPBridge"]),
        .library(name: "IronRDPBridge", targets: ["IronRDPBridge"])
    ],
    targets: [
        .executableTarget(
            name: "RDPMacApp",
            dependencies: ["RDPClientCore", "RDPMacView"]
        ),
        .executableTarget(
            name: "WindowCloseStressTest",
            dependencies: ["RDPClientCore", "RDPMacView"]
        ),
        .executableTarget(
            name: "RDPEngineHarness",
            dependencies: ["RDPClientCore", "RDPMacView"]
        ),
        .target(
            name: "RDPMacView",
            dependencies: ["RDPClientCore"]
        ),
        .target(
            name: "RDPClientCore",
            dependencies: ["FreeRDPBridge", "IronRDPBridge", "ClipboardBridge", "FileTransferStaging"]
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
        .target(
            name: "IronRDPBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(ironRDPInstall)/lib",
                    "-lcndf_ironrdp"
                ]),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                // VideoToolbox H.264 decoding (design m4-h264 D8).
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedLibrary("iconv")
            ]
        ),
        .testTarget(
            name: "ClipboardBridgeTests",
            dependencies: ["ClipboardBridge"]
        ),
        .testTarget(
            name: "FreeRDPBridgeTests",
            dependencies: ["FreeRDPBridge"]
        ),
        .testTarget(
            name: "FileTransferStagingTests",
            dependencies: ["FileTransferStaging"]
        ),
        .testTarget(
            name: "RDPClientCoreTests",
            dependencies: ["RDPClientCore", "IronRDPBridge"]
        ),
        .testTarget(
            name: "RDPEngineHarnessTests",
            dependencies: ["RDPEngineHarness"]
        ),
        .testTarget(
            name: "RDPMacViewTests",
            dependencies: ["RDPMacView"]
        )
    ]
)

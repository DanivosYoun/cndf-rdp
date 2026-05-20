# RDP Mac

SwiftPM-based macOS RDP client with an embeddable AppKit view, a thin FreeRDP bridge, dynamic resize, clipboard/file transfer, local folder redirection, and audio playback options.

## Modules

- `RDPMacApp`: AppKit executable with a connection bar and RDP surface.
- `RDPMacView`: embeddable AppKit view package for host macOS apps.
- `RDPClientCore`: Swift session lifecycle wrapper and delegate API.
- `FreeRDPBridge`: narrow C ABI for FreeRDP integration, linked against the vendored FreeRDP 3.26 build.
- `ClipboardBridge`: `NSPasteboard` read/write coordination and local-to-remote clipboard dispatch.
- `FileTransferStaging`: local file staging plus encoded file-list payloads used by the bridge layer.

## Build

The project builds against a local FreeRDP checkout pinned to `3.26.0`
(`3f6d7cb1f8973cc84c66b258a9a61c4e2b2f30a6`). Build it before running SwiftPM:

```sh
./Scripts/build-freerdp.sh
```

`Vendor/FreeRDP/src` is a local git checkout created by the build script. `Vendor/FreeRDP/build`
and `Vendor/FreeRDP/install` are generated and ignored. The build script reapplies the local
FreeRDP `cliprdr` format-name patch after resetting the checkout to the pinned commit. The
vendored build enables `cliprdr`, `drdynvc`, `disp`, `rdpgfx`, `rdpdr`, `drive`, `rdpsnd`,
and the macOS audio backend.

## Feature Status

The bridge currently provides:

- `rdp_bridge_connect`
- `rdp_bridge_disconnect`
- `rdp_bridge_send_local_text`
- `rdp_bridge_send_local_file_list`
- `rdp_bridge_request_remote_file_contents`
- `rdp_bridge_update_desktop_size`
- optional local folder redirection through FreeRDP `rdpdr`
- optional audio playback through FreeRDP `rdpsnd`
- pointer, scroll, and keyboard input dispatch
- GDI framebuffer delivery to Swift as BGRA frames
- Metal-backed frame presentation through `MTKView`
- `cliprdr` text clipboard format negotiation
- Mac-to-RDP file paste using `FileGroupDescriptorW` plus `FileContentsRequest` range reads
- RDP-to-Mac file paste materialization using remote range requests and local staged file URLs
- Finder file drag/drop into the RDP surface with automatic remote paste trigger
- optional mounted macOS folder visible in the remote session as an RDP redirected drive
- optional audio playback locally on macOS, remote/server playback, or disabled audio
- embeddable `RDPConnectionView` for host apps that want a ready-to-use RDP surface

The bridge registers FreeRDP's static addin provider directly because it creates a
minimal `freerdp_new()` session instead of using the full FreeRDP client wrapper.
With the local FreeRDP build, `cliprdr` and `drdynvc` load during pre-connect.

The app uses FreeRDP's event loop on a background WinPR thread and displays received GDI frames through AppKit.

Smooth interactive behavior depends on keeping resize, rendering, input, and clipboard work on separate paths:

- desktop resize updates are coalesced by `DisplayResizeCoordinator`
- clipboard/file transfers are staged outside the UI path
- the bridge API has an explicit `rdp_bridge_update_desktop_size` hook for FreeRDP display control integration

Remaining production work:

- harden RDP-to-Mac file paste with progress UI, cancellation, and Finder promised-file fallback
- add credential persistence and certificate trust UI

## Test Summary

Verified against a Windows RDP test host on 2026-05-21:

- FreeRDP addins loaded and connected: `rdpdr`, `rdpsnd`, `cliprdr`, `drdynvc`, `rdpgfx`, `disp`
- audio playback path connected through `AUDIO_PLAYBACK_DVC`
- dynamic resize sent through DisplayControl after the remote desktop connected
- Mac-to-RDP file paste requested descriptor, file size, and file range successfully
- RDP-to-Mac copy-back materialized the remote file to the macOS pasteboard
- `swift test` passes all package tests

Manual checklist for future changes:

1. Resize the macOS window and confirm the remote desktop fills the view without black side gaps.
2. Copy a file in Finder, focus Explorer or Desktop in the RDP session, then paste.
3. Drag a file from Finder into the RDP surface and confirm it appears remotely.
4. Select a remote file in Explorer, copy it, then paste into Finder on macOS.
5. Enable a redirected folder and confirm it appears in the remote session.
6. Enable local audio playback and confirm the `rdpsnd` and `AUDIO_PLAYBACK_DVC` channels connect.

## Verify

```sh
./Scripts/build-freerdp.sh
swift test
```

For live file-copy smoke testing, set `RDP_MAC_AUTOTEST_EXPLORER_FILE_PASTE=1` with
`RDP_MAC_AUTOCONNECT=1`. The test opens the remote Desktop in Explorer, offers a small
local file, pastes it, then copies the selected remote file back to the macOS pasteboard.

## Embed In Another App

Add this repository as a SwiftPM dependency:

```swift
.package(url: "https://github.com/CNDF-WORK/terminal-rdp.git", branch: "main")
```

Then depend on `RDPMacView` from the app target:

```swift
.product(name: "RDPMacView", package: "terminal-rdp")
```

Use `RDPConnectionView` as a normal `NSView`:

```swift
import RDPMacView
import RDPClientCore

let rdpView = RDPConnectionView(frame: container.bounds)
rdpView.autoresizingMask = [.width, .height]
container.addSubview(rdpView)

try rdpView.connect(
    RDPConnectionOptions(
        host: host,
        port: 3389,
        username: username,
        password: password,
        domain: domain,
        redirectedFolderPath: "/Users/me/RDPShare",
        redirectedFolderName: "RemoteShare",
        audioPlaybackMode: .playLocally
    )
)
```

`RDPConnectionView` owns the `RDPSession`, renders frames through Metal, forwards mouse and keyboard input, polls `NSPasteboard`, supports Finder drag/drop, and sends dynamic desktop resize updates. Use `RDPConnectionViewDelegate` if the host app needs logs, connection state, or remote clipboard notifications.

`redirectedFolderPath` mounts one macOS folder into the remote session using the provided
`redirectedFolderName` share name. Leave it `nil` to disable local folder mounting.
`audioPlaybackMode` supports `.playLocally`, `.playOnRemote`, and `.disabled`.

## External Credentials

Credentials are not persisted by the app. A terminal or vault wrapper can inject them at launch:

```sh
RDP_MAC_HOST=192.168.1.10 \
RDP_MAC_PORT=3389 \
RDP_MAC_USERNAME=user \
RDP_MAC_PASSWORD=secret \
RDP_MAC_DOMAIN=DOMAIN \
RDP_MAC_REDIRECT_FOLDER_PATH=/Users/me/RDPShare \
RDP_MAC_REDIRECT_FOLDER_NAME=RemoteShare \
RDP_MAC_AUDIO_MODE=local \
RDP_MAC_AUTOCONNECT=1 \
swift run rdp-mac
```

`RDP_MAC_AUDIO_MODE` accepts `local`, `remote`, or `off`. `RDP_MAC_AUTOCONNECT` is optional.
Without it, visible credential fields are only prefilled in the connection bar.

The sample app connection bar also exposes the audio mode and redirected folder controls for manual testing.

## Test Hook

For ad hoc integration testing only, set `RDP_MAC_AUTOTEST_EXPLORER_FILE_PASTE=1`.
The app opens the remote Desktop in Explorer, offers a small local file, pastes it,
then copies the selected remote file back to the macOS pasteboard.

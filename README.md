# RDP Mac

SwiftPM-based macOS RDP client scaffold with a thin FreeRDP bridge and separate clipboard/file-transfer services.

## Modules

- `RDPMacApp`: AppKit executable with a connection bar and RDP surface.
- `RDPClientCore`: Swift session lifecycle wrapper and delegate API.
- `FreeRDPBridge`: narrow C ABI for FreeRDP integration, linked against the vendored FreeRDP 3.26 build.
- `ClipboardBridge`: `NSPasteboard` read/write coordination and local-to-remote clipboard dispatch.
- `FileTransferStaging`: local file staging plus encoded file-list payloads used by the bridge layer.

## Current State

The project builds against a local FreeRDP checkout pinned to `3.26.0`
(`3f6d7cb1f8973cc84c66b258a9a61c4e2b2f30a6`). Build it before running SwiftPM:

```sh
./Scripts/build-freerdp.sh
```

`Vendor/FreeRDP/src` is a local git checkout created by the build script. `Vendor/FreeRDP/build`
and `Vendor/FreeRDP/install` are generated and ignored. The build script reapplies the local
FreeRDP `cliprdr` format-name patch after resetting the checkout to the pinned commit.

The bridge currently provides:

- `rdp_bridge_connect`
- `rdp_bridge_disconnect`
- `rdp_bridge_send_local_text`
- `rdp_bridge_send_local_file_list`
- `rdp_bridge_request_remote_file_contents`
- `rdp_bridge_update_desktop_size`
- pointer, scroll, and keyboard input dispatch
- GDI framebuffer delivery to Swift as BGRA frames
- Metal-backed frame presentation through `MTKView`
- `cliprdr` text clipboard format negotiation
- Mac-to-RDP file paste using `FileGroupDescriptorW` plus `FileContentsRequest` range reads
- RDP-to-Mac file paste materialization using remote range requests and local staged file URLs
- Finder file drag/drop into the RDP surface with automatic remote paste trigger

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

## Manual Test Checklist

After launching a test session:

1. Resize the macOS window and confirm the remote desktop fills the view without black side gaps.
2. Copy a file in Finder, focus Explorer or Desktop in the RDP session, then paste.
3. Drag a file from Finder into the RDP surface and confirm it appears remotely.
4. Select a remote file in Explorer, copy it, then paste into Finder on macOS.

Expected file-transfer logs include `FileGroupDescriptorW`, local file descriptor requests,
file size requests, and file range requests.

## Verify

```sh
swift test
```

## External Credentials

Credentials are not persisted by the app. A terminal or vault wrapper can inject them at launch:

```sh
RDP_MAC_HOST=192.168.1.10 \
RDP_MAC_PORT=3389 \
RDP_MAC_USERNAME=user \
RDP_MAC_PASSWORD=secret \
RDP_MAC_DOMAIN=DOMAIN \
RDP_MAC_AUTOCONNECT=1 \
swift run rdp-mac
```

`RDP_MAC_AUTOCONNECT` is optional. Without it, injected values are only prefilled in the connection bar.

## Test Hook

For ad hoc integration testing only, set `RDP_MAC_AUTOTEST_EXPLORER_FILE_PASTE=1`.
The app opens the remote Desktop in Explorer, offers a small local file, pastes it,
then copies the selected remote file back to the macOS pasteboard.

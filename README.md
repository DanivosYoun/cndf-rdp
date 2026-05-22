# RDP Mac

SwiftPM-based macOS RDP client with an embeddable AppKit view, a thin FreeRDP bridge, Retina-aware dynamic resize, clipboard/file transfer, local folder redirection, and audio playback options.

## Modules

- `RDPMacApp`: AppKit executable with a connection bar and RDP surface.
- `WindowCloseStressTest`: standalone executable that repeatedly connects, shuts down, closes an
  RDP window, and drains autorelease pools outside XCTest.
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
- `rdp_bridge_send_scroll_at`
- `rdp_bridge_send_key_ex`
- optional local folder redirection through FreeRDP `rdpdr`
- optional audio playback through FreeRDP `rdpsnd`
- pointer, scroll, and keyboard input dispatch
- GDI framebuffer delivery to Swift as BGRA frames
- rendered-frame tap callback as BGRA `CVPixelBuffer` for host-side session sharing/encoding
- public input injection methods for shared-session mouse, keyboard, and scroll forwarding
- AppKit layer-backed frame presentation without `MTKView`/`CAMetalLayer` close-time release hazards
- `cliprdr` text clipboard format negotiation
- Mac-to-RDP file and folder paste using `FileGroupDescriptorW` plus `FileContentsRequest` range reads
- RDP-to-Mac file paste materialization using remote range requests and local staged file URLs
- Finder file drag/drop into the RDP surface with automatic remote paste trigger
- NFC filename normalization at Mac/Windows file-transfer boundaries for Korean filenames
- certificate trust callback for TOFU/known-host policy integration
- typed connection failure callback for user-facing diagnostics and audit codes
- disconnect reason callback for audit/reconnect policy
- optional per-session log file writing
- WLog root level and per-category filter control
- package and FreeRDP build info through `RDPMacInfo`
- `RDPSecureString` for vault-supplied transient passwords
- reconnect API using retained connection options
- session statistics for frames, clipboard, file transfer, and activity timestamps
- Retina-aware desktop resize using the host window backing scale factor by default
- optional 1x resize mode for low-bandwidth sessions
- optional fixed remote desktop size for force-display-mode style workflows
- configurable FreeRDP color depth: 16, 24, or 32 bpp
- frame presentation disables `CALayer` implicit animations so RDP frames swap immediately without fade/transition effects
- serialized `RDPSession` bridge access to prevent reconnect/disconnect races with clipboard, resize, input, and file-transfer calls
- hardened FreeRDP teardown that waits for the event-loop thread before freeing native session state
- explicit `RDPConnectionView.shutdown()` for safe `NSWindow` close and render-surface teardown
- optional mounted macOS folder visible in the remote session as an RDP redirected drive
- optional audio playback locally on macOS, remote/server playback, or disabled audio
- embeddable `RDPConnectionView` for host apps that want a ready-to-use RDP surface

The bridge registers FreeRDP's static addin provider directly because it creates a
minimal `freerdp_new()` session instead of using the full FreeRDP client wrapper.
With the local FreeRDP build, `cliprdr` and `drdynvc` load during pre-connect.

The app uses FreeRDP's event loop on a background WinPR thread and displays received GDI frames through AppKit.

Smooth interactive behavior depends on keeping resize, rendering, input, and clipboard work on separate paths:

- desktop resize updates are coalesced by `DisplayResizeCoordinator`
- Retina displays send point size multiplied by `NSWindow.backingScaleFactor` unless `preferDeviceNativeResolution` is disabled
- `forcedDesktopSize` locks the remote framebuffer size and scales it proportionally inside the local view
- the frame layer disables implicit `contents`, `contentsScale`, bounds, and position animations to avoid fade-like frame transitions
- `onRenderedFrame` is a nil-by-default tap; when attached, each displayed frame is copied into a BGRA `CVPixelBuffer` after the layer update
- clipboard/file transfers are staged outside the UI path
- the bridge API has an explicit `rdp_bridge_update_desktop_size` hook for FreeRDP display control integration

Remaining production work:

- harden RDP-to-Mac file paste with progress UI, cancellation, and Finder promised-file fallback
- add host-app credential persistence and certificate trust UI

## Integration API

`RDPSessionDelegate` and `RDPConnectionViewDelegate` expose the integration hooks needed by a host app:

```swift
func rdpSession(
    _ session: RDPSession,
    shouldTrustCertificateFingerprint fingerprint: String,
    hostname: String,
    port: UInt16
) async -> Bool

func rdpSession(_ session: RDPSession, didFailWith error: RDPSessionError)
func rdpSession(_ session: RDPSession, didDisconnectWith reason: RDPDisconnectReason)
```

The default certificate callback returns `true` for TOFU auto-accept behavior. Host apps with a
known-host store should compare `fingerprint`, store on first use, and return `false` for rejected
changes. A rejected certificate is reported as `.certificateRejected`.

Typed failures are reported as:

- `.networkUnreachable(underlying:)`
- `.tlsHandshakeFailed(reason:)`
- `.authenticationFailed`
- `.certificateRejected`
- `.configurationInvalid(reason:)`
- `.freerdp(code:description:)`

Disconnect reasons are `.localRequest`, `.serverDisconnect(code:)`, `.timeout`, and `.error`.
Use `RDPConnectionOptions.logFileURL` to let the package append per-session logs directly.
Use `RDPConnectionOptions.logLevel` and `logFilters` for WLog root/category control, for example
`["com.freerdp.channels.cliprdr": .trace]`.
Use `RDPMacInfo.packageVersion`, `RDPMacInfo.freerdpVersion`, and
`RDPMacInfo.buildConfiguration` in about dialogs and bug reports.

For vault integration, pass `securePassword: RDPSecureString(vaultPassword)` instead of
`password:`. The secure string provides explicit `zeroize()` and only exposes a temporary C string
during `connect`. `password:` remains for compatibility.

`RDPSession.reconnect()` and `RDPConnectionView.reconnect()` perform a clean disconnect followed by
a connect with the retained options. `RDPSession.statistics` and `RDPConnectionView.statistics`
expose `RDPConnectionStatistics` counters for frames, frame bytes, clipboard text events, file
counts, file bytes, session start, and last activity.

For RDP session sharing, `RDPClientView` and `RDPConnectionView` expose a rendered-frame tap:

```swift
rdpView.onRenderedFrame = { pixelBuffer, hostTime in
    encoderQueue.async {
        encode(pixelBuffer, presentationTime: hostTime)
    }
}
```

The tap fires on the main thread after the backing layer has been updated. The pixel buffer is
BGRA (`kCVPixelFormatType_32BGRA`) and created only when the tap is non-`nil`; hosts may retain the
buffer. Keep the closure cheap and dispatch encoding work off-main. Set `onRenderedFrame = nil`
before disconnect/shutdown; `RDPClientView.shutdownRendering()` also clears it defensively.

Shared-session viewers can inject input through the same FreeRDP path used by local AppKit events:

```swift
rdpView.injectMouse(x: 960, y: 540, button: .left, flags: [.move, .down])
rdpView.injectMouse(x: 960, y: 540, button: .left, flags: [.up])
rdpView.injectKey(virtualKeyCode: 0x41, scanCode: 0x1E, flags: [.down, .up])
rdpView.injectScroll(x: 960, y: 540, deltaY: 120, deltaX: 0)
```

Injected coordinates are remote framebuffer coordinates, not local view coordinates. The caller is
responsible for viewer-to-host scaling and permission checks. Injection methods are fire-and-forget,
safe to call from any queue, and no-op when the view is shut down or the RDP session is disconnected.

Call `RDPConnectionView.shutdown()` before closing a host `NSWindow` or removing the view from the
window hierarchy. `shutdown()` is idempotent, stops frame presentation, clears layer contents,
disables the current window close animation, sets `isReleasedWhenClosed = false`, orders the window
out, detaches delegates, suppresses late callbacks, synchronously disconnects the RDP session,
drains queued main-thread view callbacks, replaces the host window's content view with an inert
placeholder, and returns `RDPShutdownDiagnostics`. This removes the RDP content tree from AppKit's
later `window.close()` release path and lets the host's ARC/window-controller ownership release the
window normally after close.
Diagnostics include whether a FreeRDP worker was waited, pending main callback count,
in-flight command buffer count kept for API compatibility, FreeRDP wait duration, and render drain
duration.
After `shutdown()`, the view instance cannot be reconnected; create a new `RDPConnectionView` for a
new session.

Threading contract:

- `RDPConnectionView.connect(_:)`, `disconnect()`, and view mutation should be called from the main thread.
- `RDPConnectionView.shutdown()` should be called before host window close. It marshals to the main thread if needed, and can block while FreeRDP worker teardown completes.
- `RDPSession.connect(_:)`, `disconnect()`, `reconnect()`, input dispatch, resize, clipboard polling, and file offering are internally serialized around the FreeRDP bridge.
- `RDPConnectionView.injectMouse`, `injectKey`, and `injectScroll` may be called from any queue; they enqueue work on a serial input queue and return immediately.
- `RDPSession.disconnect()` waits up to five seconds for the FreeRDP event-loop thread to exit before returning an error; `RDPSession` destruction waits until native teardown is complete before freeing bridge state.
- `RDPSessionDelegate` callbacks are delivered from the FreeRDP worker thread unless explicitly noted by the view wrapper.
- `RDPConnectionViewDelegate` frame display is marshalled to the main thread by `RDPConnectionView`; other callbacks should dispatch to the main thread before mutating UI.

Follow-up request status:

| Request | Status |
|---|---|
| 1. Certificate TOFU callback | Implemented |
| 2. Typed error callback | Implemented |
| 3. Disconnect reason callback | Implemented |
| 4. Per-session log file URL | Implemented |
| 5. WLog level/filter control | Implemented |
| 6. Package and FreeRDP version info | Implemented |
| 7. Thread safety contract docs | Documented |
| 8. Secure password handling | Implemented |
| 9. Reconnect API | Implemented |
| 10. Connection statistics | Implemented |

## Test Summary

Live behavior was verified against a Windows RDP test host on 2026-05-21. Package tests were
rerun on 2026-05-22:

- FreeRDP addins loaded and connected: `rdpdr`, `rdpsnd`, `cliprdr`, `drdynvc`, `rdpgfx`, `disp`
- audio playback path connected through `AUDIO_PLAYBACK_DVC`
- dynamic resize sent through DisplayControl after the remote desktop connected
- Retina/native-resolution resize, 1x opt-out resize, forced desktop size, and color depth options are covered by unit tests
- live resize smoke tests verified Retina/native scale (`1920x1280 scale=2.00`), 1x opt-out
  (`960x640 scale=1.00`), forced desktop size (`1920x1080 scale=1.00`), and 16/24 bpp
  connection negotiation without new crash reports
- frame-layer implicit animation suppression is covered by unit tests and live smoke-tested with RDP connect/shutdown
- frame tap delivery is covered by unit tests for BGRA `CVPixelBuffer` format, dimensions, host timestamp, main-thread delivery, shutdown cleanup, and `RDPConnectionView` forwarding
- input injection no-op behavior without a connected session is covered by unit tests
- Mac-to-RDP file paste requested descriptor, file size, and file range successfully
- Mac-to-RDP folder paste was live-tested through Explorer; Windows requested descriptors plus file size/range reads for both root and nested files
- folder paste is staged recursively as relative file paths such as `Folder\Sub\file.txt`
- RDP-to-Mac copy-back materialized the remote file to the macOS pasteboard
- decomposed Korean filenames are normalized to NFC before being advertised to Windows
- WLog debug/filter options were applied during live connection testing
- per-session log file creation was verified at `/tmp/rdp-session-followup.log`
- live reconnect was verified against the test host with DisplayControl and dynamic resize restored
- session teardown hardening was verified with live connect/disconnect and no new macOS crash report
- `RDPConnectionView.shutdown()` lifecycle behavior, idempotence, connect-after-shutdown rejection, late-callback suppression, diagnostics, repeated `NSWindow.close()` autorelease-drain survival, delayed main-queue drain survival, and post-close deallocation are covered by AppKit unit tests
- live connect + shutdown + window close regression was verified with the standalone
  `window-close-stress-test` for 100 consecutive cycles; every cycle reported
  `didWait=true`, `pendingMain=0`, and `inFlight=0`, and no new macOS crash report was created
- folder staging, mixed file/folder paste lists, and Korean filename NFC normalization are covered by unit tests
- secure password, reconnect guard, runtime info, and statistics APIs are covered by tests
- `swift test` passes all 31 package tests, with the live RDP close test skipped unless
  `RDP_WINDOW_CLOSE_INTEGRATION=1` is set

Manual checklist for future changes:

1. Resize the macOS window and confirm the remote desktop fills the view without black side gaps.
2. On a Retina display, confirm the DisplayControl log uses the backing-scale pixel size and text is sharp.
3. Set `preferDeviceNativeResolution` to `false` and confirm resize updates use 1x point dimensions.
4. Set `forcedDesktopSize` such as `1920x1080` and confirm the remote framebuffer stays fixed while the local view scales proportionally.
5. Switch `colorDepth` between 32, 24, and 16 bpp and confirm connection negotiation succeeds.
6. Copy a file in Finder, focus Explorer or Desktop in the RDP session, then paste.
7. Drag a file from Finder into the RDP surface and confirm it appears remotely.
8. Copy or drag a folder that contains nested files and confirm the folder structure appears remotely.
9. Select a remote file in Explorer, copy it, then paste into Finder on macOS.
10. Enable a redirected folder and confirm it appears in the remote session.
11. Enable local audio playback and confirm the `rdpsnd` and `AUDIO_PLAYBACK_DVC` channels connect.
12. Copy or drag a Korean-named file or folder and confirm the name stays composed on Windows.
13. Host `RDPConnectionView` in a separate `NSWindow`, connect, call `shutdown()`, then close the window and confirm the host app stays alive.
14. Repeat the `shutdown()` plus window close flow 10 times and confirm there is no crash or delayed macOS crash report.
15. Connect and immediately call `shutdown()` before the first frame arrives, then close the window.

## Verify

```sh
./Scripts/build-freerdp.sh
swift test
```

For live file-copy smoke testing, set `RDP_MAC_AUTOTEST_EXPLORER_FILE_PASTE=1` with
`RDP_MAC_AUTOCONNECT=1`. The test opens the remote Desktop in Explorer, offers a small
local file, pastes it, then copies the selected remote file back to the macOS pasteboard.

For live folder-copy smoke testing, set `RDP_MAC_AUTOTEST_EXPLORER_FOLDER_PASTE=1` with
`RDP_MAC_AUTOCONNECT=1`. The test opens the remote Desktop in Explorer, offers a temporary
folder containing a root file plus a nested Korean-named file, and pastes it through the
same clipboard file-transfer path used by Finder folder copy/drag.

## Embed In Another App

Add this repository as a SwiftPM dependency:

```swift
.package(url: "https://github.com/DanivosYoun/cndf-rdp.git", branch: "main")
```

Then depend on `RDPMacView` from the app target:

```swift
.product(name: "RDPMacView", package: "cndf-rdp")
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
        securePassword: RDPSecureString(vaultPassword),
        domain: domain,
        redirectedFolderPath: "/Users/me/RDPShare",
        redirectedFolderName: "RemoteShare",
        audioPlaybackMode: .playLocally,
        logFileURL: URL(fileURLWithPath: "/Users/me/Library/Logs/MyApp/rdp/session.log"),
        logLevel: .info,
        logFilters: ["com.freerdp.channels.cliprdr": .debug],
        preferDeviceNativeResolution: true,
        colorDepth: .depth32,
        forcedDesktopSize: nil
    )
)

let stats = rdpView.statistics

// Before closing the host NSWindow or removing rdpView:
let diagnostics = rdpView.shutdown()
```

`RDPConnectionView` owns the `RDPSession`, renders frames through an AppKit layer-backed view, forwards mouse and keyboard input, polls `NSPasteboard`, supports Finder drag/drop, and sends dynamic desktop resize updates. Use `RDPConnectionViewDelegate` if the host app needs logs, connection state, or remote clipboard notifications.

`redirectedFolderPath` mounts one macOS folder into the remote session using the provided
`redirectedFolderName` share name. Leave it `nil` to disable local folder mounting.
`audioPlaybackMode` supports `.playLocally`, `.playOnRemote`, and `.disabled`.
`preferDeviceNativeResolution` defaults to `true` and sends Retina/5K backing pixels to the
remote side for sharper text. Set it to `false` to force 1x resize updates.
`forcedDesktopSize` locks the remote desktop to a fixed pixel size such as `1920x1080`; the
local view scales that framebuffer proportionally. `colorDepth` requests 16, 24, or 32 bpp from
FreeRDP while the Swift display path continues to receive BGRA frames.

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
RDP_MAC_LOG_FILE=/tmp/rdp-session.log \
RDP_MAC_LOG_LEVEL=debug \
RDP_MAC_LOG_FILTERS=com.freerdp.channels.cliprdr=trace \
RDP_MAC_PREFER_NATIVE_RESOLUTION=1 \
RDP_MAC_COLOR_DEPTH=32 \
RDP_MAC_FORCED_DESKTOP_SIZE=1920x1080 \
RDP_MAC_AUTOCONNECT=1 \
swift run rdp-mac
```

`RDP_MAC_AUDIO_MODE` accepts `local`, `remote`, or `off`. `RDP_MAC_AUTOCONNECT` is optional.
Without it, visible credential fields are only prefilled in the connection bar.
`RDP_MAC_LOG_FILE` is optional and appends session logs to the given path.
`RDP_MAC_LOG_LEVEL` accepts `trace`, `debug`, `info`, `warn`, `error`, `fatal`, or `off`.
`RDP_MAC_LOG_FILTERS` accepts semicolon-separated `category=level` pairs.
`RDP_MAC_PREFER_NATIVE_RESOLUTION` accepts `1`/`true` or `0`/`false` and defaults to enabled.
`RDP_MAC_COLOR_DEPTH` accepts `16`, `24`, or `32`.
`RDP_MAC_FORCED_DESKTOP_SIZE` accepts `WIDTHxHEIGHT`; omit it to keep dynamic resize enabled.

The sample app connection bar also exposes Retina, color depth, forced size, audio mode, and
redirected folder controls for manual testing.

## Test Hook

For ad hoc integration testing only, set `RDP_MAC_AUTOTEST_EXPLORER_FILE_PASTE=1`
or `RDP_MAC_AUTOTEST_EXPLORER_FOLDER_PASTE=1`.

`RDP_MAC_AUTOTEST_EXPLORER_FILE_PASTE=1` opens the remote Desktop in Explorer, offers
a small local file, pastes it, then copies the selected remote file back to the macOS
pasteboard.

`RDP_MAC_AUTOTEST_EXPLORER_FOLDER_PASTE=1` opens the remote Desktop in Explorer, offers
a temporary folder with a nested Korean-named file, and sends Ctrl+V so the remote side
requests the staged relative file paths.

## Window Close Stress

The `window-close-stress-test` executable is a non-XCTest close-path regression harness.
It requires live RDP credentials through the same `RDP_MAC_*` environment variables as the sample app.

```sh
RDP_MAC_HOST=192.168.1.10 \
RDP_MAC_PORT=3389 \
RDP_MAC_USERNAME=user \
RDP_MAC_PASSWORD=secret \
RDP_MAC_PREFER_NATIVE_RESOLUTION=1 \
RDP_MAC_COLOR_DEPTH=32 \
RDP_MAC_FORCED_DESKTOP_SIZE=1920x1080 \
RDP_WINDOW_CLOSE_STRESS_CYCLES=10 \
swift run window-close-stress-test
```

Each cycle creates an `NSWindow`, connects `RDPConnectionView`, waits briefly after connection,
calls `shutdown()`, closes the window, drains the run loop, and prints `RDPShutdownDiagnostics`.
The harness accepts the same Retina, color depth, forced size, audio, logging, and folder redirection
environment variables as the sample app.
For XCTest-based live coverage, set `RDP_WINDOW_CLOSE_INTEGRATION=1` with the same `RDP_MAC_*`
variables before running `swift test`.

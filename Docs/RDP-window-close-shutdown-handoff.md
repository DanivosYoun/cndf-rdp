# RDP Window Close Crash Fix Handoff

Target repository: `DanivosYoun/cndf-rdp`

## Summary

`RDPConnectionView` now has an explicit synchronous `shutdown()` API for host apps that present RDP
in a separate `NSWindow`. Call `shutdown()` before `window.close()` or before removing the view from
the window hierarchy.

The fix addresses a close-time SIGSEGV caused by AppKit releasing the window/content tree from
inside `NSWindow.close()` while view/layer objects still had delayed autorelease work pending. A
minimal repro showed the same `objc_release` crash with a plain programmatic `NSWindow` unless
`isReleasedWhenClosed` is disabled before close.

## Required Host App Change

Before:

```swift
window.close()
```

After:

```swift
rdpView.shutdown()
window.close()
```

`shutdown()` is one-way. Do not call `connect(_:)` again on the same `RDPConnectionView`; create a
new view for the next RDP window.

`shutdown()` returns `RDPShutdownDiagnostics` so the host app can log whether FreeRDP worker teardown
was waited, how long that wait took, how long render shutdown took, and how many queued main
callbacks remain. The `inFlightCommandBuffers` field remains for API compatibility and is `0` with
the current AppKit layer-backed renderer.

## What `shutdown()` Does

- Stops frame presentation and clears layer contents.
- Disables the current window close animation and orders the window out.
- Sets `window.isReleasedWhenClosed = false` so `window.close()` does not own final deallocation.
- Replaces the host window's content view with an inert placeholder so AppKit's later close path no
  longer owns the RDP view.
- Detaches the RDP session delegate and suppresses late callbacks.
- Synchronously disconnects the RDP session so FreeRDP worker teardown is complete when shutdown
  returns.
- Drains queued main-thread RDP view callbacks before returning when possible.

## Package Changes

- `Sources/RDPMacView/RDPConnectionView.swift`
  - Added `public func shutdown() -> RDPShutdownDiagnostics`.
  - Added `RDPShutdownDiagnostics` timing fields:
    `freeRDPWorkerWaitDurationMs` and `metalDrainDurationMs`.
  - Removed blocking session disconnect from `deinit`.
  - Added shutdown guards for reconnect, polling, frame display, and delegate callbacks.
  - Replaced async shutdown disconnect with synchronous session detach/disconnect.
  - Added queued main-callback accounting/drain.
  - Sets `window.isReleasedWhenClosed = false` before close.
  - Replaces `window.contentView` with an inert placeholder during shutdown.
- `Sources/RDPMacView/RDPClientView.swift`
  - Replaced the `MTKView` subclass with an AppKit layer-backed `NSView`.
  - Added `shutdownRendering()`.
  - Added `window == nil` guard in `viewDidMoveToWindow()`.
  - Cancels pending resize work and blocks resize/frame updates after renderer shutdown.
  - Clears layer contents, tracking areas, drag registration, and session references during shutdown.
- `Sources/RDPMacView/RDPMetalRenderer.swift`
  - Removed. The embeddable view no longer depends on `MTKView`/`CAMetalLayer` for presentation.
- `Tests/RDPMacViewTests/RDPConnectionViewLifecycleTests.swift`
  - Covers shutdown idempotence.
  - Covers connect-after-shutdown rejection.
  - Covers delegate detachment and late-callback suppression.
  - Covers shutdown diagnostics.
  - Covers repeated `RDPConnectionView` hosting in `NSWindow`, `shutdown()`, `window.close()`, and
    autorelease-drain survival.
  - Covers delayed main-queue drain past the previous 2-second release point.
  - Covers post-close release of the RDP view/window instead of process-lifetime retention.
  - Covers `isReleasedWhenClosed = false` plus content-view replacement before close.
  - Adds an env-gated live RDP integration close test:
    `RDP_WINDOW_CLOSE_INTEGRATION=1 swift test`.
- `Sources/WindowCloseStressTest/main.swift`
  - Adds standalone `window-close-stress-test` for non-XCTest close-path validation.
  - Repeats connect, shutdown, close, and run-loop drain using live `RDP_MAC_*` credentials.

## Verification

Automated:

```sh
swift test
```

Expected result: all 24 package tests pass, with the live RDP close test skipped unless
`RDP_WINDOW_CLOSE_INTEGRATION=1` is set.

Live close stress:

```sh
RDP_WINDOW_CLOSE_STRESS_CYCLES=100 swift run window-close-stress-test
```

Expected result: all 100 live connect, shutdown, close, and autorelease-drain cycles complete with
`didWait=true`, `pendingMain=0`, and `inFlight=0`; no new crash report should appear in
`~/Library/Logs/DiagnosticReports`.

Automated window-close coverage now includes 10 repeated `NSWindow` host + `shutdown()` +
`window.close()` cycles with run-loop/autorelease draining, plus a delayed drain that runs past the
previous 2-second retain-release crash point and confirms the RDP view/window can deallocate.

Manual window-close verification for terminal integration:

1. Open an RDP window that hosts `RDPConnectionView`.
2. Connect to a real RDP host and wait for at least one frame.
3. In the host close path, call `rdpView.shutdown()` and then `window.close()`.
4. Confirm the host app remains alive.
5. Repeat the sequence 10 times.
6. Repeat once more by calling `shutdown()` immediately after `connect(_:)`, before the first frame.
7. Confirm no new app crash report appears in `~/Library/Logs/DiagnosticReports`.

Standalone stress verification:

```sh
RDP_MAC_HOST=192.168.1.10 \
RDP_MAC_PORT=3389 \
RDP_MAC_USERNAME=user \
RDP_MAC_PASSWORD=secret \
RDP_WINDOW_CLOSE_STRESS_CYCLES=100 \
swift run window-close-stress-test
```

For XCTest live integration coverage:

```sh
RDP_WINDOW_CLOSE_INTEGRATION=1 \
RDP_MAC_HOST=192.168.1.10 \
RDP_MAC_PORT=3389 \
RDP_MAC_USERNAME=user \
RDP_MAC_PASSWORD=secret \
swift test --filter RDPConnectionViewLifecycleTests/testRealSessionShutdownThenWindowCloseSurvivesAutoreleaseDrain
```

## Notes

- `RDPConnectionView.disconnect()` is still available for normal in-view disconnect behavior.
- Use `shutdown()` for window/view lifetime teardown. It may block briefly while FreeRDP exits.
- The host app should not touch renderer internals after adopting this API.
- `shutdown()` does not keep a graveyard retain. It removes the RDP content tree from the window
  before close and disables close-owned release so normal host ARC/window-controller deallocation can
  happen after the close/autorelease drains.

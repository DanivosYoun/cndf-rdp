# RDP Window Close Crash Fix Handoff

Target repository: `DanivosYoun/cndf-rdp`

## Summary

`RDPConnectionView` now has an explicit `shutdown()` API for host apps that present RDP in a
separate `NSWindow`. Call `shutdown()` before `window.close()` or before removing the view from the
window hierarchy.

The fix addresses a close-time SIGSEGV caused by AppKit/Core Animation releasing a window transform
animation while Metal drawables and the `MTKView` display link were still tied to the closing window.

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

## What `shutdown()` Does

- Stops the `MTKView` display link with `isPaused = true`.
- Clears the Metal delegate.
- Clears renderer texture state.
- Calls `releaseDrawables()`.
- Removes the Metal subview from its superview.
- Disables the current window close animation and orders the window out.
- Retains the view/window for two main-runloop turns to let AppKit and Core Animation drain close
  and autorelease work safely.
- Detaches the RDP session delegate and suppresses late callbacks.
- Disconnects the RDP session on a utility queue so the window close path does not block on FreeRDP
  teardown.

## Package Changes

- `Sources/RDPMacView/RDPConnectionView.swift`
  - Added `public func shutdown()`.
  - Removed blocking session disconnect from `deinit`.
  - Added shutdown guards for reconnect, polling, frame display, and delegate callbacks.
  - Added async session detach/disconnect for shutdown.
- `Sources/RDPMacView/RDPClientView.swift`
  - Added `shutdownRendering()`.
  - Added `window == nil` guard in `viewDidMoveToWindow()`.
  - Cancels pending resize work and blocks resize/frame updates after renderer shutdown.
- `Sources/RDPMacView/RDPMetalRenderer.swift`
  - Added renderer shutdown state.
  - Clears texture/frame state and blocks further draw/update calls after shutdown.
- `Tests/RDPMacViewTests/RDPConnectionViewLifecycleTests.swift`
  - Covers shutdown idempotence.
  - Covers connect-after-shutdown rejection.
  - Covers delegate detachment and late-callback suppression.

## Verification

Automated:

```sh
swift test
```

Expected result: all 21 package tests pass.

Manual window-close verification, because `NSWindow.close()` inside XCTest can crash XCTest's own
invalid-object checker on macOS 26.4.1:

1. Open an RDP window that hosts `RDPConnectionView`.
2. Connect to a real RDP host and wait for at least one frame.
3. In the host close path, call `rdpView.shutdown()` and then `window.close()`.
4. Confirm the host app remains alive.
5. Repeat the sequence 10 times.
6. Repeat once more by calling `shutdown()` immediately after `connect(_:)`, before the first frame.
7. Confirm no new app crash report appears in `~/Library/Logs/DiagnosticReports`.

## Notes

- `RDPConnectionView.disconnect()` is still available for normal in-view disconnect behavior.
- Use `shutdown()` for window/view lifetime teardown.
- The host app should not touch `rdpView.clientView.isPaused`, `delegate`, or `releaseDrawables()`
  directly after adopting this API.

# RDP Window Close Crash Fix Handoff

Target repository: `DanivosYoun/cndf-rdp`

## Summary

`RDPConnectionView` now has an explicit synchronous `shutdown()` API for host apps that present RDP
in a separate `NSWindow`. Call `shutdown()` before `window.close()` or before removing the view from
the window hierarchy.

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

`shutdown()` returns `RDPShutdownDiagnostics` so the host app can log whether FreeRDP worker teardown
was waited, how many queued main callbacks remain, and how many Metal command buffers are still
in-flight.

## What `shutdown()` Does

- Stops the `MTKView` display link with `isPaused = true`.
- Clears the Metal delegate.
- Clears renderer texture state.
- Waits for in-flight Metal command buffers to complete.
- Calls `releaseDrawables()`.
- Removes the Metal subview from its superview.
- Disables the current window close animation and orders the window out.
- Retains the already-shut-down view/window in a process-lifetime unmanaged graveyard so AppKit and
  Core Animation never release the close path objects after `window.close()`.
- Detaches the RDP session delegate and suppresses late callbacks.
- Synchronously disconnects the RDP session so FreeRDP worker teardown is complete when shutdown
  returns.
- Drains queued main-thread RDP view callbacks before returning when possible.

## Package Changes

- `Sources/RDPMacView/RDPConnectionView.swift`
  - Added `public func shutdown() -> RDPShutdownDiagnostics`.
  - Added `RDPShutdownDiagnostics`.
  - Removed blocking session disconnect from `deinit`.
  - Added shutdown guards for reconnect, polling, frame display, and delegate callbacks.
  - Replaced async shutdown disconnect with synchronous session detach/disconnect.
  - Added queued main-callback accounting/drain.
  - Added a process-lifetime unmanaged close-context graveyard for the already-shut-down
    view/window shell.
- `Sources/RDPMacView/RDPClientView.swift`
  - Added `shutdownRendering()`.
  - Added `window == nil` guard in `viewDidMoveToWindow()`.
  - Cancels pending resize work and blocks resize/frame updates after renderer shutdown.
- `Sources/RDPMacView/RDPMetalRenderer.swift`
  - Added renderer shutdown state.
  - Tracks in-flight command buffers and waits during shutdown.
  - Clears texture/frame state and blocks further draw/update calls after shutdown.
- `Tests/RDPMacViewTests/RDPConnectionViewLifecycleTests.swift`
  - Covers shutdown idempotence.
  - Covers connect-after-shutdown rejection.
  - Covers delegate detachment and late-callback suppression.
  - Covers shutdown diagnostics.
  - Covers repeated `RDPConnectionView` hosting in `NSWindow`, `shutdown()`, `window.close()`, and
    autorelease-drain survival.
  - Covers delayed main-queue drain past the previous 2-second release point.

## Verification

Automated:

```sh
swift test
```

Expected result: all 23 package tests pass.

Automated window-close coverage now includes 10 repeated `NSWindow` host + `shutdown()` +
`window.close()` cycles with run-loop/autorelease draining, plus a delayed drain that runs past the
previous 2-second retain-release crash point.

Manual window-close verification for terminal integration:

1. Open an RDP window that hosts `RDPConnectionView`.
2. Connect to a real RDP host and wait for at least one frame.
3. In the host close path, call `rdpView.shutdown()` and then `window.close()`.
4. Confirm the host app remains alive.
5. Repeat the sequence 10 times.
6. Repeat once more by calling `shutdown()` immediately after `connect(_:)`, before the first frame.
7. Confirm no new app crash report appears in `~/Library/Logs/DiagnosticReports`.

## Notes

- `RDPConnectionView.disconnect()` is still available for normal in-view disconnect behavior.
- Use `shutdown()` for window/view lifetime teardown. It may block briefly while FreeRDP exits.
- The host app should not touch `rdpView.clientView.isPaused`, `delegate`, or `releaseDrawables()`
  directly after adopting this API.
- `shutdown()` intentionally retains the closed `NSWindow` plus `RDPConnectionView` shell for the
  rest of the process. The RDP session, Metal renderer, drawables, delegates, and clipboard timer
  are already detached, so this trades a small bounded-per-window shell leak for crash-free close
  behavior on macOS 26.4.1.

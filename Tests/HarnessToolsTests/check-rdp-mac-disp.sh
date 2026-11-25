#!/usr/bin/env bash
# Run the example app's real delegate callback with local stand-ins for its UI.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source_file="${1:-$root/Sources/RDPMacApp/main.swift}"
scratch="$(mktemp -d "$root/.rdp-mac-disp-test.XXXXXXXX")"
trap 'rmdir "$scratch" 2>/dev/null || { unlink "$scratch/probe.swift"; rmdir "$scratch"; }' EXIT
{
  cat <<'SWIFT'
import Foundation
class RDPEngineSession { var isConnected = true }
class ConnectionBar {
    func setStatus(_ message: String) {}
    func setConnected(_ connected: Bool) {}
}
class ClientView {
    var resizeRequests = 0
    func sendForcedDesktopSize() { resizeRequests += 1 }
}
class AppDelegate {
    var connectionBar: ConnectionBar? = ConnectionBar()
    var clientView: ClientView? = ClientView()
    var filePasteRequests = 0
    var folderPasteRequests = 0
    func runExplorerFilePasteAutotestIfNeeded() { filePasteRequests += 1 }
    func runExplorerFolderPasteAutotestIfNeeded() { folderPasteRequests += 1 }
SWIFT
  sed -n '/^    func rdpSession(_ session: RDPEngineSession, didLog message: String) {$/,/^    }$/p' "$source_file"
  cat <<'SWIFT'
}
let app = AppDelegate()
let session = RDPEngineSession()
app.rdpSession(session, didLog: "IronRDP connected.")
app.rdpSession(session, didLog: "Display control capabilities received: maxMonitors=16 maxArea=1073741824.")
DispatchQueue.main.async {
    let passed = app.clientView?.resizeRequests == 2
        && app.filePasteRequests == 1 && app.folderPasteRequests == 1
    if !passed { print("DISP capability log did not trigger resize and both paste checks") }
    exit(passed ? 0 : 1)
}
dispatchMain()
SWIFT
} > "$scratch/probe.swift"
swift "$scratch/probe.swift"

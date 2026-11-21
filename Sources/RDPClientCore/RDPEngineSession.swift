import CoreGraphics
import Foundation

/// The session surface `RDPConnectionView`, `RDPClientView` and the input executor use. Each
/// engine (`RDPSession` for FreeRDP, `IronRDPSession`) adopts it; callers never branch on the
/// engine except to read `engine` and the `supports…` capabilities.
public protocol RDPEngineSession: AnyObject {
    var engine: RDPEngineKind { get }
    var delegate: RDPSessionDelegate? { get set }
    var isConnected: Bool { get }
    /// Identifies a native connection attempt, including reconnects on this session.
    var connectionGeneration: UInt64 { get }
    func isInputConnectionCurrent(generation: UInt64) -> Bool
    /// Keeps an input transaction on its original connection across reconnect races.
    func withInputConnection(generation: UInt64, _ body: () throws -> Void) throws
    var statistics: RDPConnectionStatistics { get }
    /// The keyboard profile of the latest `connect`; `.standard` before the first. Read on the
    /// main thread for each key event, so it never waits for a connect in progress.
    var keyboardProfile: RDPKeyboardProfile { get }

    func connect(_ options: RDPConnectionOptions, initialPointSize: CGSize, scale: Double) throws
    func reconnect() throws
    func disconnect() throws

    /// False when the engine has no clipboard channel; the clipboard calls below then do nothing
    /// (`pollLocalClipboard`) or throw.
    var supportsClipboard: Bool { get }
    func pollLocalClipboard() throws
    func sendLocalFiles(_ urls: [URL]) throws
    func sendLocalText(_ text: String) throws

    func updateDesktopSize(pointWidth: Double, pointHeight: Double, scale: Double, force: Bool) throws
    var supportsOutputSuppression: Bool { get }
    func setOutputSuppressed(_ suppressed: Bool) throws

    func sendPointerMove(_ location: RDPPointerLocation) throws
    func sendPointerButton(_ button: RDPPointerButton, at location: RDPPointerLocation, pressed: Bool) throws
    @discardableResult
    func sendScroll(at location: RDPPointerLocation, deltaX: Int32, deltaY: Int32) throws -> Bool
    func sendKey(keyCode: UInt16, pressed: Bool, extended: Bool) throws
    func sendUnicode(code: UInt16, pressed: Bool) throws
}

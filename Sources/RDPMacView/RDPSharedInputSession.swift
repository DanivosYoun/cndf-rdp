import Foundation
import RDPClientCore

public enum RDPSharedInputCommand: Sendable {
    case key(scanCode: UInt16, pressed: Bool, modifiers: [UInt16])
    case mouse(x: Int32, y: Int32, button: RDPMouseButton?, flags: RDPMouseFlags, modifiers: [UInt16])
    case scroll(x: Int32, y: Int32, deltaY: Int32, deltaX: Int32, modifiers: [UInt16])
    case modifiers([UInt16])
    case chord([UInt16])
}

public enum RDPSharedInputCloseFailure: Sendable, Equatable {
    case connectionLost
    case sendFailed
}

public enum RDPSharedInputCloseResult: Sendable, Equatable {
    case released
    case failed(RDPSharedInputCloseFailure)
}

/// One share's input lifetime on one native connection.
///
/// The handle only carries identity and lifecycle. Admission of queued commands, the record of
/// what was actually sent, and the release on close all live in the connection's
/// `RDPInputExecutor`, on the same queue that performs the final native send.
public final class RDPSharedInputSession: @unchecked Sendable {
    private enum State {
        case prepared
        case active
        case closing
        case closed(RDPSharedInputCloseResult)
    }

    private let lock = NSLock()
    private var state: State
    private var waiters: [CheckedContinuation<RDPSharedInputCloseResult, Never>] = []
    private let executor: RDPInputExecutor?
    private let owner: RDPInputOwner
    private let connectionLifetime: AnyObject?

    init(executor: RDPInputExecutor, owner: RDPInputOwner) {
        self.executor = executor
        self.owner = owner
        self.state = .prepared
        self.connectionLifetime = executor.connectionLifetime
    }

    private init() {
        self.executor = nil
        self.owner = .shared(0)
        self.state = .closed(.failed(.connectionLost))
        self.connectionLifetime = nil
    }

    /// A handle for a view without a usable connection: never active, always connection lost.
    static func unavailable() -> RDPSharedInputSession {
        RDPSharedInputSession()
    }

    /// Opens the handle for input. Only a prepared handle on a healthy connection can activate,
    /// and a handle never activates again once it has begun closing.
    public func activate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .prepared = state, let executor, executor.canActivateSharing else {
            return false
        }
        state = .active
        return true
    }

    /// Accepting a command only reserves its execution; it says nothing about the remote side.
    public func submit(_ command: RDPSharedInputCommand) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .active = state, let executor else {
            return false
        }
        executor.submitShared(command, owner: owner) { [self] in
            isAcceptingExecution()
        }
        return true
    }

    /// Synchronously stops acceptance and execution of this handle's queued commands and
    /// schedules the release of what it holds. Repeated calls are no-ops.
    public func beginClose() {
        lock.lock()
        let wasActive: Bool
        switch state {
        case .prepared:
            wasActive = false
            state = .closing
        case .active:
            wasActive = true
            state = .closing
        case .closing, .closed:
            lock.unlock()
            return
        }
        lock.unlock()
        executor?.submitCleanup(owner: owner, wasActive: wasActive) { [self] result in
            complete(with: result)
        }
    }

    /// Waits for the release scheduled by `beginClose()`. Cancelling the caller does not cancel
    /// the release; every caller receives the same result.
    public func finishClose() async -> RDPSharedInputCloseResult {
        beginClose()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if case .closed(let result) = state {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func isAcceptingExecution() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .active = state {
            return true
        }
        return false
    }

    private func complete(with result: RDPSharedInputCloseResult) {
        lock.lock()
        guard case .closing = state else {
            lock.unlock()
            return
        }
        state = .closed(result)
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }
}

// MARK: - Native connection seam

/// The final native sender. Production binds it to one `RDPSession` connection generation;
/// tests substitute a recording fake.
protocol RDPInputSending: AnyObject {
    var connectionLifetime: AnyObject? { get }
    var isConnected: Bool { get }
    /// Runs `body` as one uninterrupted unit on the connection this sender is bound to. Returns
    /// false, without running `body`, when that connection is gone or has been replaced.
    func perform(_ body: () -> Void) -> Bool
    func sendKey(keyCode: UInt16, pressed: Bool, extended: Bool) throws
    func sendUnicode(code: UInt16, pressed: Bool) throws
    func sendPointerMove(_ location: RDPPointerLocation) throws
    func sendPointerButton(_ button: RDPPointerButton, at location: RDPPointerLocation, pressed: Bool) throws
    func sendScroll(at location: RDPPointerLocation, deltaX: Int32, deltaY: Int32) throws
}

extension RDPInputSending {
    var connectionLifetime: AnyObject? { nil }
}

final class RDPSessionInputSender: RDPInputSending {
    weak var session: RDPSession?
    var connectionLifetime: AnyObject? { session }
    let generation: UInt64

    init(session: RDPSession, generation: UInt64? = nil) {
        self.session = session
        self.generation = generation ?? session.connectionGeneration
    }

    var isConnected: Bool {
        guard let session else { return false }
        return session.isInputConnectionCurrent(generation: generation)
    }

    func perform(_ body: () -> Void) -> Bool {
        guard let session else { return false }
        do {
            try session.withInputConnection(generation: generation) {
                body()
            }
            return true
        } catch {
            return false
        }
    }

    func sendKey(keyCode: UInt16, pressed: Bool, extended: Bool) throws {
        guard let session else { throw RDPSessionError.unableToCreateBridgeSession }
        try session.sendKey(keyCode: keyCode, pressed: pressed, extended: extended)
    }

    func sendUnicode(code: UInt16, pressed: Bool) throws {
        guard let session else { throw RDPSessionError.unableToCreateBridgeSession }
        try session.sendUnicode(code: code, pressed: pressed)
    }

    func sendPointerMove(_ location: RDPPointerLocation) throws {
        guard let session else { throw RDPSessionError.unableToCreateBridgeSession }
        try session.sendPointerMove(location)
    }

    func sendPointerButton(_ button: RDPPointerButton, at location: RDPPointerLocation, pressed: Bool) throws {
        guard let session else { throw RDPSessionError.unableToCreateBridgeSession }
        try session.sendPointerButton(button, at: location, pressed: pressed)
    }

    func sendScroll(at location: RDPPointerLocation, deltaX: Int32, deltaY: Int32) throws {
        guard let session else { throw RDPSessionError.unableToCreateBridgeSession }
        try session.sendScroll(at: location, deltaX: deltaX, deltaY: deltaY)
    }
}

/// Retains connection state across view detachments without retaining the session itself.
/// A share handle separately retains its session until its queued cleanup completes.
final class RDPInputExecutorRegistry {
    private final class Binding {
        let generation: UInt64
        let executor: RDPInputExecutor
        init(generation: UInt64, executor: RDPInputExecutor) {
            self.generation = generation
            self.executor = executor
        }
    }
    private static let lock = NSLock()
    private static let bindings = NSMapTable<RDPSession, Binding>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func executor(
        for session: RDPSession,
        generation: UInt64? = nil,
        schedule: @escaping (@escaping () -> Void) -> Void,
        makeSender: (RDPSession, UInt64) -> RDPInputSending = { RDPSessionInputSender(session: $0, generation: $1) }
    ) -> RDPInputExecutor {
        let generation = generation ?? session.connectionGeneration
        lock.lock()
        defer { lock.unlock() }
        if let binding = bindings.object(forKey: session) {
            if binding.generation == generation { return binding.executor }
            // A request may have captured its generation before a reconnect. It must not
            // replace the newer connection's ownership record or failure block.
            if binding.generation > generation {
                return RDPInputExecutor(sender: makeSender(session, generation), schedule: schedule)
            }
        }
        let executor = RDPInputExecutor(sender: makeSender(session, generation), schedule: schedule)
        bindings.setObject(Binding(generation: generation, executor: executor), forKey: session)
        return executor
    }
}

// MARK: - Executor

enum RDPInputOwner: Hashable {
    case host
    case shared(UInt64)
}

/// Key identity as it goes on the wire: the extended bit is part of it.
enum RDPInputKey: Hashable {
    case scancode(UInt16, extended: Bool)
    case unicode(UInt16)

    static func fromScancode(_ code: UInt16, extended: Bool = false) -> RDPInputKey {
        .scancode(code & 0xFF, extended: extended || (code & 0x100) != 0)
    }
}

private enum RDPInputButton: Int {
    case left
    case right
    case middle

    init(_ button: RDPPointerButton) {
        switch button {
        case .left: self = .left
        case .right: self = .right
        case .middle: self = .middle
        }
    }

    var pointerButton: RDPPointerButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .middle
        }
    }
}

private struct RDPHeldInputs {
    struct Button {
        let button: RDPInputButton
        let location: RDPPointerLocation
    }

    var buttons: [Button] = []
    var keys: [RDPInputKey] = []
    var modifiers: [RDPInputKey] = []

    var isEmpty: Bool {
        buttons.isEmpty && keys.isEmpty && modifiers.isEmpty
    }

    func holds(_ key: RDPInputKey) -> Bool {
        keys.contains(key) || modifiers.contains(key)
    }

    func holds(_ button: RDPInputButton) -> Bool {
        buttons.contains { $0.button == button }
    }
}

extension RDPPointerLocation {
    init(clampingX x: Int32, y: Int32) {
        self.init(pixelX: UInt32(max(0, x)), pixelY: UInt32(max(0, y)))
    }
}

extension RDPMouseButton {
    var pointerButton: RDPPointerButton {
        switch self {
        case .left:
            return .left
        case .right:
            return .right
        case .middle:
            return .middle
        }
    }
}

/// The last executor of input for one native connection. Everything the local view and every
/// share handle send goes through one instance, so a single record of actually-sent keys and
/// buttons, with its owners, decides what is released and what is left held.
///
/// Work is scheduled onto `schedule`, which must run it serially; the held-input record and the
/// pointer position are only touched from that work. A unit of work is one native transaction:
/// it runs to completion before anything queued after it, including a share's release.
final class RDPInputExecutor: @unchecked Sendable {
    private let sender: RDPInputSending
    private let schedule: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var shareBlocked = false
    private var failures: [RDPInputOwner: RDPSharedInputCloseFailure] = [:]
    private var executingOwner: RDPInputOwner = .host
    private var nextSharedOwner: UInt64 = 0

    private var held: [RDPInputOwner: RDPHeldInputs] = [:]
    private var lastPointer: RDPPointerLocation?

    init(sender: RDPInputSending, schedule: @escaping (@escaping () -> Void) -> Void) {
        self.sender = sender
        self.schedule = schedule
    }

    var connectionLifetime: AnyObject? { sender.connectionLifetime }

    // MARK: Shares

    /// False once any send on this connection failed or the connection is gone. A blocked
    /// connection stays blocked; sharing resumes on a new executor after reconnect.
    var canActivateSharing: Bool {
        lock.lock()
        let blocked = shareBlocked
        lock.unlock()
        return !blocked && sender.isConnected
    }

    func makeSharedSession() -> RDPSharedInputSession {
        lock.lock()
        nextSharedOwner += 1
        let owner = RDPInputOwner.shared(nextSharedOwner)
        lock.unlock()
        return RDPSharedInputSession(executor: self, owner: owner)
    }

    func submitShared(
        _ command: RDPSharedInputCommand,
        owner: RDPInputOwner,
        isAccepting: @escaping () -> Bool
    ) {
        schedule { [self] in
            // A discarded command touches no pointer, modifier or held-input state.
            guard isAccepting() else {
                return
            }
            executingOwner = owner
            if !sender.perform({ run(command, owner: owner) }) {
                failures[owner] = .connectionLost
                blockSharing()
            }
        }
    }

    func submitCleanup(owner: RDPInputOwner, wasActive: Bool, completion: @escaping (RDPSharedInputCloseResult) -> Void) {
        schedule { [self] in
            completion(close(owner, wasActive: wasActive))
        }
    }

    // MARK: Local view input

    func hostKey(scanCode: UInt16, extended: Bool = false, pressed: Bool, asModifier: Bool = false) {
        submitHost { [self] in
            let key = RDPInputKey.fromScancode(scanCode, extended: extended)
            if pressed {
                pressKey(.host, key, asModifier: asModifier)
            } else {
                releaseKey(.host, key)
            }
        }
    }

    func hostModifiers(_ scanCodes: [UInt16]) {
        submitHost { [self] in syncModifiers(.host, to: scanCodes) }
    }

    func hostUnicode(code: UInt16, pressed: Bool) {
        submitHost { [self] in
            if pressed {
                pressKey(.host, .unicode(code))
            } else {
                releaseKey(.host, .unicode(code))
            }
        }
    }

    func hostInjectKey(scanCode: UInt16, flags: RDPKeyFlags) {
        let extended = flags.contains(.extended)
        submitHost { [self] in
            let key = RDPInputKey.fromScancode(scanCode, extended: extended)
            if flags.contains(.down) {
                pressKey(.host, key)
            }
            if flags.contains(.up) {
                releaseKey(.host, key)
            }
        }
    }

    func hostPointerMove(_ location: RDPPointerLocation) {
        submitHost { [self] in
            move(to: location)
        }
    }

    func hostPointerButton(_ button: RDPPointerButton, at location: RDPPointerLocation, pressed: Bool) {
        submitHost { [self] in
            if pressed {
                pressButton(.host, RDPInputButton(button), at: location)
            } else {
                releaseButton(.host, RDPInputButton(button), at: location)
            }
        }
    }

    func hostMouse(x: Int32, y: Int32, button: RDPMouseButton?, flags: RDPMouseFlags) {
        let location = RDPPointerLocation(clampingX: x, y: y)
        submitHost { [self] in
            mouse(.host, at: location, button: button, flags: flags)
        }
    }

    func hostScroll(at location: RDPPointerLocation, deltaX: Int32, deltaY: Int32) {
        submitHost { [self] in
            scroll(at: location, deltaX: deltaX, deltaY: deltaY)
        }
    }

    func hostChord(_ scanCodes: [UInt16]) {
        submitHost { [self] in
            chord(.host, scanCodes)
        }
    }

    private func submitHost(_ body: @escaping () -> Void) {
        schedule { [self] in
            executingOwner = .host
            _ = sender.perform(body)
        }
    }

    // MARK: Commands

    private func run(_ command: RDPSharedInputCommand, owner: RDPInputOwner) {
        switch command {
        case let .key(scanCode, pressed, modifiers):
            let key = RDPInputKey.fromScancode(scanCode)
            if pressed {
                syncModifiers(owner, to: modifiers)
                pressKey(owner, key)
            } else {
                releaseKey(owner, key)
                syncModifiers(owner, to: modifiers)
            }
        case let .mouse(x, y, button, flags, modifiers):
            syncModifiers(owner, to: modifiers)
            mouse(owner, at: RDPPointerLocation(clampingX: x, y: y), button: button, flags: flags)
        case let .scroll(x, y, deltaY, deltaX, modifiers):
            syncModifiers(owner, to: modifiers)
            scroll(at: RDPPointerLocation(clampingX: x, y: y), deltaX: deltaX, deltaY: deltaY)
        case let .modifiers(modifiers):
            syncModifiers(owner, to: modifiers)
        case let .chord(scanCodes):
            chord(owner, scanCodes)
        }
    }

    private func mouse(_ owner: RDPInputOwner, at location: RDPPointerLocation, button: RDPMouseButton?, flags: RDPMouseFlags) {
        if flags.contains(.move) {
            move(to: location)
        }
        guard let button = button.map({ RDPInputButton($0.pointerButton) }) else {
            return
        }
        if flags.contains(.down) {
            pressButton(owner, button, at: location)
        }
        if flags.contains(.up) {
            releaseButton(owner, button, at: location)
        }
    }

    /// Brings the owner's held modifiers to exactly `desired`: releases first in reverse press
    /// order, then presses the missing ones in the requested order.
    private func syncModifiers(_ owner: RDPInputOwner, to desired: [UInt16]) {
        var wanted: [RDPInputKey] = []
        for code in desired {
            let key = RDPInputKey.fromScancode(code)
            if !wanted.contains(key) {
                wanted.append(key)
            }
        }
        for key in (held[owner]?.modifiers ?? []).reversed() where !wanted.contains(key) {
            releaseKey(owner, key)
        }
        for key in wanted where !(held[owner]?.modifiers.contains(key) ?? false) {
            pressKey(owner, key, asModifier: true)
        }
    }

    /// Presses in order and releases in reverse, leaving anything the owner already held alone.
    private func chord(_ owner: RDPInputOwner, _ scanCodes: [UInt16]) {
        var pressed: [RDPInputKey] = []
        for code in scanCodes {
            let key = RDPInputKey.fromScancode(code)
            if (held[owner]?.holds(key) ?? false) || pressed.contains(key) {
                continue
            }
            pressKey(owner, key)
            pressed.append(key)
        }
        for key in pressed.reversed() {
            releaseKey(owner, key)
        }
    }

    // MARK: Held-input record

    /// Records the owner as responsible even when the send failed: whether the remote saw the
    /// DOWN is unknown, so the UP stays owed.
    private func pressKey(_ owner: RDPInputOwner, _ key: RDPInputKey, asModifier: Bool = false) {
        _ = attempt { try sendKey(key, pressed: true) }
        var inputs = held[owner] ?? RDPHeldInputs()
        if !inputs.holds(key) {
            if asModifier {
                inputs.modifiers.append(key)
            } else {
                inputs.keys.append(key)
            }
        }
        held[owner] = inputs
    }

    /// The remote key goes up only when no other owner still holds it; a failed UP keeps the
    /// owner responsible.
    private func releaseKey(_ owner: RDPInputOwner, _ key: RDPInputKey) {
        let heldElsewhere = held.contains { $0.key != owner && $0.value.holds(key) }
        guard heldElsewhere || attempt({ try sendKey(key, pressed: false) }) else {
            return
        }
        guard var inputs = held[owner] else {
            return
        }
        inputs.keys.removeAll { $0 == key }
        inputs.modifiers.removeAll { $0 == key }
        held[owner] = inputs.isEmpty ? nil : inputs
    }

    private func pressButton(_ owner: RDPInputOwner, _ button: RDPInputButton, at location: RDPPointerLocation) {
        if attempt({ try sender.sendPointerButton(button.pointerButton, at: location, pressed: true) }) {
            lastPointer = location
        }
        var inputs = held[owner] ?? RDPHeldInputs()
        if !inputs.holds(button) {
            inputs.buttons.append(RDPHeldInputs.Button(button: button, location: location))
        }
        held[owner] = inputs
    }

    private func releaseButton(_ owner: RDPInputOwner, _ button: RDPInputButton, at location: RDPPointerLocation) {
        let heldElsewhere = held.contains { $0.key != owner && $0.value.holds(button) }
        if !heldElsewhere {
            guard attempt({ try sender.sendPointerButton(button.pointerButton, at: location, pressed: false) }) else {
                return
            }
            lastPointer = location
        }
        guard var inputs = held[owner] else {
            return
        }
        inputs.buttons.removeAll { $0.button == button }
        held[owner] = inputs.isEmpty ? nil : inputs
    }

    private func move(to location: RDPPointerLocation) {
        if attempt({ try sender.sendPointerMove(location) }) {
            lastPointer = location
        }
    }

    private func scroll(at location: RDPPointerLocation, deltaX: Int32, deltaY: Int32) {
        if attempt({ try sender.sendScroll(at: location, deltaX: deltaX, deltaY: deltaY) }) {
            lastPointer = location
        }
    }

    private func sendKey(_ key: RDPInputKey, pressed: Bool) throws {
        switch key {
        case let .scancode(code, extended):
            try sender.sendKey(keyCode: code, pressed: pressed, extended: extended)
        case let .unicode(code):
            try sender.sendUnicode(code: code, pressed: pressed)
        }
    }

    /// Shared send failures leave the share state uncertain until this connection is replaced.
    private func attempt(_ send: () throws -> Void) -> Bool {
        do {
            try send()
            return true
        } catch {
            failures[executingOwner] = sender.isConnected ? .sendFailed : .connectionLost
            if case .shared = executingOwner {
                blockSharing()
            }
            return false
        }
    }

    private func blockSharing() {
        lock.lock()
        shareBlocked = true
        lock.unlock()
    }

    private func recordCloseResult(_ result: RDPSharedInputCloseResult) -> RDPSharedInputCloseResult {
        if case .failed = result { blockSharing() }
        return result
    }

    // MARK: Close

    /// Releases what the owner holds: buttons and ordinary keys first, then modifiers in
    /// reverse press order, at the last pointer position actually sent.
    private func close(_ owner: RDPInputOwner, wasActive: Bool) -> RDPSharedInputCloseResult {
        guard wasActive else { return .released }
        executingOwner = owner
        guard let inputs = held[owner], !inputs.isEmpty else {
            held[owner] = nil
            return recordCloseResult(failures[owner].map { .failed($0) } ?? (sender.isConnected ? .released : .failed(.connectionLost)))
        }
        let ran = sender.perform { [self] in
            for entry in inputs.buttons where held[owner]?.holds(entry.button) ?? false {
                releaseButton(owner, entry.button, at: lastPointer ?? entry.location)
            }
            for key in inputs.keys where held[owner]?.holds(key) ?? false {
                releaseKey(owner, key)
            }
            for key in inputs.modifiers.reversed() where held[owner]?.holds(key) ?? false {
                releaseKey(owner, key)
            }
        }
        if held[owner] == nil {
            return recordCloseResult(failures[owner].map { .failed($0) } ?? .released)
        }
        return recordCloseResult(.failed(ran && sender.isConnected ? .sendFailed : .connectionLost))
    }
}

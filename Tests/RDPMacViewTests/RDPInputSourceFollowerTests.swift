import AppKit
import XCTest
@testable import RDPMacView

final class RDPInputSourceFollowerTests: XCTestCase {
    // MARK: F0b confirmed defaults

    func testF0bConfirmedDefaultIntervals() {
        XCTAssertEqual(RDPInputSourceFollower.defaultSettleInterval, 0.600, accuracy: 0.000_1)
        XCTAssertEqual(RDPInputSourceFollower.defaultMergeInterval, 0.300, accuracy: 0.000_1)
        let follower = RDPInputSourceFollower()
        XCTAssertEqual(follower.settleInterval, 0.600, accuracy: 0.000_1)
        XCTAssertEqual(follower.mergeInterval, 0.300, accuracy: 0.000_1)
    }

    // MARK: I-F2 language classification

    func testLanguageClassificationMatchesKoreanPrefixesOnly() {
        XCTAssertEqual(RDPMacInputSourceReader.classifyLanguage(from: ["ko"]), .korean)
        XCTAssertEqual(RDPMacInputSourceReader.classifyLanguage(from: ["ko-KR"]), .korean)
        XCTAssertEqual(RDPMacInputSourceReader.classifyLanguage(from: ["KO-Kore", "en"]), .korean)
        XCTAssertEqual(RDPMacInputSourceReader.classifyLanguage(from: ["en"]), .other)
        XCTAssertEqual(RDPMacInputSourceReader.classifyLanguage(from: ["en-US", "ko"]), .other)
        XCTAssertEqual(RDPMacInputSourceReader.classifyLanguage(from: ["ja"]), .other)
        XCTAssertEqual(RDPMacInputSourceReader.classifyLanguage(from: ["kok"]), .other)
        XCTAssertEqual(RDPMacInputSourceReader.classifyLanguage(from: []), .other)
    }

    func testSameClassificationChangesSendNothing() {
        var follower = RDPInputSourceFollower()
        follower.focusGained(at: 10.0, language: .korean)
        follower.settleElapsed(at: 10.6, language: .korean)

        // 2-bulsik -> 3-bulsik (both Korean)
        XCTAssertEqual(follower.observe(.korean, at: 11.0, cause: .async), .none(.unchanged))
        XCTAssertEqual(follower.observe(.korean, at: 11.1, cause: .async), .none(.unchanged))

        // Flip to other (ABC), then US, then Japanese (all other)
        XCTAssertEqual(follower.observe(.other, at: 12.0, cause: .async), .sendToggle(.languageFlipped))
        XCTAssertEqual(follower.observe(.other, at: 12.5, cause: .async), .none(.unchanged))
        XCTAssertEqual(follower.observe(.other, at: 13.0, cause: .async), .none(.unchanged))
    }

    // MARK: Focus, settle window, and parity (I-F3, I-F8, F0b)

    func testUnfocusedObservationsSendNothingAndRefocusRebaselinesWithoutToggle() {
        var follower = RDPInputSourceFollower()
        XCTAssertEqual(follower.observe(.korean, at: 1.0, cause: .async), .none(.unfocused))
        XCTAssertEqual(follower.observe(.other, at: 2.0, cause: .async), .none(.unfocused))

        follower.focusGained(at: 5.0, language: .other)
        follower.settleElapsed(at: 5.6, language: .other)
        XCTAssertEqual(follower.observe(.korean, at: 6.0, cause: .async), .sendToggle(.languageFlipped))

        follower.focusLost()
        XCTAssertNil(follower.baseline)
        XCTAssertEqual(follower.observe(.other, at: 7.0, cause: .async), .none(.unfocused))

        // Refocus with a different language than before focusLost: still 0 toggles (I-F8).
        follower.focusGained(at: 8.0, language: .other)
        follower.settleElapsed(at: 8.6, language: .other)
        XCTAssertEqual(follower.observe(.other, at: 9.0, cause: .async), .none(.unchanged))
        XCTAssertEqual(follower.observe(.korean, at: 9.1, cause: .async), .sendToggle(.languageFlipped))
    }

    func testSettleWindowAbsorbsAsyncChangesAndRebaselinesAtEnd() {
        var follower = RDPInputSourceFollower()
        follower.focusGained(at: 10.0, language: .other)

        // Observed F0b focus notifications around 285-292 ms and up to 599 ms stay in settle.
        XCTAssertEqual(follower.observe(.korean, at: 10.292, cause: .async), .none(.settling))
        XCTAssertEqual(follower.baseline, .korean)
        XCTAssertEqual(follower.observe(.other, at: 10.599, cause: .async), .none(.settling))
        XCTAssertEqual(follower.baseline, .other)

        // Late change absorbed at settleElapsed.
        follower.settleElapsed(at: 10.600, language: .korean)
        XCTAssertEqual(follower.baseline, .korean)
        XCTAssertEqual(follower.observe(.korean, at: 10.650, cause: .async), .none(.unchanged))

        // Real flip after T_settle sends toggle.
        XCTAssertEqual(follower.observe(.other, at: 10.700, cause: .async), .sendToggle(.languageFlipped))
    }

    func testSwitchKeyCauseBypassesSettleWindow() {
        var follower = RDPInputSourceFollower()
        follower.focusGained(at: 10.0, language: .other)

        // Inside T_settle (100 ms), sync switchKey still toggles.
        XCTAssertEqual(follower.observe(.korean, at: 10.100, cause: .switchKey), .sendToggle(.languageFlipped))
        XCTAssertEqual(follower.baseline, .korean)
    }

    func testDuplicateAndCoalescedNotificationsKeepParity() {
        var follower = RDPInputSourceFollower()
        follower.focusGained(at: 0.0, language: .other)
        follower.settleElapsed(at: 0.6, language: .other)

        // F0b: one switch fires two TIS notifications 2-10 ms apart.
        XCTAssertEqual(follower.observe(.korean, at: 1.000, cause: .async), .sendToggle(.languageFlipped))
        XCTAssertEqual(follower.observe(.korean, at: 1.005, cause: .async), .none(.unchanged))
        XCTAssertEqual(follower.observe(.korean, at: 1.010, cause: .async), .none(.unchanged))

        // Coalesced rapid ko -> other -> ko where only final ko is observed -> 0 toggles.
        XCTAssertEqual(follower.observe(.korean, at: 2.000, cause: .async), .none(.unchanged))

        // Both transitions observed -> 2 toggles.
        XCTAssertEqual(follower.observe(.other, at: 3.000, cause: .async), .sendToggle(.languageFlipped))
        XCTAssertEqual(follower.observe(.korean, at: 3.050, cause: .async), .sendToggle(.languageFlipped))
    }

    // MARK: R4 & R6 raw toggle merging and suppression (I-F1)

    func testRawToggleMergesFirstAsyncFlipWithinMergeWindowAndIgnoresUnchangedNotifications() {
        var follower = RDPInputSourceFollower()
        follower.focusGained(at: 0.0, language: .other)
        follower.settleElapsed(at: 0.6, language: .other)

        follower.rawToggleBegan(at: 1.000)
        follower.rawToggleEnded(at: 1.050)

        // F0b: unchanged notification 6 ms after press must not consume the R4 merge slot.
        XCTAssertEqual(follower.observe(.other, at: 1.056, cause: .async), .none(.unchanged))

        // First async flip within T_merge (300 ms after 1.050 = 1.350) is merged.
        XCTAssertEqual(follower.observe(.korean, at: 1.250, cause: .async), .none(.mergedWithRawToggle))
        XCTAssertEqual(follower.baseline, .korean)

        // A second distinct flip even within T_merge is not merged.
        XCTAssertEqual(follower.observe(.other, at: 1.300, cause: .async), .sendToggle(.languageFlipped))
    }

    func testRawToggleAsyncFlipAfterMergeWindowSendsToggle() {
        var follower = RDPInputSourceFollower()
        follower.focusGained(at: 0.0, language: .other)
        follower.settleElapsed(at: 0.6, language: .other)

        follower.rawToggleBegan(at: 1.000)
        follower.rawToggleEnded(at: 1.050)

        // At 1.050 + 0.300 = 1.350, merge window has elapsed.
        XCTAssertEqual(follower.observe(.korean, at: 1.350, cause: .async), .sendToggle(.languageFlipped))
    }

    func testAsyncToggleSuppressesFollowingRawToggleWithinMergeWindowOnly() {
        var follower = RDPInputSourceFollower()
        follower.focusGained(at: 0.0, language: .other)
        follower.settleElapsed(at: 0.6, language: .other)

        XCTAssertFalse(follower.shouldSuppressRawToggle(at: 1.000))
        XCTAssertEqual(follower.observe(.korean, at: 1.000, cause: .async), .sendToggle(.languageFlipped))
        XCTAssertTrue(follower.shouldSuppressRawToggle(at: 1.000))
        XCTAssertTrue(follower.shouldSuppressRawToggle(at: 1.299))
        XCTAssertFalse(follower.shouldSuppressRawToggle(at: 1.300))
    }

    func testSwitchKeyToggleDoesNotSuppressFollowingRawToggle() {
        var follower = RDPInputSourceFollower()
        follower.focusGained(at: 0.0, language: .other)
        follower.settleElapsed(at: 0.6, language: .other)

        XCTAssertEqual(follower.observe(.korean, at: 1.000, cause: .switchKey), .sendToggle(.languageFlipped))
        XCTAssertFalse(follower.shouldSuppressRawToggle(at: 1.050))
    }

    // MARK: Symbolic hotkeys parser

    func testSymbolicHotKeysParserHandlesDefaultsCustomAndDisabled() {
        // Missing / nil -> default Control+Space and Control+Option+Space.
        let fallback = RDPSymbolicHotKeys.parseEnabledSwitchHotkeys(from: nil)
        XCTAssertEqual(fallback, [
            RDPSwitchHotkey(keyCode: 49, modifiers: [.control]),
            RDPSwitchHotkey(keyCode: 49, modifiers: [.control, .option])
        ])

        // 60 enabled custom (Option+Space), 61 disabled.
        let customRaw: [String: Any] = [
            "60": [
                "enabled": true,
                "value": ["parameters": [32, 49, Int(NSEvent.ModifierFlags.option.rawValue)]]
            ],
            "61": [
                "enabled": false,
                "value": ["parameters": [32, 49, Int(NSEvent.ModifierFlags([.control, .option]).rawValue)]]
            ]
        ]
        let parsed = RDPSymbolicHotKeys.parseEnabledSwitchHotkeys(from: customRaw)
        XCTAssertEqual(parsed, [RDPSwitchHotkey(keyCode: 49, modifiers: [.option])])
        XCTAssertTrue(parsed[0].matches(keyCode: 49, modifierFlags: [.option, .capsLock]))
        XCTAssertFalse(parsed[0].matches(keyCode: 49, modifierFlags: [.control]))

        // Both disabled -> empty.
        let disabledRaw: [String: Any] = [
            "60": ["enabled": false],
            "61": ["enabled": false]
        ]
        XCTAssertEqual(RDPSymbolicHotKeys.parseEnabledSwitchHotkeys(from: disabledRaw), [])
    }

    // MARK: Read-only TIS latency sanity check (stop condition: < 1 ms per key)

    func testReadOnlyTISCurrentLanguageLatencyUnderOneMillisecond() {
        let reader = RDPMacInputSourceReader()
        _ = reader.currentLanguage() // warm up
        let iterations = 100
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations {
            _ = reader.currentLanguage()
        }
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000.0
        let avgMs = elapsedMs / Double(iterations)
        XCTAssertLessThan(avgMs, 1.0, "Average TIS read latency \(avgMs) ms exceeded 1 ms stop threshold")
    }
}

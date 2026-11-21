import AppKit
import Carbon
import Foundation

// MARK: - Data Models (No PII, No Character Contents)

enum ProbeViewKind: String {
    case viewA = "A"
    case viewB = "B"
}

enum ProbeEventKind: String {
    case keyDown
    case keyUp
    case flagsChanged
    case tisNotify
    case didBecomeActive
    case didResignActive
    case didBecomeKey
    case didResignKey
    case clientInsert
    case clientMarked
}

struct InputSourceSnapshot: Equatable {
    let sourceID: String
    let primaryLanguage: String

    var isKorean: Bool {
        Self.isKoreanLanguage(primaryLanguage)
    }

    static func isKoreanLanguage(_ lang: String) -> Bool {
        let lower = lang.lowercased()
        return lower == "ko" || lower.hasPrefix("ko-")
    }
}

struct SymbolicHotkeySpec: Equatable {
    let id: Int
    let enabled: Bool
    let charCode: Int
    let keyCode: Int
    let modifierMask: UInt

    func matchesKeyDown(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard enabled else { return false }
        guard Int(keyCode) == self.keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let actual = modifierFlags.intersection(relevant).rawValue
        let expected = NSEvent.ModifierFlags(rawValue: modifierMask).intersection(relevant).rawValue
        return actual == expected
    }
}

struct ProbeEventRecord: Equatable {
    let stepIndex: Int
    let elapsedMs: Int
    let view: ProbeViewKind?
    let kind: ProbeEventKind
    let keyCode: UInt16?
    let modifierFlagsRaw: UInt?
    let capsLockOn: Bool?
    let isARepeat: Bool?
    let sourceID: String
    let primaryLanguage: String
    let handleEventReturned: Bool?
    let postSourceID: String?
    let postPrimaryLanguage: String?
    let clientTextLength: Int?

    var modifierFlagsHex: String {
        guard let raw = modifierFlagsRaw else { return "-" }
        return String(format: "0x%llX", UInt64(raw))
    }
}

struct ProbeStepDefinition {
    let index: Int // 1...13
    let view: ProbeViewKind
    let methodGroup: String
    let instruction: String
    let isMultiAction: Bool
    let isAppSwitchStep: Bool
    let timeoutSeconds: Double
}

struct ProbeStepResult {
    let step: ProbeStepDefinition
    let skipped: Bool
    let startSource: InputSourceSnapshot
    let endSource: InputSourceSnapshot
    let events: [ProbeEventRecord]
}

struct ProbeEnvironmentContext {
    let osVersion: String
    let architecture: String
    let hotkeys: [SymbolicHotkeySpec]
    let hotkeysFromFallback: Bool
    let fnUsageType: String
    let globalTextInputProperties: String
    let enabledSources: [InputSourceSnapshot]
}

// MARK: - 13 Steps (V-H Spec)

enum ProbeSteps {
    static let all: [ProbeStepDefinition] = [
        ProbeStepDefinition(
            index: 1, view: .viewA, methodGroup: "평소 방법",
            instruction: "[뷰 A] 평소 쓰는 한/영 전환 방법으로 한 번 누르세요",
            isMultiAction: false, isAppSwitchStep: false, timeoutSeconds: 8.0
        ),
        ProbeStepDefinition(
            index: 2, view: .viewA, methodGroup: "Control+Space",
            instruction: "[뷰 A] Control+Space 를 한 번 누르세요",
            isMultiAction: false, isAppSwitchStep: false, timeoutSeconds: 8.0
        ),
        ProbeStepDefinition(
            index: 3, view: .viewA, methodGroup: "Caps Lock 짧게",
            instruction: "[뷰 A] Caps Lock 을 짧게 한 번 누르세요",
            isMultiAction: false, isAppSwitchStep: false, timeoutSeconds: 8.0
        ),
        ProbeStepDefinition(
            index: 4, view: .viewA, methodGroup: "지구본 또는 fn",
            instruction: "[뷰 A] 지구본(fn) 키를 한 번 누르세요",
            isMultiAction: false, isAppSwitchStep: false, timeoutSeconds: 8.0
        ),
        ProbeStepDefinition(
            index: 5, view: .viewA, methodGroup: "오른쪽 Option",
            instruction: "[뷰 A] 오른쪽 Option 키를 한 번 누르세요",
            isMultiAction: false, isAppSwitchStep: false, timeoutSeconds: 8.0
        ),
        ProbeStepDefinition(
            index: 6, view: .viewB, methodGroup: "평소 방법",
            instruction: "[뷰 B] 평소 쓰는 한/영 전환 방법으로 한 번 누르세요",
            isMultiAction: false, isAppSwitchStep: false, timeoutSeconds: 8.0
        ),
        ProbeStepDefinition(
            index: 7, view: .viewB, methodGroup: "Control+Space",
            instruction: "[뷰 B] Control+Space 를 한 번 누르세요",
            isMultiAction: false, isAppSwitchStep: false, timeoutSeconds: 8.0
        ),
        ProbeStepDefinition(
            index: 8, view: .viewB, methodGroup: "Caps Lock 짧게",
            instruction: "[뷰 B] Caps Lock 을 짧게 한 번 누르세요",
            isMultiAction: false, isAppSwitchStep: false, timeoutSeconds: 8.0
        ),
        ProbeStepDefinition(
            index: 9, view: .viewB, methodGroup: "지구본 또는 fn",
            instruction: "[뷰 B] 지구본(fn) 키를 한 번 누르세요",
            isMultiAction: false, isAppSwitchStep: false, timeoutSeconds: 8.0
        ),
        ProbeStepDefinition(
            index: 10, view: .viewB, methodGroup: "오른쪽 Option",
            instruction: "[뷰 B] 오른쪽 Option 키를 한 번 누르세요",
            isMultiAction: false, isAppSwitchStep: false, timeoutSeconds: 8.0
        ),
        ProbeStepDefinition(
            index: 11, view: .viewB, methodGroup: "Control+Space 2회",
            instruction: "[뷰 B] Control 을 누른 채 Space 를 두 번 누르고 Control 을 떼세요",
            isMultiAction: true, isAppSwitchStep: false, timeoutSeconds: 8.0
        ),
        ProbeStepDefinition(
            index: 12, view: .viewB, methodGroup: "평소 방법 3회",
            instruction: "[뷰 B] 평소 쓰는 한/영 전환 방법으로 빠르게 세 번 누르세요",
            isMultiAction: true, isAppSwitchStep: false, timeoutSeconds: 8.0
        ),
        ProbeStepDefinition(
            index: 13, view: .viewB, methodGroup: "앱 전환 복귀",
            instruction: "다른 앱 창을 한 번 클릭했다가 이 창을 다시 클릭하세요",
            isMultiAction: false, isAppSwitchStep: true, timeoutSeconds: 15.0
        ),
    ]
}

// MARK: - Read-Only System Readers (Zero Write, Zero TISSelectInputSource, Zero Permissions)

enum ReadOnlySystemInspector {
    static func currentInputSource() -> InputSourceSnapshot {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return InputSourceSnapshot(sourceID: "unknown", primaryLanguage: "unknown")
        }
        return snapshot(from: source)
    }

    static func enabledKeyboardInputSources() -> [InputSourceSnapshot] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsEnabled: true,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.map { snapshot(from: $0) }
    }

    private static func snapshot(from source: TISInputSource) -> InputSourceSnapshot {
        let sourceID: String
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            sourceID = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        } else {
            sourceID = "unknown"
        }

        let primaryLang: String
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String],
           let first = langs.first {
            primaryLang = first
        } else {
            primaryLang = "unknown"
        }

        return InputSourceSnapshot(sourceID: sourceID, primaryLanguage: primaryLang)
    }

    static func defaultFallbackHotkeys() -> [SymbolicHotkeySpec] {
        // 60 = Control+Space (32, 49, 262144), 61 = Control+Option+Space (32, 49, 786432)
        return [
            SymbolicHotkeySpec(id: 60, enabled: true, charCode: 32, keyCode: 49, modifierMask: 262144),
            SymbolicHotkeySpec(id: 61, enabled: true, charCode: 32, keyCode: 49, modifierMask: 786432),
        ]
    }

    static func readSymbolicHotkeys() -> (hotkeys: [SymbolicHotkeySpec], fromFallback: Bool) {
        guard let raw = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString),
              let dict = raw as? [String: Any] else {
            return (defaultFallbackHotkeys(), true)
        }
        var specs: [SymbolicHotkeySpec] = []
        for id in [60, 61] {
            guard let entry = dict[String(id)] as? [String: Any] else { continue }
            let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? NSNumber)?.boolValue ?? false)
            var charCode = 32
            var keyCode = 49
            var modMask: UInt = (id == 60 ? 262144 : 786432)
            if let value = entry["value"] as? [String: Any],
               let params = value["parameters"] as? [Any],
               params.count >= 3 {
                if let c = (params[0] as? NSNumber)?.intValue { charCode = c }
                if let k = (params[1] as? NSNumber)?.intValue { keyCode = k }
                if let m = (params[2] as? NSNumber)?.uintValue { modMask = m }
            }
            specs.append(SymbolicHotkeySpec(id: id, enabled: enabled, charCode: charCode, keyCode: keyCode, modifierMask: modMask))
        }
        if specs.isEmpty {
            return (defaultFallbackHotkeys(), true)
        }
        return (specs, false)
    }

    static func readHIToolboxPreferences() -> (fnUsageType: String, globalTextInputProperties: String) {
        let domain = "com.apple.HIToolbox" as CFString
        let fnValue: String
        if let rawFn = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) {
            fnValue = String(describing: rawFn)
        } else {
            fnValue = "(없음)"
        }

        let globalProps: String
        if let rawGlobal = CFPreferencesCopyAppValue("AppleGlobalTextInputProperties" as CFString, domain) {
            globalProps = sanitizePreferenceValue(rawGlobal)
        } else {
            globalProps = "(없음)"
        }

        return (fnValue, globalProps)
    }

    static func sanitizePreferenceValue(_ value: Any) -> String {
        if let dict = value as? [String: Any] {
            let pairs = dict.keys.sorted().map { key -> String in
                let val = dict[key].map { sanitizePreferenceValue($0) } ?? "nil"
                return "\(key)=\(val)"
            }
            return "{\(pairs.joined(separator: ", "))}"
        }
        if let arr = value as? [Any] {
            return "[\(arr.map { sanitizePreferenceValue($0) }.joined(separator: ", "))]"
        }
        let str = String(describing: value)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "/")
        return str
    }

    static func collectEnvironmentContext() -> ProbeEnvironmentContext {
        let (hotkeys, fallback) = readSymbolicHotkeys()
        let (fnUsage, globalProps) = readHIToolboxPreferences()
        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #else
        arch = "unknown"
        #endif
        return ProbeEnvironmentContext(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: arch,
            hotkeys: hotkeys,
            hotkeysFromFallback: fallback,
            fnUsageType: fnUsage,
            globalTextInputProperties: globalProps,
            enabledSources: enabledKeyboardInputSources()
        )
    }
}

// MARK: - Candidate Event Filter (View B)

struct ViewBCandidateFilter {
    let hotkeys: [SymbolicHotkeySpec]

    func shouldHandle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            return hotkeys.contains { $0.matchesKeyDown(keyCode: event.keyCode, modifierFlags: event.modifierFlags) }
        case .flagsChanged:
            // 57 = kVK_CapsLock, 63 = kVK_Function
            return event.keyCode == 57 || event.keyCode == 63
        default:
            return false
        }
    }

    func matchesEnabledHotkey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        return hotkeys.contains { $0.matchesKeyDown(keyCode: event.keyCode, modifierFlags: event.modifierFlags) }
    }
}

// MARK: - Judgment & Report Generator (Pure Functions for Unit Testing)

struct MethodViewSummary: Equatable {
    enum SwitchMode: Equatable {
        case skipped
        case none
        case syncInHandleEvent(delayMs: Int)
        case preCheckAlreadyChanged(delayMs: Int)
        case asyncNotification(delayMs: Int?)
    }

    let switchMode: SwitchMode
    let arrivalSummary: String
    let clientTextEvents: [String]

    var descriptionText: String {
        switch switchMode {
        case .skipped:
            return "건너뜀"
        case .none:
            return "안 됨 (\(arrivalSummary))"
        case .syncInHandleEvent(let ms):
            return "전환됨(동기 handleEvent, \(ms)ms, \(arrivalSummary))"
        case .preCheckAlreadyChanged(let ms):
            return "전환됨(pre-check 이전 완료, \(ms)ms, \(arrivalSummary))"
        case .asyncNotification(let ms):
            if let ms {
                return "전환됨(비동기 알림, 지연 \(ms)ms, \(arrivalSummary))"
            }
            return "전환됨(비동기 알림, \(arrivalSummary))"
        }
    }
}

struct MethodRowJudgment: Equatable {
    let methodName: String
    let viewA: MethodViewSummary
    let viewB: MethodViewSummary
    let decision: String
}

struct ProbeJudgmentSummary {
    let methodRows: [MethodRowJudgment]
    let step11Summary: String
    let step12Summary: String
    let step13ActivationDelayMs: Int?
    let recommendedTSettleMs: Int
    let usualKeyUpToNotifyDelayMs: Int?
    let recommendedTMergeMs: Int
    let capsLockFlagSummary: String
}

enum JudgmentAnalyzer {
    static func clamp(_ value: Int, min minVal: Int, max maxVal: Int) -> Int {
        return Swift.max(minVal, Swift.min(maxVal, value))
    }

    static func analyzeViewStep(_ result: ProbeStepResult) -> MethodViewSummary {
        if result.skipped {
            return MethodViewSummary(switchMode: .skipped, arrivalSummary: "건너뜀", clientTextEvents: [])
        }

        let keyEvents = result.events.filter {
            $0.kind == .keyDown || $0.kind == .keyUp || $0.kind == .flagsChanged
        }
        let clientEvents = result.events.compactMap { ev -> String? in
            if ev.kind == .clientInsert {
                return "insertText(len=\(ev.clientTextLength ?? -1))"
            }
            if ev.kind == .clientMarked {
                return "setMarkedText(len=\(ev.clientTextLength ?? -1))"
            }
            return nil
        }

        let arrivalSummary: String
        if keyEvents.isEmpty {
            let hasNotify = result.events.contains { $0.kind == .tisNotify }
            arrivalSummary = hasNotify ? "키 이벤트 없음(알림만)" : "이벤트 없음"
        } else {
            let parts = keyEvents.prefix(4).map { ev -> String in
                let kc = ev.keyCode.map { String($0) } ?? "-"
                return "\(ev.kind.rawValue)(kc=\(kc))"
            }
            arrivalSummary = parts.joined(separator: ", ")
        }

        // 1) Sync in handleEvent (View B)
        if result.events.contains(where: {
            $0.handleEventReturned != nil && $0.postSourceID != nil && $0.postSourceID != $0.sourceID
        }) {
            return MethodViewSummary(
                switchMode: .syncInHandleEvent(delayMs: 0),
                arrivalSummary: arrivalSummary,
                clientTextEvents: clientEvents
            )
        }

        // 2) Pre-check already changed at keyDown / flagsChanged arrival
        if let preEv = keyEvents.first(where: { $0.sourceID != result.startSource.sourceID }) {
            return MethodViewSummary(
                switchMode: .preCheckAlreadyChanged(delayMs: preEv.elapsedMs),
                arrivalSummary: arrivalSummary,
                clientTextEvents: clientEvents
            )
        }

        // 3) Async TIS notification changed source
        if let notifyEv = result.events.first(where: {
            $0.kind == .tisNotify && $0.sourceID != result.startSource.sourceID
        }) {
            let refEvent = keyEvents.first
            let delay = refEvent.map { max(0, notifyEv.elapsedMs - $0.elapsedMs) }
            return MethodViewSummary(
                switchMode: .asyncNotification(delayMs: delay),
                arrivalSummary: arrivalSummary,
                clientTextEvents: clientEvents
            )
        }

        // 4) End source differs from start source even without notify
        if result.endSource.sourceID != result.startSource.sourceID {
            return MethodViewSummary(
                switchMode: .asyncNotification(delayMs: nil),
                arrivalSummary: arrivalSummary,
                clientTextEvents: clientEvents
            )
        }

        return MethodViewSummary(
            switchMode: .none,
            arrivalSummary: arrivalSummary,
            clientTextEvents: clientEvents
        )
    }

    static func decideMethod(viewA: MethodViewSummary, viewB: MethodViewSummary) -> String {
        if viewA.switchMode == .skipped && viewB.switchMode == .skipped {
            return "해당 없음(건너뜀)"
        }

        var notes: [String] = []
        if !viewB.clientTextEvents.isEmpty {
            notes.append("주의: B 에서 글자/조합 생성(\(viewB.clientTextEvents.joined(separator: ", "))) -> 후보 제외 필요(D1)")
        }

        switch (viewA.switchMode, viewB.switchMode) {
        case (.asyncNotification, _):
            notes.insert("F1 로 지원(비동기 알림)", at: 0)
        case (.preCheckAlreadyChanged, _):
            notes.insert("F1 로 지원(후보 키 pre-check 억제)", at: 0)
        case (.none, .syncInHandleEvent), (.skipped, .syncInHandleEvent):
            notes.insert("F1b 필요(B 의 handleEvent 에서 전환)", at: 0)
        case (.none, .asyncNotification), (.none, .preCheckAlreadyChanged):
            notes.insert("F1b 검토 필요(B 에서만 전환)", at: 0)
        case (.none, .none), (.none, .skipped), (.skipped, .none):
            notes.insert("미지원(한계 기록, 오른쪽 Option 안내)", at: 0)
        case (.syncInHandleEvent, _):
            notes.insert("A 에서 동기 전환(예외 확인 필요)", at: 0)
        case (.skipped, .asyncNotification):
            notes.insert("B 비동기 전환(A 건너뜀)", at: 0)
        case (.skipped, .preCheckAlreadyChanged):
            notes.insert("B pre-check 전환(A 건너뜀)", at: 0)
        case (.skipped, .skipped):
            notes.insert("해당 없음(건너뜀)", at: 0)
        }

        return notes.joined(separator: "; ")
    }

    static func analyzeAll(results: [ProbeStepResult]) -> ProbeJudgmentSummary {
        let byIndex = Dictionary(uniqueKeysWithValues: results.map { ($0.step.index, $0) })

        let pairs: [(String, Int, Int)] = [
            ("평소 방법", 1, 6),
            ("Control+Space", 2, 7),
            ("Caps Lock 짧게", 3, 8),
            ("지구본 또는 fn", 4, 9),
            ("오른쪽 Option", 5, 10),
        ]

        let methodRows: [MethodRowJudgment] = pairs.map { name, idxA, idxB in
            let sumA = byIndex[idxA].map { analyzeViewStep($0) }
                ?? MethodViewSummary(switchMode: .skipped, arrivalSummary: "기록 없음", clientTextEvents: [])
            let sumB = byIndex[idxB].map { analyzeViewStep($0) }
                ?? MethodViewSummary(switchMode: .skipped, arrivalSummary: "기록 없음", clientTextEvents: [])
            return MethodRowJudgment(
                methodName: name,
                viewA: sumA,
                viewB: sumB,
                decision: decideMethod(viewA: sumA, viewB: sumB)
            )
        }

        // Step 11: Control held + Space twice
        let step11Summary: String
        if let r11 = byIndex[11] {
            if r11.skipped {
                step11Summary = "건너뜀"
            } else {
                let spaceEvents = r11.events.filter { $0.kind == .keyDown && $0.keyCode == 49 }
                let handleResults = spaceEvents.map { ev -> String in
                    let h = ev.handleEventReturned.map { $0 ? "YES" : "NO" } ?? "미호출"
                    let changed = (ev.postSourceID != nil && ev.postSourceID != ev.sourceID) ? "변화" : "유지"
                    return "Space(\(ev.elapsedMs)ms: handle=\(h), \(changed))"
                }
                let notifies = r11.events.filter { $0.kind == .tisNotify }
                let notifyStr = notifies.isEmpty ? "알림 0회" : "알림 \(notifies.count)회(\(notifies.map { "\($0.elapsedMs)ms" }.joined(separator: ",")))"
                step11Summary = (handleResults.isEmpty ? "Space 이벤트 없음" : handleResults.joined(separator: ", ")) + " / " + notifyStr
            }
        } else {
            step11Summary = "기록 없음"
        }

        // Step 12: Usual method 3 times quickly
        let step12Summary: String
        if let r12 = byIndex[12] {
            if r12.skipped {
                step12Summary = "건너뜀"
            } else {
                let notifies = r12.events.filter { $0.kind == .tisNotify }
                let uniqueTransitions = countSourceTransitions(start: r12.startSource.sourceID, events: r12.events)
                step12Summary = "알림 \(notifies.count)회, 소스 변화 \(uniqueTransitions)회"
            }
        } else {
            step12Summary = "기록 없음"
        }

        // Step 13: App switch and return -> T_settle
        var activationDelay: Int? = nil
        if let r13 = byIndex[13], !r13.skipped {
            let returnEvent = r13.events.last(where: { $0.kind == .didBecomeActive || $0.kind == .didBecomeKey })
            if let ret = returnEvent {
                if let notifyAfter = r13.events.first(where: { $0.kind == .tisNotify && $0.elapsedMs >= ret.elapsedMs }) {
                    activationDelay = notifyAfter.elapsedMs - ret.elapsedMs
                }
            }
        }
        let recommendedTSettle = activationDelay.map { clamp($0 * 2, min: 200, max: 800) } ?? 300

        // T_merge from Step 1 / Step 6 (keyUp or flagsChanged release -> tisNotify)
        var mergeDelays: [Int] = []
        for idx in [1, 6] {
            guard let r = byIndex[idx], !r.skipped else { continue }
            if let notifyEv = r.events.first(where: { $0.kind == .tisNotify && $0.sourceID != r.startSource.sourceID }) {
                let releaseEv = r.events.last(where: { ($0.kind == .keyUp || $0.kind == .flagsChanged) && $0.elapsedMs <= notifyEv.elapsedMs })
                    ?? r.events.first(where: { ($0.kind == .keyDown || $0.kind == .flagsChanged) && $0.elapsedMs <= notifyEv.elapsedMs })
                if let ref = releaseEv {
                    mergeDelays.append(max(0, notifyEv.elapsedMs - ref.elapsedMs))
                }
            }
        }
        let maxMergeDelay = mergeDelays.max()
        let recommendedTMerge = maxMergeDelay.map { clamp($0 * 2, min: 300, max: 1000) } ?? 500

        // Caps Lock .capsLock flag changes (Steps 3 and 8)
        let capsSummaries: [String] = [3, 8].compactMap { idx -> String? in
            guard let r = byIndex[idx] else { return nil }
            let label = idx == 3 ? "A" : "B"
            if r.skipped { return "\(label): 건너뜀" }
            let capsVals = r.events.compactMap { $0.capsLockOn }
            guard let first = capsVals.first else { return "\(label): 키 이벤트 없음" }
            let changed = capsVals.contains { $0 != first }
            let states = capsVals.map { $0 ? "ON" : "OFF" }.joined(separator: "->")
            return "\(label): \(changed ? "변화함" : "변화 없음") (\(states))"
        }
        let capsLockFlagSummary = capsSummaries.isEmpty ? "기록 없음" : capsSummaries.joined(separator: " / ")

        return ProbeJudgmentSummary(
            methodRows: methodRows,
            step11Summary: step11Summary,
            step12Summary: step12Summary,
            step13ActivationDelayMs: activationDelay,
            recommendedTSettleMs: recommendedTSettle,
            usualKeyUpToNotifyDelayMs: maxMergeDelay,
            recommendedTMergeMs: recommendedTMerge,
            capsLockFlagSummary: capsLockFlagSummary
        )
    }

    private static func countSourceTransitions(start: String, events: [ProbeEventRecord]) -> Int {
        var last = start
        var count = 0
        for ev in events {
            if ev.sourceID != last {
                count += 1
                last = ev.sourceID
            }
            if let post = ev.postSourceID, post != last {
                count += 1
                last = post
            }
        }
        return count
    }
}

enum ReportGenerator {
    static func generateMarkdown(
        timestampKST: String,
        context: ProbeEnvironmentContext,
        results: [ProbeStepResult]
    ) -> String {
        let summary = JudgmentAnalyzer.analyzeAll(results: results)
        var lines: [String] = []

        lines.append("# CNDF KeyProbe 측정 결과")
        lines.append("")
        lines.append("- 측정 시각: \(timestampKST)")
        lines.append("- 개인정보 보호: 사용자 이름, 홈 경로, 호스트명, 입력 글자 내용은 기록하지 않았습니다.")
        lines.append("")

        lines.append("## 1. V-H 판정 요약표")
        lines.append("")
        lines.append("| 방법 | 뷰 A (컨텍스트 없음) | 뷰 B (최소 컨텍스트) | 판정 |")
        lines.append("|---|---|---|---|")
        for row in summary.methodRows {
            lines.append("| \(row.methodName) | \(row.viewA.descriptionText) | \(row.viewB.descriptionText) | \(row.decision) |")
        }
        lines.append("")

        lines.append("### 추가 판정 항목")
        lines.append("")
        lines.append("| 항목 | 측정 결과 |")
        lines.append("|---|---|")
        lines.append("| 단계 11 (Control+Space 2회) | \(summary.step11Summary) |")
        lines.append("| 단계 12 (평소 방법 빠르게 3회) | \(summary.step12Summary) |")
        let settleText: String
        if let d = summary.step13ActivationDelayMs {
            settleText = "활성화 후 알림 지연 \(d)ms -> 권장 T_settle = \(summary.recommendedTSettleMs)ms"
        } else {
            settleText = "자동 전환 알림 없음 -> 기본값 T_settle = \(summary.recommendedTSettleMs)ms 유지"
        }
        lines.append("| 단계 13 (앱 복귀 -> T_settle) | \(settleText) |")
        let mergeText: String
        if let d = summary.usualKeyUpToNotifyDelayMs {
            mergeText = "키 뗌 후 알림 지연 \(d)ms -> 권장 T_merge = \(summary.recommendedTMergeMs)ms"
        } else {
            mergeText = "지연 측정값 없음 -> 기본값 T_merge = \(summary.recommendedTMergeMs)ms 유지"
        }
        lines.append("| 평소 방법 지연 (-> T_merge) | \(mergeText) |")
        lines.append("| Caps Lock `.capsLock` 변화 (D5) | \(summary.capsLockFlagSummary) |")
        lines.append("")

        lines.append("## 2. 환경 맥락 (읽기 전용)")
        lines.append("")
        lines.append("- macOS: \(context.osVersion) (\(context.architecture))")
        let hotkeySourceNote = context.hotkeysFromFallback ? "기본값 폴백" : "시스템 설정 읽기"
        let hotkeyDesc = context.hotkeys.map {
            "id=\($0.id) enabled=\($0.enabled) params=(\($0.charCode), \($0.keyCode), \($0.modifierMask))"
        }.joined(separator: "; ")
        lines.append("- 심볼릭 핫키 60/61 (\(hotkeySourceNote)): \(hotkeyDesc)")
        lines.append("- HIToolbox AppleFnUsageType: \(context.fnUsageType)")
        lines.append("- HIToolbox AppleGlobalTextInputProperties: \(context.globalTextInputProperties)")
        lines.append("- 활성 키보드 입력 소스:")
        for src in context.enabledSources {
            lines.append("  - `\(src.sourceID)` (언어: `\(src.primaryLanguage)`)")
        }
        lines.append("")

        lines.append("## 3. 원시 기록 (단계 1~13)")
        lines.append("")
        for res in results {
            let status = res.skipped ? "건너뜀" : "완료"
            lines.append("### 단계 \(res.step.index)/\(ProbeSteps.all.count) [\(res.step.methodGroup), 뷰 \(res.step.view.rawValue)] (\(status))")
            lines.append("- 시작 소스: `\(res.startSource.sourceID)` (`\(res.startSource.primaryLanguage)`) -> 종료 소스: `\(res.endSource.sourceID)` (`\(res.endSource.primaryLanguage)`)")
            if res.events.isEmpty {
                lines.append("- 기록된 이벤트 없음")
            } else {
                lines.append("")
                lines.append("| ms | 뷰 | 종류 | keyCode | flags(hex) | capsLock | repeat | 소스 ID | 언어 | handleEvent | 직후 소스 ID | client 길이 |")
                lines.append("|---:|:---:|---|---:|---:|:---:|:---:|---|---|:---:|---|---:|")
                for ev in res.events {
                    let v = ev.view?.rawValue ?? "-"
                    let kc = ev.keyCode.map { String($0) } ?? "-"
                    let caps = ev.capsLockOn.map { $0 ? "1" : "0" } ?? "-"
                    let rep = ev.isARepeat.map { $0 ? "1" : "0" } ?? "-"
                    let he = ev.handleEventReturned.map { $0 ? "YES" : "NO" } ?? "-"
                    let post = ev.postSourceID ?? "-"
                    let clen = ev.clientTextLength.map { String($0) } ?? "-"
                    lines.append("| \(ev.elapsedMs) | \(v) | \(ev.kind.rawValue) | \(kc) | \(ev.modifierFlagsHex) | \(caps) | \(rep) | `\(ev.sourceID)` | `\(ev.primaryLanguage)` | \(he) | `\(post)` | \(clen) |")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Step State Machine (Testable Without AppKit RunLoop)

final class ProbeStepEngine {
    private let steps: [ProbeStepDefinition]
    private(set) var currentIndex: Int = 0
    private(set) var completedResults: [ProbeStepResult] = []
    private(set) var currentEvents: [ProbeEventRecord] = []
    private(set) var currentStartSource: InputSourceSnapshot = InputSourceSnapshot(sourceID: "unknown", primaryLanguage: "unknown")
    private(set) var currentStepStartTime: TimeInterval = 0
    private(set) var sawResignInAppSwitchStep: Bool = false
    private(set) var isFinished: Bool = false

    init(steps: [ProbeStepDefinition] = ProbeSteps.all) {
        self.steps = steps
    }

    var currentStep: ProbeStepDefinition? {
        guard currentIndex < steps.count else { return nil }
        return steps[currentIndex]
    }

    func startCurrentStep(at now: TimeInterval, source: InputSourceSnapshot) {
        guard currentIndex < steps.count else {
            isFinished = true
            return
        }
        currentEvents = []
        currentStartSource = source
        currentStepStartTime = now
        sawResignInAppSwitchStep = false
    }

    enum RecordOutcome: Equatable {
        case ignored
        case recorded(scheduleAdvanceAfterSeconds: Double?)
    }

    func recordEvent(_ event: ProbeEventRecord) -> RecordOutcome {
        guard let step = currentStep, !isFinished else { return .ignored }
        currentEvents.append(event)

        if step.isAppSwitchStep {
            if event.kind == .didResignActive || event.kind == .didResignKey {
                sawResignInAppSwitchStep = true
                return .recorded(scheduleAdvanceAfterSeconds: nil)
            }
            if sawResignInAppSwitchStep && (event.kind == .didBecomeActive || event.kind == .didBecomeKey) {
                return .recorded(scheduleAdvanceAfterSeconds: 1.5)
            }
            return .recorded(scheduleAdvanceAfterSeconds: nil)
        }

        let isRelevant = event.kind == .keyDown || event.kind == .flagsChanged || event.kind == .tisNotify
        if isRelevant {
            return .recorded(scheduleAdvanceAfterSeconds: 1.5)
        }
        return .recorded(scheduleAdvanceAfterSeconds: nil)
    }

    func finishCurrentStep(skipped: Bool, endSource: InputSourceSnapshot) -> Bool {
        guard let step = currentStep, !isFinished else { return true }
        let result = ProbeStepResult(
            step: step,
            skipped: skipped,
            startSource: currentStartSource,
            endSource: endSource,
            events: currentEvents
        )
        completedResults.append(result)
        currentIndex += 1
        if currentIndex >= steps.count {
            isFinished = true
        }
        return isFinished
    }
}

// MARK: - View A (Plain NSView, inputContext == nil)

final class PlainKeyProbeView: NSView {
    var onKeyEvent: ((NSEvent, ProbeViewKind, ProbeEventKind) -> Void)?
    var onSkipRequested: (() -> Void)?
    var isActiveTarget: Bool = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var inputContext: NSTextInputContext? { nil }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isSkipEscape(event) {
            onSkipRequested?()
            return
        }
        onKeyEvent?(event, .viewA, .keyDown)
    }

    override func keyUp(with event: NSEvent) {
        if isSkipEscape(event) { return }
        onKeyEvent?(event, .viewA, .keyUp)
    }

    override func flagsChanged(with event: NSEvent) {
        onKeyEvent?(event, .viewA, .flagsChanged)
    }

    override func draw(_ dirtyRect: NSRect) {
        let isFocused = (window?.firstResponder === self) || isActiveTarget
        let bgColor: NSColor = isFocused ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.controlBackgroundColor
        let borderColor: NSColor = isFocused ? NSColor.controlAccentColor : NSColor.separatorColor
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        bgColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = isFocused ? 2.5 : 1.0
        path.stroke()

        let title = isFocused ? "뷰 A (입력 컨텍스트 없음) [활성]" : "뷰 A (입력 컨텍스트 없음)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: isFocused ? .semibold : .regular),
            .foregroundColor: isFocused ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (title as NSString).draw(at: point, withAttributes: attrs)
    }
}

// MARK: - View B (NSView with Minimal DropAllClient inputContext)

final class DropAllClient: NSObject, NSTextInputClient {
    weak var hostView: NSView?
    var onInsertText: ((Int) -> Void)?
    var onMarkedText: ((Int) -> Void)?

    private static func textLength(of string: Any) -> Int {
        if let str = string as? String {
            return str.count
        }
        if let attr = string as? NSAttributedString {
            return attr.length
        }
        return -1
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // Discard character contents completely; record length only.
        let len = Self.textLength(of: string)
        onInsertText?(len)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Discard character contents completely; record length only.
        let len = Self.textLength(of: string)
        onMarkedText?(len)
    }

    func unmarkText() {}

    func doCommand(by selector: Selector) {}

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        false
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let view = hostView, let window = view.window else { return .zero }
        let inWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}

final class ContextKeyProbeView: NSView {
    let dropAllClient = DropAllClient()
    private lazy var probeInputContext: NSTextInputContext = {
        NSTextInputContext(client: dropAllClient)
    }()

    var candidateFilter: ViewBCandidateFilter
    var sourceReader: () -> InputSourceSnapshot = { ReadOnlySystemInspector.currentInputSource() }
    var onKeyEvent: ((NSEvent, ProbeViewKind, ProbeEventKind, InputSourceSnapshot, Bool?, InputSourceSnapshot?) -> Void)?
    var onClientTextEvent: ((ProbeEventKind, Int) -> Void)?
    var onSkipRequested: (() -> Void)?
    var isActiveTarget: Bool = false {
        didSet { needsDisplay = true }
    }

    init(frame frameRect: NSRect, candidateFilter: ViewBCandidateFilter) {
        self.candidateFilter = candidateFilter
        super.init(frame: frameRect)
        dropAllClient.hostView = self
        dropAllClient.onInsertText = { [weak self] len in
            self?.onClientTextEvent?(.clientInsert, len)
        }
        dropAllClient.onMarkedText = { [weak self] len in
            self?.onClientTextEvent?(.clientMarked, len)
            self?.probeInputContext.discardMarkedText()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var inputContext: NSTextInputContext? { probeInputContext }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isSkipEscape(event) {
            onSkipRequested?()
            return
        }
        handleViewBEvent(event, kind: .keyDown)
    }

    override func keyUp(with event: NSEvent) {
        if isSkipEscape(event) { return }
        // keyUp is never passed to handleEvent
        let preSource = sourceReader()
        onKeyEvent?(event, .viewB, .keyUp, preSource, nil, nil)
    }

    override func flagsChanged(with event: NSEvent) {
        handleViewBEvent(event, kind: .flagsChanged)
    }

    private func handleViewBEvent(_ event: NSEvent, kind: ProbeEventKind) {
        let preSource = sourceReader()
        if candidateFilter.shouldHandle(event) {
            let handled = probeInputContext.handleEvent(event)
            let postSource = sourceReader()
            onKeyEvent?(event, .viewB, kind, preSource, handled, postSource)
        } else {
            onKeyEvent?(event, .viewB, kind, preSource, nil, nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let isFocused = (window?.firstResponder === self) || isActiveTarget
        let bgColor: NSColor = isFocused ? NSColor.systemGreen.withAlphaComponent(0.14) : NSColor.controlBackgroundColor
        let borderColor: NSColor = isFocused ? NSColor.systemGreen : NSColor.separatorColor
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        bgColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = isFocused ? 2.5 : 1.0
        path.stroke()

        let title = isFocused ? "뷰 B (최소 입력 컨텍스트) [활성]" : "뷰 B (최소 입력 컨텍스트)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: isFocused ? .semibold : .regular),
            .foregroundColor: isFocused ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (title as NSString).draw(at: point, withAttributes: attrs)
    }
}

private func isSkipEscape(_ event: NSEvent) -> Bool {
    guard event.keyCode == 53 else { return false }
    let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
    return mods.isEmpty
}

// MARK: - Main Window Controller

final class KeyProbeAppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let smokeTestMode: Bool
    private let envContext: ProbeEnvironmentContext
    private let engine = ProbeStepEngine()

    private var window: NSWindow!
    private var progressLabel: NSTextField!
    private var instructionLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var viewA: PlainKeyProbeView!
    private var viewB: ContextKeyProbeView!
    private var skipButton: NSButton!
    private var copyButton: NSButton!
    private var quitButton: NSButton!

    private var stepTimeoutTimer: Timer?
    private var postEventAdvanceTimer: Timer?
    private var finalMarkdown: String?
    private var savedFileName: String?
    private var tisObserver: NSObjectProtocol?

    init(smokeTestMode: Bool) {
        self.smokeTestMode = smokeTestMode
        self.envContext = ReadOnlySystemInspector.collectEnvironmentContext()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        subscribeNotifications()
        startStep()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if smokeTestMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stepTimeoutTimer?.invalidate()
        postEventAdvanceTimer?.invalidate()
        if let obs = tisObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 680, height: 340)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CNDF 키 프로브"
        window.center()
        window.delegate = self

        let content = NSView(frame: rect)
        window.contentView = content

        progressLabel = NSTextField(labelWithString: "1/13")
        progressLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.frame = NSRect(x: 24, y: 294, width: 120, height: 22)
        content.addSubview(progressLabel)

        let privacyNote = NSTextField(labelWithString: "글자 내용 및 개인정보는 기록하지 않습니다. 쓰지 않는 방법은 Esc 로 건너뛰세요.")
        privacyNote.font = NSFont.systemFont(ofSize: 12)
        privacyNote.textColor = .secondaryLabelColor
        privacyNote.alignment = .right
        privacyNote.frame = NSRect(x: 150, y: 296, width: 506, height: 18)
        content.addSubview(privacyNote)

        instructionLabel = NSTextField(wrappingLabelWithString: "")
        instructionLabel.font = NSFont.systemFont(ofSize: 21, weight: .semibold)
        instructionLabel.textColor = .labelColor
        instructionLabel.frame = NSRect(x: 24, y: 234, width: 632, height: 52)
        content.addSubview(instructionLabel)

        let filter = ViewBCandidateFilter(hotkeys: envContext.hotkeys)
        viewA = PlainKeyProbeView(frame: NSRect(x: 24, y: 112, width: 306, height: 106))
        viewB = ContextKeyProbeView(frame: NSRect(x: 350, y: 112, width: 306, height: 106), candidateFilter: filter)

        viewA.onKeyEvent = { [weak self] event, viewKind, eventKind in
            let preSource = ReadOnlySystemInspector.currentInputSource()
            self?.handleRecordedKeyEvent(event: event, view: viewKind, kind: eventKind, preSource: preSource, handleResult: nil, postSource: nil)
        }
        viewA.onSkipRequested = { [weak self] in
            self?.skipCurrentStep()
        }

        viewB.onKeyEvent = { [weak self] event, viewKind, eventKind, preSource, handleResult, postSource in
            self?.handleRecordedKeyEvent(event: event, view: viewKind, kind: eventKind, preSource: preSource, handleResult: handleResult, postSource: postSource)
        }
        viewB.onClientTextEvent = { [weak self] kind, length in
            self?.handleClientTextEvent(kind: kind, length: length)
        }
        viewB.onSkipRequested = { [weak self] in
            self?.skipCurrentStep()
        }

        content.addSubview(viewA)
        content.addSubview(viewB)

        statusLabel = NSTextField(wrappingLabelWithString: "준비됨")
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 24, y: 62, width: 632, height: 38)
        content.addSubview(statusLabel)

        skipButton = NSButton(title: "건너뛰기 (Esc)", target: self, action: #selector(skipButtonClicked))
        skipButton.frame = NSRect(x: 24, y: 18, width: 130, height: 32)
        content.addSubview(skipButton)

        copyButton = NSButton(title: "결과 복사", target: self, action: #selector(copyButtonClicked))
        copyButton.bezelStyle = .rounded
        copyButton.isEnabled = false
        copyButton.frame = NSRect(x: 430, y: 18, width: 120, height: 32)
        content.addSubview(copyButton)

        quitButton = NSButton(title: "종료", target: self, action: #selector(quitButtonClicked))
        quitButton.frame = NSRect(x: 562, y: 18, width: 94, height: 32)
        content.addSubview(quitButton)
    }

    private func subscribeNotifications() {
        tisObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemEvent(kind: .tisNotify)
        }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidResignActive), name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        handleSystemEvent(kind: .didBecomeActive)
    }

    @objc private func appDidResignActive() {
        handleSystemEvent(kind: .didResignActive)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        handleSystemEvent(kind: .didBecomeKey)
    }

    func windowDidResignKey(_ notification: Notification) {
        handleSystemEvent(kind: .didResignKey)
    }

    private func elapsedMs() -> Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - engine.currentStepStartTime) * 1000.0))
    }

    private func startStep() {
        stepTimeoutTimer?.invalidate()
        postEventAdvanceTimer?.invalidate()

        guard let step = engine.currentStep else {
            finishAllSteps()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let src = ReadOnlySystemInspector.currentInputSource()
        engine.startCurrentStep(at: now, source: src)

        progressLabel.stringValue = "\(step.index)/\(ProbeSteps.all.count)"
        instructionLabel.stringValue = step.instruction
        statusLabel.stringValue = "현재 입력 소스: \(src.sourceID) (\(src.primaryLanguage))"

        viewA.isActiveTarget = (step.view == .viewA)
        viewB.isActiveTarget = (step.view == .viewB)
        window.makeFirstResponder(step.view == .viewA ? viewA : viewB)

        stepTimeoutTimer = Timer.scheduledTimer(withTimeInterval: step.timeoutSeconds, repeats: false) { [weak self] _ in
            self?.advanceStep(skipped: false)
        }
    }

    private func handleRecordedKeyEvent(
        event: NSEvent,
        view: ProbeViewKind,
        kind: ProbeEventKind,
        preSource: InputSourceSnapshot,
        handleResult: Bool?,
        postSource: InputSourceSnapshot?
    ) {
        guard let step = engine.currentStep, !engine.isFinished else { return }
        let isRepeat: Bool? = (kind == .keyDown) ? event.isARepeat : nil
        let record = ProbeEventRecord(
            stepIndex: step.index,
            elapsedMs: elapsedMs(),
            view: view,
            kind: kind,
            keyCode: event.keyCode,
            modifierFlagsRaw: event.modifierFlags.rawValue,
            capsLockOn: event.modifierFlags.contains(.capsLock),
            isARepeat: isRepeat,
            sourceID: preSource.sourceID,
            primaryLanguage: preSource.primaryLanguage,
            handleEventReturned: handleResult,
            postSourceID: postSource?.sourceID,
            postPrimaryLanguage: postSource?.primaryLanguage,
            clientTextLength: nil
        )
        processRecord(record)
    }

    private func handleClientTextEvent(kind: ProbeEventKind, length: Int) {
        guard let step = engine.currentStep, !engine.isFinished else { return }
        let src = ReadOnlySystemInspector.currentInputSource()
        let record = ProbeEventRecord(
            stepIndex: step.index,
            elapsedMs: elapsedMs(),
            view: .viewB,
            kind: kind,
            keyCode: nil,
            modifierFlagsRaw: nil,
            capsLockOn: nil,
            isARepeat: nil,
            sourceID: src.sourceID,
            primaryLanguage: src.primaryLanguage,
            handleEventReturned: nil,
            postSourceID: nil,
            postPrimaryLanguage: nil,
            clientTextLength: length
        )
        processRecord(record)
    }

    private func handleSystemEvent(kind: ProbeEventKind) {
        guard let step = engine.currentStep, !engine.isFinished else { return }
        let src = ReadOnlySystemInspector.currentInputSource()
        let record = ProbeEventRecord(
            stepIndex: step.index,
            elapsedMs: elapsedMs(),
            view: nil,
            kind: kind,
            keyCode: nil,
            modifierFlagsRaw: nil,
            capsLockOn: nil,
            isARepeat: nil,
            sourceID: src.sourceID,
            primaryLanguage: src.primaryLanguage,
            handleEventReturned: nil,
            postSourceID: nil,
            postPrimaryLanguage: nil,
            clientTextLength: nil
        )
        processRecord(record)
    }

    private func processRecord(_ record: ProbeEventRecord) {
        guard let step = engine.currentStep else { return }
        let outcome = engine.recordEvent(record)
        statusLabel.stringValue = "감지됨: \(record.kind.rawValue) (소스: \(record.sourceID))"

        if case .recorded(let delayOpt) = outcome, let delay = delayOpt {
            if step.isMultiAction {
                // Reset 1.5s debounce timer for multi-action steps (11, 12), bounded by step timeout.
                postEventAdvanceTimer?.invalidate()
                postEventAdvanceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.advanceStep(skipped: false)
                }
            } else if postEventAdvanceTimer == nil {
                postEventAdvanceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.advanceStep(skipped: false)
                }
            }
        }
    }

    private func skipCurrentStep() {
        advanceStep(skipped: true)
    }

    private func advanceStep(skipped: Bool) {
        stepTimeoutTimer?.invalidate()
        stepTimeoutTimer = nil
        postEventAdvanceTimer?.invalidate()
        postEventAdvanceTimer = nil

        let endSource = ReadOnlySystemInspector.currentInputSource()
        let finished = engine.finishCurrentStep(skipped: skipped, endSource: endSource)
        if finished {
            finishAllSteps()
        } else {
            startStep()
        }
    }

    private func finishAllSteps() {
        stepTimeoutTimer?.invalidate()
        postEventAdvanceTimer?.invalidate()

        let now = Date()
        let kstFormatter = DateFormatter()
        kstFormatter.locale = Locale(identifier: "en_US_POSIX")
        kstFormatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        kstFormatter.dateFormat = "yyyy-MM-dd HH:mm KST"
        let timestampKST = kstFormatter.string(from: now)

        let markdown = ReportGenerator.generateMarkdown(
            timestampKST: timestampKST,
            context: envContext,
            results: engine.completedResults
        )
        finalMarkdown = markdown

        let saveResult = saveReportToDesktop(markdown: markdown, date: now)
        savedFileName = saveResult.fileName

        progressLabel.stringValue = "완료"
        instructionLabel.stringValue = "측정이 끝났습니다. 아래 '결과 복사' 버튼을 눌러 결과를 보내 주세요."
        if let fileName = saveResult.fileName {
            statusLabel.stringValue = "바탕화면에 새 파일로 저장되었습니다: \(fileName) (클립보드는 버튼 클릭 시에만 복사됩니다)"
        } else {
            statusLabel.stringValue = "바탕화면 저장에 실패했습니다(\(saveResult.errorMessage ?? "오류")). '결과 복사' 버튼으로 복사해 주세요."
        }

        viewA.isActiveTarget = false
        viewB.isActiveTarget = false
        skipButton.isEnabled = false
        copyButton.isEnabled = true
    }

    private func saveReportToDesktop(markdown: String, date: Date) -> (fileName: String?, errorMessage: String?) {
        let desktopURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let nameFormatter = DateFormatter()
        nameFormatter.locale = Locale(identifier: "en_US_POSIX")
        nameFormatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        nameFormatter.dateFormat = "yyyyMMdd-HHmm"
        let baseStamp = nameFormatter.string(from: date)

        var candidateName = "cndf-keyprobe-\(baseStamp).md"
        var candidateURL = desktopURL.appendingPathComponent(candidateName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidateURL.path) {
            candidateName = "cndf-keyprobe-\(baseStamp)-\(suffix).md"
            candidateURL = desktopURL.appendingPathComponent(candidateName)
            suffix += 1
        }

        do {
            try markdown.write(to: candidateURL, atomically: true, encoding: .utf8)
            return (candidateName, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    @objc private func skipButtonClicked() {
        skipCurrentStep()
    }

    @objc private func copyButtonClicked() {
        guard let markdown = finalMarkdown else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdown, forType: .string)
        if let fileName = savedFileName {
            statusLabel.stringValue = "클립보드에 복사되었습니다. 저장 파일: \(fileName)"
        } else {
            statusLabel.stringValue = "클립보드에 복사되었습니다."
        }
    }

    @objc private func quitButtonClicked() {
        NSApp.terminate(nil)
    }
}

// MARK: - Self-Tests (--self-test)

enum ProbeSelfTests {
    static func runAll() -> Bool {
        var passed = 0
        var failed = 0

        func assertEqual<T: Equatable>(_ a: T, _ b: T, _ name: String) {
            if a == b {
                passed += 1
            } else {
                failed += 1
                fputs("FAIL [\(name)]: expected \(b), got \(a)\n", stderr)
            }
        }

        func assertTrue(_ cond: Bool, _ name: String) {
            if cond {
                passed += 1
            } else {
                failed += 1
                fputs("FAIL [\(name)]\n", stderr)
            }
        }

        // 1. Language classification
        assertTrue(InputSourceSnapshot.isKoreanLanguage("ko"), "lang-ko")
        assertTrue(InputSourceSnapshot.isKoreanLanguage("ko-KR"), "lang-ko-KR")
        assertTrue(!InputSourceSnapshot.isKoreanLanguage("en"), "lang-en")
        assertTrue(!InputSourceSnapshot.isKoreanLanguage("ja"), "lang-ja")

        // 2. Symbolic hotkey matching
        let hk60 = SymbolicHotkeySpec(id: 60, enabled: true, charCode: 32, keyCode: 49, modifierMask: 262144)
        let hkDisabled = SymbolicHotkeySpec(id: 61, enabled: false, charCode: 32, keyCode: 49, modifierMask: 786432)
        assertTrue(hk60.matchesKeyDown(keyCode: 49, modifierFlags: [.control]), "hk60-ctrl-space")
        assertTrue(!hk60.matchesKeyDown(keyCode: 49, modifierFlags: [.control, .option]), "hk60-not-ctrl-opt-space")
        assertTrue(!hkDisabled.matchesKeyDown(keyCode: 49, modifierFlags: [.control, .option]), "hk61-disabled")

        // 3. Step engine progression & synthetic NSEvent keyDown on View A and View B
        let ko = InputSourceSnapshot(sourceID: "com.apple.inputmethod.Korean.2SetKorean", primaryLanguage: "ko")
        let en = InputSourceSnapshot(sourceID: "com.apple.keylayout.ABC", primaryLanguage: "en")
        let engine = ProbeStepEngine()
        engine.startCurrentStep(at: 100.0, source: en)
        assertEqual(engine.currentStep?.index, 1, "engine-step-1")

        let plainView = PlainKeyProbeView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var viewARecordedKeyCodes: [UInt16] = []
        var viewASkipped = false
        plainView.onKeyEvent = { ev, _, _ in viewARecordedKeyCodes.append(ev.keyCode) }
        plainView.onSkipRequested = { viewASkipped = true }

        if let syntheticSpace = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ) {
            plainView.keyDown(with: syntheticSpace)
        }
        assertEqual(viewARecordedKeyCodes, [49], "viewA-synthetic-keydown")
        assertTrue(!viewASkipped, "viewA-not-skipped-on-space")

        if let syntheticEsc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ) {
            plainView.keyDown(with: syntheticEsc)
        }
        assertTrue(viewASkipped, "viewA-esc-skip")
        assertTrue(plainView.inputContext == nil, "viewA-inputContext-nil")

        // 4. View B DropAllClient discards characters, records only length
        let viewB = ContextKeyProbeView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), candidateFilter: ViewBCandidateFilter(hotkeys: [hk60]))
        var clientEvents: [(ProbeEventKind, Int)] = []
        viewB.onClientTextEvent = { kind, len in clientEvents.append((kind, len)) }
        viewB.dropAllClient.insertText("한글테스트", replacementRange: NSRange(location: NSNotFound, length: 0))
        viewB.dropAllClient.setMarkedText("ㅎ", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        assertEqual(clientEvents.count, 2, "viewB-client-event-count")
        assertEqual(clientEvents[0].0, .clientInsert, "viewB-client-insert-kind")
        assertEqual(clientEvents[0].1, 5, "viewB-client-insert-len")
        assertEqual(clientEvents[1].0, .clientMarked, "viewB-client-marked-kind")
        assertEqual(clientEvents[1].1, 1, "viewB-client-marked-len")
        assertTrue(viewB.inputContext != nil, "viewB-inputContext-present")

        // 5. Judgment analyzer: A none + B sync => F1b needed; T_settle & T_merge clamping
        let steps = ProbeSteps.all
        var mockResults: [ProbeStepResult] = []
        for s in steps {
            switch s.index {
            case 1: // A usual: async notify 180ms after keyUp
                mockResults.append(ProbeStepResult(
                    step: s, skipped: false, startSource: en, endSource: ko,
                    events: [
                        ProbeEventRecord(stepIndex: 1, elapsedMs: 100, view: .viewA, kind: .flagsChanged, keyCode: 54, modifierFlagsRaw: 0x100010, capsLockOn: false, isARepeat: nil, sourceID: en.sourceID, primaryLanguage: en.primaryLanguage, handleEventReturned: nil, postSourceID: nil, postPrimaryLanguage: nil, clientTextLength: nil),
                        ProbeEventRecord(stepIndex: 1, elapsedMs: 280, view: nil, kind: .tisNotify, keyCode: nil, modifierFlagsRaw: nil, capsLockOn: nil, isARepeat: nil, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage, handleEventReturned: nil, postSourceID: nil, postPrimaryLanguage: nil, clientTextLength: nil),
                    ]
                ))
            case 2: // A Ctrl+Space: no switch
                mockResults.append(ProbeStepResult(
                    step: s, skipped: false, startSource: en, endSource: en,
                    events: [
                        ProbeEventRecord(stepIndex: 2, elapsedMs: 120, view: .viewA, kind: .keyDown, keyCode: 49, modifierFlagsRaw: 0x40001, capsLockOn: false, isARepeat: false, sourceID: en.sourceID, primaryLanguage: en.primaryLanguage, handleEventReturned: nil, postSourceID: nil, postPrimaryLanguage: nil, clientTextLength: nil),
                    ]
                ))
            case 7: // B Ctrl+Space: sync in handleEvent
                mockResults.append(ProbeStepResult(
                    step: s, skipped: false, startSource: en, endSource: ko,
                    events: [
                        ProbeEventRecord(stepIndex: 7, elapsedMs: 120, view: .viewB, kind: .keyDown, keyCode: 49, modifierFlagsRaw: 0x40001, capsLockOn: false, isARepeat: false, sourceID: en.sourceID, primaryLanguage: en.primaryLanguage, handleEventReturned: true, postSourceID: ko.sourceID, postPrimaryLanguage: ko.primaryLanguage, clientTextLength: nil),
                    ]
                ))
            case 13: // App switch: resign -> becomeActive at 500 -> tisNotify at 750 (d=250 -> T_settle=500)
                mockResults.append(ProbeStepResult(
                    step: s, skipped: false, startSource: en, endSource: ko,
                    events: [
                        ProbeEventRecord(stepIndex: 13, elapsedMs: 100, view: nil, kind: .didResignActive, keyCode: nil, modifierFlagsRaw: nil, capsLockOn: nil, isARepeat: nil, sourceID: en.sourceID, primaryLanguage: en.primaryLanguage, handleEventReturned: nil, postSourceID: nil, postPrimaryLanguage: nil, clientTextLength: nil),
                        ProbeEventRecord(stepIndex: 13, elapsedMs: 500, view: nil, kind: .didBecomeActive, keyCode: nil, modifierFlagsRaw: nil, capsLockOn: nil, isARepeat: nil, sourceID: en.sourceID, primaryLanguage: en.primaryLanguage, handleEventReturned: nil, postSourceID: nil, postPrimaryLanguage: nil, clientTextLength: nil),
                        ProbeEventRecord(stepIndex: 13, elapsedMs: 750, view: nil, kind: .tisNotify, keyCode: nil, modifierFlagsRaw: nil, capsLockOn: nil, isARepeat: nil, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage, handleEventReturned: nil, postSourceID: nil, postPrimaryLanguage: nil, clientTextLength: nil),
                    ]
                ))
            default:
                mockResults.append(ProbeStepResult(step: s, skipped: true, startSource: en, endSource: en, events: []))
            }
        }

        let summary = JudgmentAnalyzer.analyzeAll(results: mockResults)
        assertEqual(summary.methodRows[0].decision, "F1 로 지원(비동기 알림)", "judgment-usual-async")
        assertEqual(summary.methodRows[1].decision, "F1b 필요(B 의 handleEvent 에서 전환)", "judgment-ctrl-space-f1b")
        assertEqual(summary.step13ActivationDelayMs, 250, "judgment-step13-delay")
        assertEqual(summary.recommendedTSettleMs, 500, "judgment-tsettle")
        assertEqual(summary.usualKeyUpToNotifyDelayMs, 180, "judgment-merge-delay")
        assertEqual(summary.recommendedTMergeMs, 360, "judgment-tmerge")

        // 6. Report contains no PII, no em-dash, no typed text
        let mockCtx = ProbeEnvironmentContext(
            osVersion: "Version 15.0",
            architecture: "arm64",
            hotkeys: [hk60],
            hotkeysFromFallback: false,
            fnUsageType: "2",
            globalTextInputProperties: "(없음)",
            enabledSources: [en, ko]
        )
        let md = ReportGenerator.generateMarkdown(timestampKST: "2026-11-21 20:00 KST", context: mockCtx, results: mockResults)
        assertTrue(!md.contains("\u{2014}"), "report-no-emdash")
        assertTrue(!md.contains("\u{2013}"), "report-no-endash")
        assertTrue(!md.contains(NSUserName()), "report-no-username")
        assertTrue(!md.contains(NSHomeDirectory()), "report-no-homedir")
        assertTrue(!md.contains(ProcessInfo.processInfo.hostName), "report-no-hostname")
        assertTrue(!md.contains("한글테스트"), "report-no-typed-text")

        print("KeyProbe self-test: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}

// MARK: - Entry Point

let args = CommandLine.arguments
if args.contains("--self-test") {
    let ok = ProbeSelfTests.runAll()
    exit(ok ? 0 : 1)
}

let isSmokeTest = args.contains("--smoke-test")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = KeyProbeAppController(smokeTestMode: isSmokeTest)
app.delegate = controller
app.run()

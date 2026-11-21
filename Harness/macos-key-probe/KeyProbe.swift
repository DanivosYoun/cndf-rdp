import AppKit
import Carbon
import Foundation

// MARK: - Probe Mode & Data Models (No PII, No Character Contents)

enum ProbeMode: String {
    case vu2 = "vu2"
    case vh = "vh"
}

enum ProbeViewKind: String {
    case viewA = "A"
    case viewB = "B"
    case viewC = "C"
}

enum ProbeEventKind: String {
    case keyDown
    case keyUp
    case flagsChanged
    case mouseDown
    case handleEventEnd
    case forceDiscardBegin
    case forceDiscardEnd
    case tisNotify
    case didBecomeActive
    case didResignActive
    case didBecomeKey
    case didResignKey
    case resignFirstResponder
    case clientInsert
    case clientMarked
    case clientUnmark
    case clientDoCommand
    case clientHasMarked
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

// MARK: - Privacy-Safe Text Structure Summary (Zero Literal Characters)

struct TextStructureSummary: Equatable {
    let utf16Count: Int
    let scalarCount: Int
    let nfcScalarCount: Int
    let jamoCount: Int
    let hangulSyllableCount: Int
    let hangulJamoCount: Int
    let hanjaCount: Int
    let spaceCount: Int
    let controlCount: Int
    let nonBMPCount: Int
    let asciiOtherCount: Int
    let otherBMPCount: Int

    static func extractString(from value: Any) -> String {
        if let str = value as? String {
            return str
        }
        if let attr = value as? NSAttributedString {
            return attr.string
        }
        return ""
    }

    static func analyze(_ value: Any) -> TextStructureSummary {
        let str = extractString(from: value)
        return analyzeString(str)
    }

    static func analyzeString(_ str: String) -> TextStructureSummary {
        let utf16Count = str.utf16.count
        let scalars = Array(str.unicodeScalars)
        let nfcScalarCount = str.precomposedStringWithCanonicalMapping.unicodeScalars.count

        var jamoCount = 0
        var hangulSyllableCount = 0
        var hangulJamoCount = 0
        var hanjaCount = 0
        var spaceCount = 0
        var controlCount = 0
        var nonBMPCount = 0
        var asciiOtherCount = 0
        var otherBMPCount = 0

        for scalar in scalars {
            let v = scalar.value
            if v >= 0xAC00 && v <= 0xD7A3 {
                hangulSyllableCount += 1
                let jong = (v - 0xAC00) % 28
                jamoCount += (jong == 0 ? 2 : 3)
            } else if (v >= 0x1100 && v <= 0x11FF)
                || (v >= 0x3130 && v <= 0x318F)
                || (v >= 0xA960 && v <= 0xA97F)
                || (v >= 0xD7B0 && v <= 0xD7FF) {
                hangulJamoCount += 1
                jamoCount += 1
            } else if (v >= 0x4E00 && v <= 0x9FFF)
                || (v >= 0x3400 && v <= 0x4DBF)
                || (v >= 0xF900 && v <= 0xFAFF) {
                hanjaCount += 1
            } else if v == 0x0020 {
                spaceCount += 1
            } else if v < 0x0020 || v == 0x007F {
                controlCount += 1
            } else if v > 0xFFFF {
                nonBMPCount += 1
            } else if v < 0x007F {
                asciiOtherCount += 1
            } else {
                otherBMPCount += 1
            }
        }

        return TextStructureSummary(
            utf16Count: utf16Count,
            scalarCount: scalars.count,
            nfcScalarCount: nfcScalarCount,
            jamoCount: jamoCount,
            hangulSyllableCount: hangulSyllableCount,
            hangulJamoCount: hangulJamoCount,
            hanjaCount: hanjaCount,
            spaceCount: spaceCount,
            controlCount: controlCount,
            nonBMPCount: nonBMPCount,
            asciiOtherCount: asciiOtherCount,
            otherBMPCount: otherBMPCount
        )
    }

    var compactDescription: String {
        if utf16Count == 0 {
            return "empty(u16=0,jamo=0)"
        }
        var cats: [String] = []
        if hangulSyllableCount > 0 { cats.append("hangulSyl:\(hangulSyllableCount)") }
        if hangulJamoCount > 0 { cats.append("hangulJamo:\(hangulJamoCount)") }
        if hanjaCount > 0 { cats.append("hanja:\(hanjaCount)") }
        if spaceCount > 0 { cats.append("space:\(spaceCount)") }
        if controlCount > 0 { cats.append("ctrl:\(controlCount)") }
        if nonBMPCount > 0 { cats.append("nonBMP:\(nonBMPCount)") }
        if asciiOtherCount > 0 { cats.append("ascii:\(asciiOtherCount)") }
        if otherBMPCount > 0 { cats.append("other:\(otherBMPCount)") }
        let catStr = cats.isEmpty ? "none" : cats.joined(separator: "+")
        return "u16=\(utf16Count),sc=\(scalarCount),nfc=\(nfcScalarCount),jamo=\(jamoCount),cat=\(catStr)"
    }
}

private func formatRange(_ range: NSRange?) -> String {
    guard let r = range else { return "-" }
    if r.location == NSNotFound {
        return "(NF,\(r.length))"
    }
    return "(\(r.location),\(r.length))"
}

struct ProbeEventRecord: Equatable {
    let stepIndex: Int
    let elapsedMs: Int
    let eventDeltaMs: Int?
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
    let textStructure: String?
    let selectedRangeText: String?
    let replacementRangeText: String?
    let commandSelector: String?
    let hasMarkedResult: Bool?

    init(
        stepIndex: Int,
        elapsedMs: Int,
        eventDeltaMs: Int? = nil,
        view: ProbeViewKind?,
        kind: ProbeEventKind,
        keyCode: UInt16? = nil,
        modifierFlagsRaw: UInt? = nil,
        capsLockOn: Bool? = nil,
        isARepeat: Bool? = nil,
        sourceID: String,
        primaryLanguage: String,
        handleEventReturned: Bool? = nil,
        postSourceID: String? = nil,
        postPrimaryLanguage: String? = nil,
        clientTextLength: Int? = nil,
        textStructure: String? = nil,
        selectedRangeText: String? = nil,
        replacementRangeText: String? = nil,
        commandSelector: String? = nil,
        hasMarkedResult: Bool? = nil
    ) {
        self.stepIndex = stepIndex
        self.elapsedMs = elapsedMs
        self.eventDeltaMs = eventDeltaMs
        self.view = view
        self.kind = kind
        self.keyCode = keyCode
        self.modifierFlagsRaw = modifierFlagsRaw
        self.capsLockOn = capsLockOn
        self.isARepeat = isARepeat
        self.sourceID = sourceID
        self.primaryLanguage = primaryLanguage
        self.handleEventReturned = handleEventReturned
        self.postSourceID = postSourceID
        self.postPrimaryLanguage = postPrimaryLanguage
        self.clientTextLength = clientTextLength
        self.textStructure = textStructure
        self.selectedRangeText = selectedRangeText
        self.replacementRangeText = replacementRangeText
        self.commandSelector = commandSelector
        self.hasMarkedResult = hasMarkedResult
    }

    var modifierFlagsHex: String {
        guard let raw = modifierFlagsRaw else { return "-" }
        return String(format: "0x%llX", UInt64(raw))
    }
}

enum StepAdvancePolicy: Equatable {
    case singleAction(debounceSeconds: Double)
    case multiAction(debounceSeconds: Double)
    case appSwitch(postReturnDebounceSeconds: Double)
    case waitForMouseDown(postClickDebounceSeconds: Double)
    case waitForForceDiscard(postDiscardDebounceSeconds: Double)
    case waitForInsertText(postInsertDebounceSeconds: Double)
}

struct ProbeStepDefinition {
    let index: Int // 1...13
    let view: ProbeViewKind
    let methodGroup: String
    let instruction: String
    let isMultiAction: Bool
    let isAppSwitchStep: Bool
    let advancePolicy: StepAdvancePolicy
    let timeoutSeconds: Double

    init(
        index: Int,
        view: ProbeViewKind,
        methodGroup: String,
        instruction: String,
        isMultiAction: Bool,
        isAppSwitchStep: Bool,
        advancePolicy: StepAdvancePolicy? = nil,
        timeoutSeconds: Double
    ) {
        self.index = index
        self.view = view
        self.methodGroup = methodGroup
        self.instruction = instruction
        self.isMultiAction = isMultiAction
        self.isAppSwitchStep = isAppSwitchStep
        if let policy = advancePolicy {
            self.advancePolicy = policy
        } else if isAppSwitchStep {
            self.advancePolicy = .appSwitch(postReturnDebounceSeconds: 1.5)
        } else if isMultiAction {
            self.advancePolicy = .multiAction(debounceSeconds: 1.5)
        } else {
            self.advancePolicy = .singleAction(debounceSeconds: 1.5)
        }
        self.timeoutSeconds = timeoutSeconds
    }
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

// MARK: - Steps (V-H 13 Steps & V-U2 13 Steps)

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

    static let vu2All: [ProbeStepDefinition] = [
        ProbeStepDefinition(
            index: 1, view: .viewC, methodGroup: "rk 후 Space",
            instruction: "[뷰 C] 2벌식 한글에서 r, k 를 치고 Space 를 누르세요",
            isMultiAction: true, isAppSwitchStep: false,
            advancePolicy: .multiAction(debounceSeconds: 2.5), timeoutSeconds: 20.0
        ),
        ProbeStepDefinition(
            index: 2, view: .viewC, methodGroup: "rk 후 Return",
            instruction: "[뷰 C] 2벌식 한글에서 r, k 를 치고 Return(Enter) 을 누르세요",
            isMultiAction: true, isAppSwitchStep: false,
            advancePolicy: .multiAction(debounceSeconds: 2.5), timeoutSeconds: 20.0
        ),
        ProbeStepDefinition(
            index: 3, view: .viewC, methodGroup: "rk 후 Tab",
            instruction: "[뷰 C] 2벌식 한글에서 r, k 를 치고 Tab 을 누르세요",
            isMultiAction: true, isAppSwitchStep: false,
            advancePolicy: .multiAction(debounceSeconds: 2.5), timeoutSeconds: 20.0
        ),
        ProbeStepDefinition(
            index: 4, view: .viewC, methodGroup: "rk 후 ←",
            instruction: "[뷰 C] 2벌식 한글에서 r, k 를 치고 왼쪽 화살표(←)를 누르세요",
            isMultiAction: true, isAppSwitchStep: false,
            advancePolicy: .multiAction(debounceSeconds: 2.5), timeoutSeconds: 20.0
        ),
        ProbeStepDefinition(
            index: 5, view: .viewC, methodGroup: "rkr 후 Backspace 2회",
            instruction: "[뷰 C] 2벌식 한글에서 r, k, r 을 치고 Backspace(Delete)를 두 번 누르세요",
            isMultiAction: true, isAppSwitchStep: false,
            advancePolicy: .multiAction(debounceSeconds: 2.5), timeoutSeconds: 20.0
        ),
        ProbeStepDefinition(
            index: 6, view: .viewC, methodGroup: "rk 후 Esc",
            instruction: "[뷰 C] 2벌식 한글에서 r, k 를 치고 Esc 를 누르세요",
            isMultiAction: true, isAppSwitchStep: false,
            advancePolicy: .multiAction(debounceSeconds: 2.5), timeoutSeconds: 20.0
        ),
        ProbeStepDefinition(
            index: 7, view: .viewC, methodGroup: "조합 중 창 안 클릭",
            instruction: "[뷰 C] 2벌식 한글에서 r, k 를 친 뒤(조합 중) 뷰 C 안을 클릭하세요",
            isMultiAction: true, isAppSwitchStep: false,
            advancePolicy: .waitForMouseDown(postClickDebounceSeconds: 1.5), timeoutSeconds: 25.0
        ),
        ProbeStepDefinition(
            index: 8, view: .viewC, methodGroup: "조합 중 ⌘C",
            instruction: "[뷰 C] 2벌식 한글에서 r, k 를 친 뒤(조합 중) ⌘C 를 누르세요",
            isMultiAction: true, isAppSwitchStep: false,
            advancePolicy: .multiAction(debounceSeconds: 2.5), timeoutSeconds: 20.0
        ),
        ProbeStepDefinition(
            index: 9, view: .viewC, methodGroup: "조합 중 다른 앱 클릭",
            instruction: "[뷰 C] 2벌식 한글에서 r, k 를 친 뒤 다른 앱을 클릭했다가 이 창으로 돌아오세요",
            isMultiAction: false, isAppSwitchStep: true,
            advancePolicy: .appSwitch(postReturnDebounceSeconds: 1.5), timeoutSeconds: 30.0
        ),
        ProbeStepDefinition(
            index: 10, view: .viewC, methodGroup: "조합 중 강제 확정 버튼",
            instruction: "[뷰 C] 2벌식 한글에서 r, k 를 친 뒤 아래 '강제 확정' 버튼을 누르세요",
            isMultiAction: true, isAppSwitchStep: false,
            advancePolicy: .waitForForceDiscard(postDiscardDebounceSeconds: 1.5), timeoutSeconds: 25.0
        ),
        ProbeStepDefinition(
            index: 11, view: .viewC, methodGroup: "⌥Return 한자 변환",
            instruction: "[뷰 C] 2벌식 한글에서 r, k 를 치고 ⌥Return 으로 한자 후보를 열어 하나 선택하세요",
            isMultiAction: true, isAppSwitchStep: false,
            advancePolicy: .waitForInsertText(postInsertDebounceSeconds: 2.0), timeoutSeconds: 30.0
        ),
        ProbeStepDefinition(
            index: 12, view: .viewC, methodGroup: "r 1초 누름",
            instruction: "[뷰 C] 2벌식 한글에서 r 키를 약 1초간 길게 누르세요",
            isMultiAction: true, isAppSwitchStep: false,
            advancePolicy: .multiAction(debounceSeconds: 2.0), timeoutSeconds: 20.0
        ),
        ProbeStepDefinition(
            index: 13, view: .viewC, methodGroup: "⌃⌘Space 이모지 하나",
            instruction: "[뷰 C] ⌃⌘Space 로 이모지 창을 열어 이모지 하나를 선택하세요",
            isMultiAction: true, isAppSwitchStep: false,
            advancePolicy: .waitForInsertText(postInsertDebounceSeconds: 2.0), timeoutSeconds: 30.0
        ),
    ]

    static func steps(for mode: ProbeMode) -> [ProbeStepDefinition] {
        switch mode {
        case .vu2: return vu2All
        case .vh: return all
        }
    }
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

struct VU2StepRowJudgment: Equatable {
    let stepIndex: Int
    let stepName: String
    let status: String
    let callSequence: String
    let note: String
}

struct VU2JudgmentSummary: Equatable {
    let rows: [VU2StepRowJudgment]
    let returnDoCommandFinding: String
    let discardMarkedTextFinding: String
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

    static func analyzeVU2(results: [ProbeStepResult]) -> VU2JudgmentSummary {
        let byIndex = Dictionary(uniqueKeysWithValues: results.map { ($0.step.index, $0) })
        var rows: [VU2StepRowJudgment] = []

        for step in ProbeSteps.vu2All {
            guard let res = byIndex[step.index] else {
                rows.append(VU2StepRowJudgment(
                    stepIndex: step.index, stepName: step.methodGroup,
                    status: "기록 없음", callSequence: "-", note: "-"
                ))
                continue
            }
            if res.skipped {
                rows.append(VU2StepRowJudgment(
                    stepIndex: step.index, stepName: step.methodGroup,
                    status: "건너뜀", callSequence: "-", note: "건너뜀"
                ))
                continue
            }

            let clientCalls = res.events.compactMap { ev -> String? in
                switch ev.kind {
                case .clientMarked:
                    return "setMarked(\(ev.textStructure ?? "?"))"
                case .clientInsert:
                    return "insert(\(ev.textStructure ?? "?"))"
                case .clientUnmark:
                    return "unmark"
                case .clientDoCommand:
                    return "doCmd(\(ev.commandSelector ?? "?"))"
                case .forceDiscardBegin:
                    return "discardBegin"
                case .forceDiscardEnd:
                    return "discardEnd"
                case .mouseDown:
                    return "mouseDown"
                case .didResignActive, .didResignKey:
                    return ev.kind.rawValue
                default:
                    return nil
                }
            }
            let seq = clientCalls.isEmpty ? "(호출 없음)" : clientCalls.prefix(10).joined(separator: " -> ") + (clientCalls.count > 10 ? " ... (총 \(clientCalls.count)건)" : "")

            let insertCount = res.events.filter { $0.kind == .clientInsert }.count
            let markedCount = res.events.filter { $0.kind == .clientMarked }.count
            let unmarkCount = res.events.filter { $0.kind == .clientUnmark }.count
            let cmds = res.events.compactMap { $0.kind == .clientDoCommand ? $0.commandSelector : nil }
            let hasMarkedQueries = res.events.filter { $0.kind == .clientHasMarked }.count

            var noteParts: [String] = []
            noteParts.append("marked=\(markedCount), insert=\(insertCount), unmark=\(unmarkCount), hasMarked질의=\(hasMarkedQueries)")
            if !cmds.isEmpty {
                noteParts.append("doCmd=[\(cmds.joined(separator: ","))]")
            }

            rows.append(VU2StepRowJudgment(
                stepIndex: step.index,
                stepName: step.methodGroup,
                status: "완료",
                callSequence: seq,
                note: noteParts.joined(separator: "; ")
            ))
        }

        // Step 2: Return doCommand finding
        let returnFinding: String
        if let r2 = byIndex[2], !r2.skipped {
            let inserts = r2.events.filter { $0.kind == .clientInsert }
            let cmds = r2.events.compactMap { $0.kind == .clientDoCommand ? $0.commandSelector : nil }
            if !inserts.isEmpty && cmds.contains("insertNewline:") {
                returnFinding = "insertText 후 doCommand(insertNewline:) 호출됨 (4-2 (c) 규칙 필요, 원격지원 Return 누락 의심점 확인)"
            } else if !inserts.isEmpty && cmds.isEmpty {
                returnFinding = "insertText 만 호출되고 doCommand 없음 (세부 원시 기록 확인 필요)"
            } else {
                returnFinding = "insert=\(inserts.count)회, doCmd=[\(cmds.joined(separator: ","))]"
            }
        } else {
            returnFinding = "단계 2 미실시"
        }

        // Step 10: discardMarkedText finding
        let discardFinding: String
        if let r10 = byIndex[10], !r10.skipped {
            if let beginIdx = r10.events.firstIndex(where: { $0.kind == .forceDiscardBegin }) {
                let endIdx = r10.events.firstIndex(where: { $0.kind == .forceDiscardEnd }) ?? r10.events.count
                let slice = r10.events[beginIdx..<endIdx]
                let innerInserts = slice.filter { $0.kind == .clientInsert }.count
                let innerUnmarks = slice.filter { $0.kind == .clientUnmark }.count
                let innerMarkeds = slice.filter { $0.kind == .clientMarked }.count
                discardFinding = "discardMarkedText 내부: insertText=\(innerInserts)회, unmarkText=\(innerUnmarks)회, setMarkedText=\(innerMarkeds)회"
            } else {
                discardFinding = "강제 확정 버튼 클릭 기록 없음"
            }
        } else {
            discardFinding = "단계 10 미실시"
        }

        return VU2JudgmentSummary(
            rows: rows,
            returnDoCommandFinding: returnFinding,
            discardMarkedTextFinding: discardFinding
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
        mode: ProbeMode = .vh,
        timestampKST: String,
        context: ProbeEnvironmentContext,
        results: [ProbeStepResult]
    ) -> String {
        switch mode {
        case .vu2:
            return generateVU2Markdown(timestampKST: timestampKST, context: context, results: results)
        case .vh:
            return generateVHMarkdown(timestampKST: timestampKST, context: context, results: results)
        }
    }

    private static func appendEnvironmentContext(_ lines: inout [String], context: ProbeEnvironmentContext) {
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
    }

    private static func generateVU2Markdown(
        timestampKST: String,
        context: ProbeEnvironmentContext,
        results: [ProbeStepResult]
    ) -> String {
        let summary = JudgmentAnalyzer.analyzeVU2(results: results)
        var lines: [String] = []

        lines.append("# CNDF KeyProbe UF3 (V-U2) 측정 결과")
        lines.append("")
        lines.append("- 측정 시각: \(timestampKST)")
        lines.append("- 개인정보 보호: 사용자 이름, 홈 경로, 호스트명, 입력 글자 내용은 기록하지 않았습니다(조합 구조는 UTF-16/스칼라/자모 개수 및 범주로만 기록).")
        lines.append("")

        lines.append("## 1. V-U2 판정 요약표 (뷰 C)")
        lines.append("")
        lines.append("| 단계 | 조작 | 상태 | 주요 NSTextInputClient 호출 순서 | 요약 |")
        lines.append("|---:|---|---|---|---|")
        for row in summary.rows {
            lines.append("| \(row.stepIndex) | \(row.stepName) | \(row.status) | \(row.callSequence) | \(row.note) |")
        }
        lines.append("")

        lines.append("### 핵심 확인 항목")
        lines.append("")
        lines.append("- 단계 2 (Return / 원격지원 의심점): \(summary.returnDoCommandFinding)")
        lines.append("- 단계 10 (강제 확정 discardMarkedText): \(summary.discardMarkedTextFinding)")
        lines.append("")

        appendEnvironmentContext(&lines, context: context)

        lines.append("## 3. 원시 기록 (V-U2 단계 1~13)")
        lines.append("")
        for res in results {
            let status = res.skipped ? "건너뜀" : "완료"
            lines.append("### 단계 \(res.step.index)/\(ProbeSteps.vu2All.count) [\(res.step.methodGroup), 뷰 \(res.step.view.rawValue)] (\(status))")
            lines.append("- 시작 소스: `\(res.startSource.sourceID)` (`\(res.startSource.primaryLanguage)`) -> 종료 소스: `\(res.endSource.sourceID)` (`\(res.endSource.primaryLanguage)`)")
            if res.events.isEmpty {
                lines.append("- 기록된 이벤트 없음")
            } else {
                lines.append("")
                lines.append("| stepMs | evMs | 종류 | kc | flags(hex) | rep | 소스 ID | handleEvent | 구조(글자 없음) | selRange | replRange | doCommand | hasMarked |")
                lines.append("|---:|---:|---|---:|---:|:---:|---|:---:|---|---|---|---|---|")
                for ev in res.events {
                    let evMs = ev.eventDeltaMs.map { String($0) } ?? "out"
                    let kc = ev.keyCode.map { String($0) } ?? "-"
                    let rep = ev.isARepeat.map { $0 ? "1" : "0" } ?? "-"
                    let he = ev.handleEventReturned.map { $0 ? "YES" : "NO" } ?? "-"
                    let structStr = ev.textStructure ?? "-"
                    let selStr = ev.selectedRangeText ?? "-"
                    let replStr = ev.replacementRangeText ?? "-"
                    let cmdStr = ev.commandSelector ?? "-"
                    let hmStr = ev.hasMarkedResult.map { $0 ? "true" : "false" } ?? "-"
                    lines.append("| \(ev.elapsedMs) | \(evMs) | \(ev.kind.rawValue) | \(kc) | \(ev.modifierFlagsHex) | \(rep) | `\(ev.sourceID)` | \(he) | \(structStr) | \(selStr) | \(replStr) | \(cmdStr) | \(hmStr) |")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func generateVHMarkdown(
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

        appendEnvironmentContext(&lines, context: context)

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
    let steps: [ProbeStepDefinition]
    private(set) var currentIndex: Int = 0
    private(set) var completedResults: [ProbeStepResult] = []
    private(set) var currentEvents: [ProbeEventRecord] = []
    private(set) var currentStartSource: InputSourceSnapshot = InputSourceSnapshot(sourceID: "unknown", primaryLanguage: "unknown")
    private(set) var currentStepStartTime: TimeInterval = 0
    private(set) var sawResignInAppSwitchStep: Bool = false
    private(set) var sawKeyOrMarkedInCurrentStep: Bool = false
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
        sawKeyOrMarkedInCurrentStep = false
    }

    enum RecordOutcome: Equatable {
        case ignored
        case recorded(scheduleAdvanceAfterSeconds: Double?)
    }

    func recordEvent(_ event: ProbeEventRecord) -> RecordOutcome {
        guard let step = currentStep, !isFinished else { return .ignored }
        currentEvents.append(event)

        if event.kind == .keyDown || event.kind == .clientMarked {
            sawKeyOrMarkedInCurrentStep = true
        }

        switch step.advancePolicy {
        case .appSwitch(let delay):
            if event.kind == .didResignActive || event.kind == .didResignKey {
                sawResignInAppSwitchStep = true
                return .recorded(scheduleAdvanceAfterSeconds: nil)
            }
            if sawResignInAppSwitchStep && (event.kind == .didBecomeActive || event.kind == .didBecomeKey) {
                return .recorded(scheduleAdvanceAfterSeconds: delay)
            }
            return .recorded(scheduleAdvanceAfterSeconds: nil)

        case .waitForMouseDown(let delay):
            if event.kind == .mouseDown && sawKeyOrMarkedInCurrentStep {
                return .recorded(scheduleAdvanceAfterSeconds: delay)
            }
            return .recorded(scheduleAdvanceAfterSeconds: nil)

        case .waitForForceDiscard(let delay):
            if event.kind == .forceDiscardEnd {
                return .recorded(scheduleAdvanceAfterSeconds: delay)
            }
            return .recorded(scheduleAdvanceAfterSeconds: nil)

        case .waitForInsertText(let delay):
            if event.kind == .clientInsert {
                return .recorded(scheduleAdvanceAfterSeconds: delay)
            }
            return .recorded(scheduleAdvanceAfterSeconds: nil)

        case .multiAction(let delay):
            let isRelevant = event.kind == .keyDown
                || event.kind == .flagsChanged
                || event.kind == .tisNotify
                || event.kind == .clientInsert
                || event.kind == .clientMarked
                || event.kind == .clientDoCommand
            if isRelevant {
                return .recorded(scheduleAdvanceAfterSeconds: delay)
            }
            return .recorded(scheduleAdvanceAfterSeconds: nil)

        case .singleAction(let delay):
            let isRelevant = event.kind == .keyDown || event.kind == .flagsChanged || event.kind == .tisNotify
            if isRelevant {
                return .recorded(scheduleAdvanceAfterSeconds: delay)
            }
            return .recorded(scheduleAdvanceAfterSeconds: nil)
        }
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

// MARK: - View C (NSView + NSTextInputClient Composition Probe for UF3 / V-U2)

struct CompositionClientEvent {
    let kind: ProbeEventKind
    let textSummary: TextStructureSummary?
    let selectedRange: NSRange?
    let replacementRange: NSRange?
    let commandSelector: String?
    let hasMarkedResult: Bool?
}

final class CompositionProbeClient: NSObject, NSTextInputClient {
    weak var hostView: CompositionKeyProbeView?

    // Kept in memory only so macOS IME and Hanja candidate window behave naturally.
    // Never written to reports, files, or clipboard.
    private(set) var markedAttributedString: NSAttributedString = NSAttributedString()
    private(set) var markedSelectedRange: NSRange = NSRange(location: 0, length: 0)
    var suppressLogging: Bool = false

    var onClientEvent: ((CompositionClientEvent) -> Void)?
    var onDisplayChanged: (() -> Void)?

    var currentMarkedSummary: TextStructureSummary {
        TextStructureSummary.analyzeString(markedAttributedString.string)
    }

    func resetSilently() {
        suppressLogging = true
        markedAttributedString = NSAttributedString()
        markedSelectedRange = NSRange(location: 0, length: 0)
        suppressLogging = false
        onDisplayChanged?()
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let summary = TextStructureSummary.analyze(string)
        markedAttributedString = NSAttributedString()
        markedSelectedRange = NSRange(location: 0, length: 0)
        onDisplayChanged?()
        if !suppressLogging {
            onClientEvent?(CompositionClientEvent(
                kind: .clientInsert,
                textSummary: summary,
                selectedRange: nil,
                replacementRange: replacementRange,
                commandSelector: nil,
                hasMarkedResult: nil
            ))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let summary = TextStructureSummary.analyze(string)
        if let attr = string as? NSAttributedString {
            markedAttributedString = attr
        } else if let str = string as? String {
            markedAttributedString = NSAttributedString(string: str)
        } else {
            markedAttributedString = NSAttributedString()
        }
        markedSelectedRange = selectedRange
        onDisplayChanged?()
        if !suppressLogging {
            onClientEvent?(CompositionClientEvent(
                kind: .clientMarked,
                textSummary: summary,
                selectedRange: selectedRange,
                replacementRange: replacementRange,
                commandSelector: nil,
                hasMarkedResult: nil
            ))
        }
    }

    func unmarkText() {
        markedAttributedString = NSAttributedString()
        markedSelectedRange = NSRange(location: 0, length: 0)
        onDisplayChanged?()
        if !suppressLogging {
            onClientEvent?(CompositionClientEvent(
                kind: .clientUnmark,
                textSummary: nil,
                selectedRange: nil,
                replacementRange: nil,
                commandSelector: nil,
                hasMarkedResult: nil
            ))
        }
    }

    func doCommand(by selector: Selector) {
        if !suppressLogging {
            onClientEvent?(CompositionClientEvent(
                kind: .clientDoCommand,
                textSummary: nil,
                selectedRange: nil,
                replacementRange: nil,
                commandSelector: NSStringFromSelector(selector),
                hasMarkedResult: nil
            ))
        }
    }

    func selectedRange() -> NSRange {
        if markedAttributedString.length > 0 {
            return markedSelectedRange
        }
        return NSRange(location: 0, length: 0)
    }

    func markedRange() -> NSRange {
        if markedAttributedString.length > 0 {
            return NSRange(location: 0, length: markedAttributedString.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        let result = markedAttributedString.length > 0
        if !suppressLogging {
            onClientEvent?(CompositionClientEvent(
                kind: .clientHasMarked,
                textSummary: nil,
                selectedRange: nil,
                replacementRange: nil,
                commandSelector: nil,
                hasMarkedResult: result
            ))
        }
        return result
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let len = markedAttributedString.length
        guard len > 0, range.location != NSNotFound, range.location < len else { return nil }
        let clampedLen = min(range.length, len - range.location)
        let clamped = NSRange(location: range.location, length: max(0, clampedLen))
        actualRange?.pointee = clamped
        return markedAttributedString.attributedSubstring(from: clamped)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .markedClauseSegment, .backgroundColor]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let view = hostView, let window = view.window else { return .zero }
        let anchor = view.compositionAnchorRect()
        let inWindow = view.convert(anchor, to: nil)
        return window.convertToScreen(inWindow)
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}

final class CompositionKeyProbeView: NSView {
    let compositionClient = CompositionProbeClient()
    private lazy var probeInputContext: NSTextInputContext = {
        NSTextInputContext(client: compositionClient)
    }()

    var sourceReader: () -> InputSourceSnapshot = { ReadOnlySystemInspector.currentInputSource() }
    var onViewEvent: ((ProbeEventKind, NSEvent?, Int?, InputSourceSnapshot, Bool?, InputSourceSnapshot?, String?, Bool?) -> Void)?
    var onClientEvent: ((CompositionClientEvent, Int?) -> Void)?

    var isActiveTarget: Bool = false {
        didSet { needsDisplay = true }
    }

    private var activeEventStartUptime: TimeInterval?
    private var lastClickPoint: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        compositionClient.hostView = self
        compositionClient.onClientEvent = { [weak self] ev in
            guard let self else { return }
            let delta = self.currentEventDeltaMs()
            self.onClientEvent?(ev, delta)
        }
        compositionClient.onDisplayChanged = { [weak self] in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var inputContext: NSTextInputContext? { probeInputContext }

    private func currentEventDeltaMs() -> Int? {
        guard let start = activeEventStartUptime else { return nil }
        return max(0, Int((ProcessInfo.processInfo.systemUptime - start) * 1000.0))
    }

    func compositionAnchorRect() -> NSRect {
        if let pt = lastClickPoint {
            let x = max(12, min(bounds.width - 140, pt.x))
            let y = max(12, min(bounds.height - 32, pt.y - 24))
            return NSRect(x: x, y: y, width: 120, height: 24)
        }
        return NSRect(x: 16, y: 16, width: 120, height: 24)
    }

    func resetForNextStep() {
        compositionClient.suppressLogging = true
        probeInputContext.discardMarkedText()
        compositionClient.resetSilently()
        activeEventStartUptime = nil
    }

    func forceCommitViaDiscardMarkedText() {
        let preSource = sourceReader()
        let preSummary = compositionClient.currentMarkedSummary.compactDescription
        let preHasMarked = compositionClient.markedAttributedString.length > 0

        activeEventStartUptime = ProcessInfo.processInfo.systemUptime
        onViewEvent?(.forceDiscardBegin, nil, 0, preSource, nil, nil, preSummary, preHasMarked)

        probeInputContext.discardMarkedText()

        let postSource = sourceReader()
        let postHasMarked = compositionClient.markedAttributedString.length > 0
        let postSummary = compositionClient.currentMarkedSummary.compactDescription
        let delta = currentEventDeltaMs()
        onViewEvent?(.forceDiscardEnd, nil, delta, preSource, nil, postSource, postSummary, postHasMarked)
        activeEventStartUptime = nil
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        let src = sourceReader()
        let hm = compositionClient.markedAttributedString.length > 0
        onViewEvent?(.resignFirstResponder, nil, nil, src, nil, nil, compositionClient.currentMarkedSummary.compactDescription, hm)
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Note: Esc is NOT treated as skip in View C (V-U2 Step 6 tests Esc while composing).
        let preSource = sourceReader()
        activeEventStartUptime = ProcessInfo.processInfo.systemUptime
        onViewEvent?(.keyDown, event, 0, preSource, nil, nil, nil, nil)

        let handled = probeInputContext.handleEvent(event)
        let postSource = sourceReader()
        let delta = currentEventDeltaMs()
        onViewEvent?(.handleEventEnd, event, delta, preSource, handled, postSource, nil, nil)
        activeEventStartUptime = nil

        // Convenience fallback for Step 13 (Ctrl+Cmd+Space) if the system/menu did not consume it.
        let relevantMods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if !handled && event.keyCode == 49 && relevantMods == [.control, .command] {
            NSApp.orderFrontCharacterPalette(nil)
        }
    }

    override func keyUp(with event: NSEvent) {
        let preSource = sourceReader()
        onViewEvent?(.keyUp, event, 0, preSource, nil, nil, nil, nil)
    }

    override func flagsChanged(with event: NSEvent) {
        let preSource = sourceReader()
        onViewEvent?(.flagsChanged, event, 0, preSource, nil, nil, nil, nil)
    }

    override func mouseDown(with event: NSEvent) {
        lastClickPoint = convert(event.locationInWindow, from: nil)
        let preSource = sourceReader()
        let preHasMarked = compositionClient.markedAttributedString.length > 0
        activeEventStartUptime = ProcessInfo.processInfo.systemUptime
        onViewEvent?(.mouseDown, event, 0, preSource, nil, nil, compositionClient.currentMarkedSummary.compactDescription, preHasMarked)

        let handled = probeInputContext.handleEvent(event)
        let postSource = sourceReader()
        let delta = currentEventDeltaMs()
        onViewEvent?(.handleEventEnd, event, delta, preSource, handled, postSource, nil, nil)
        activeEventStartUptime = nil

        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let isFocused = (window?.firstResponder === self) || isActiveTarget
        let bgColor: NSColor = isFocused ? NSColor.systemIndigo.withAlphaComponent(0.12) : NSColor.controlBackgroundColor
        let borderColor: NSColor = isFocused ? NSColor.systemIndigo : NSColor.separatorColor
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        bgColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = isFocused ? 2.5 : 1.0
        path.stroke()

        let title = isFocused ? "뷰 C (조합 NSTextInputClient) [활성]" : "뷰 C (조합 NSTextInputClient)"
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: isFocused ? .semibold : .regular),
            .foregroundColor: isFocused ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        (title as NSString).draw(at: NSPoint(x: 16, y: bounds.height - 28), withAttributes: titleAttrs)

        let marked = compositionClient.markedAttributedString
        if marked.length > 0 {
            let boxRect = NSRect(x: 16, y: 20, width: bounds.width - 32, height: 56)
            let boxPath = NSBezierPath(roundedRect: boxRect, xRadius: 6, yRadius: 6)
            NSColor.textBackgroundColor.setFill()
            boxPath.fill()
            NSColor.separatorColor.setStroke()
            boxPath.lineWidth = 1.0
            boxPath.stroke()

            let display = NSMutableAttributedString(attributedString: marked)
            let fullRange = NSRange(location: 0, length: display.length)
            display.addAttribute(.font, value: NSFont.systemFont(ofSize: 22), range: fullRange)
            display.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
            display.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
            display.draw(at: NSPoint(x: 28, y: 34))
        } else {
            let hint = "여기에 키를 입력하거나 클릭하세요 (조합 중인 글자만 화면에 표시되며 파일에는 남지 않습니다)"
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            (hint as NSString).draw(at: NSPoint(x: 16, y: 36), withAttributes: hintAttrs)
        }
    }
}

private func isSkipEscape(_ event: NSEvent) -> Bool {
    guard event.keyCode == 53 else { return false }
    let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
    return mods.isEmpty
}

// MARK: - Main Window Controller

final class KeyProbeAppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let mode: ProbeMode
    private let smokeTestMode: Bool
    private let envContext: ProbeEnvironmentContext
    private let engine: ProbeStepEngine

    private var window: NSWindow!
    private var progressLabel: NSTextField!
    private var instructionLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var viewA: PlainKeyProbeView?
    private var viewB: ContextKeyProbeView?
    private var viewC: CompositionKeyProbeView?
    private var forceDiscardButton: NSButton?
    private var nextButton: NSButton?
    private var skipButton: NSButton!
    private var copyButton: NSButton!
    private var quitButton: NSButton!

    private var stepTimeoutTimer: Timer?
    private var postEventAdvanceTimer: Timer?
    private var finalMarkdown: String?
    private var savedFileName: String?
    private var tisObserver: NSObjectProtocol?

    init(mode: ProbeMode, smokeTestMode: Bool) {
        self.mode = mode
        self.smokeTestMode = smokeTestMode
        self.envContext = ReadOnlySystemInspector.collectEnvironmentContext()
        self.engine = ProbeStepEngine(steps: ProbeSteps.steps(for: mode))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildWindow()
        subscribeNotifications()
        startStep()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if smokeTestMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                let windowVisible = self?.window.isVisible ?? false
                let hasViewCContext = (self?.mode == .vh) ? true : (self?.viewC?.inputContext != nil)
                if windowVisible && hasViewCContext {
                    print("SMOKE_TEST_OK")
                } else {
                    fputs("SMOKE_TEST_FAIL windowVisible=\(windowVisible) hasViewCContext=\(hasViewCContext)\n", stderr)
                }
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

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "CNDF 키 프로브 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu with Emoji & Symbols only (no Cmd+C Copy item so Step 8 Cmd+C reaches View C keyDown).
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        let emojiItem = NSMenuItem(title: "이모지 및 기호", action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: " ")
        emojiItem.keyEquivalentModifierMask = [.control, .command]
        editMenu.addItem(emojiItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 720, height: 370)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = (mode == .vu2) ? "CNDF 키 프로브 UF3 (V-U2)" : "CNDF 키 프로브 (V-H)"
        window.center()
        window.delegate = self

        let content = NSView(frame: rect)
        window.contentView = content

        progressLabel = NSTextField(labelWithString: "1/\(engine.steps.count)")
        progressLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.frame = NSRect(x: 24, y: 324, width: 120, height: 22)
        content.addSubview(progressLabel)

        let privacyText = (mode == .vu2)
            ? "글자 내용 및 개인정보는 기록하지 않습니다(자모 개수·호출 순서만 기록)."
            : "글자 내용 및 개인정보는 기록하지 않습니다. 쓰지 않는 방법은 Esc 로 건너뛰세요."
        let privacyNote = NSTextField(labelWithString: privacyText)
        privacyNote.font = NSFont.systemFont(ofSize: 12)
        privacyNote.textColor = .secondaryLabelColor
        privacyNote.alignment = .right
        privacyNote.frame = NSRect(x: 150, y: 326, width: 546, height: 18)
        content.addSubview(privacyNote)

        instructionLabel = NSTextField(wrappingLabelWithString: "")
        instructionLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        instructionLabel.textColor = .labelColor
        instructionLabel.frame = NSRect(x: 24, y: 262, width: 672, height: 54)
        content.addSubview(instructionLabel)

        if mode == .vu2 {
            let vc = CompositionKeyProbeView(frame: NSRect(x: 24, y: 124, width: 672, height: 126))
            vc.onViewEvent = { [weak self] kind, event, deltaMs, preSource, handled, postSource, structStr, hasMarked in
                self?.handleViewCEvent(
                    kind: kind, event: event, deltaMs: deltaMs,
                    preSource: preSource, handled: handled, postSource: postSource,
                    textStructure: structStr, hasMarked: hasMarked
                )
            }
            vc.onClientEvent = { [weak self] clientEv, deltaMs in
                self?.handleViewCClientEvent(clientEv, deltaMs: deltaMs)
            }
            content.addSubview(vc)
            viewC = vc
        } else {
            let filter = ViewBCandidateFilter(hotkeys: envContext.hotkeys)
            let va = PlainKeyProbeView(frame: NSRect(x: 24, y: 124, width: 326, height: 120))
            let vb = ContextKeyProbeView(frame: NSRect(x: 370, y: 124, width: 326, height: 120), candidateFilter: filter)

            va.onKeyEvent = { [weak self] event, viewKind, eventKind in
                let preSource = ReadOnlySystemInspector.currentInputSource()
                self?.handleRecordedKeyEvent(event: event, view: viewKind, kind: eventKind, preSource: preSource, handleResult: nil, postSource: nil)
            }
            va.onSkipRequested = { [weak self] in
                self?.skipCurrentStep()
            }

            vb.onKeyEvent = { [weak self] event, viewKind, eventKind, preSource, handleResult, postSource in
                self?.handleRecordedKeyEvent(event: event, view: viewKind, kind: eventKind, preSource: preSource, handleResult: handleResult, postSource: postSource)
            }
            vb.onClientTextEvent = { [weak self] kind, length in
                self?.handleClientTextEvent(kind: kind, length: length)
            }
            vb.onSkipRequested = { [weak self] in
                self?.skipCurrentStep()
            }

            content.addSubview(va)
            content.addSubview(vb)
            viewA = va
            viewB = vb
        }

        statusLabel = NSTextField(wrappingLabelWithString: "준비됨")
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 24, y: 66, width: 672, height: 46)
        content.addSubview(statusLabel)

        if mode == .vu2 {
            let forceBtn = NSButton(title: "강제 확정", target: self, action: #selector(forceDiscardButtonClicked))
            forceBtn.bezelStyle = .rounded
            forceBtn.frame = NSRect(x: 24, y: 20, width: 112, height: 32)
            content.addSubview(forceBtn)
            forceDiscardButton = forceBtn

            let nextBtn = NSButton(title: "다음 단계", target: self, action: #selector(nextStepButtonClicked))
            nextBtn.bezelStyle = .rounded
            nextBtn.frame = NSRect(x: 146, y: 20, width: 100, height: 32)
            content.addSubview(nextBtn)
            nextButton = nextBtn

            skipButton = NSButton(title: "건너뛰기", target: self, action: #selector(skipButtonClicked))
            skipButton.bezelStyle = .rounded
            skipButton.frame = NSRect(x: 256, y: 20, width: 92, height: 32)
            content.addSubview(skipButton)
        } else {
            skipButton = NSButton(title: "건너뛰기 (Esc)", target: self, action: #selector(skipButtonClicked))
            skipButton.frame = NSRect(x: 24, y: 20, width: 130, height: 32)
            content.addSubview(skipButton)
        }

        copyButton = NSButton(title: "결과 복사", target: self, action: #selector(copyButtonClicked))
        copyButton.bezelStyle = .rounded
        copyButton.isEnabled = false
        copyButton.frame = NSRect(x: 470, y: 20, width: 120, height: 32)
        content.addSubview(copyButton)

        quitButton = NSButton(title: "종료", target: self, action: #selector(quitButtonClicked))
        quitButton.frame = NSRect(x: 602, y: 20, width: 94, height: 32)
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
        postEventAdvanceTimer = nil

        guard let step = engine.currentStep else {
            finishAllSteps()
            return
        }

        viewC?.resetForNextStep()

        let now = ProcessInfo.processInfo.systemUptime
        let src = ReadOnlySystemInspector.currentInputSource()
        engine.startCurrentStep(at: now, source: src)

        progressLabel.stringValue = "\(step.index)/\(engine.steps.count)"
        instructionLabel.stringValue = step.instruction
        if mode == .vu2 && step.index <= 12 && !src.isKorean {
            statusLabel.stringValue = "현재 입력 소스: \(src.sourceID) (\(src.primaryLanguage)) -- 2벌식 한글 입력기로 전환한 뒤 진행해 주세요."
        } else {
            statusLabel.stringValue = "현재 입력 소스: \(src.sourceID) (\(src.primaryLanguage))"
        }

        viewA?.isActiveTarget = (step.view == .viewA)
        viewB?.isActiveTarget = (step.view == .viewB)
        viewC?.isActiveTarget = (step.view == .viewC)

        switch step.view {
        case .viewA:
            if let va = viewA { window.makeFirstResponder(va) }
        case .viewB:
            if let vb = viewB { window.makeFirstResponder(vb) }
        case .viewC:
            if let vc = viewC { window.makeFirstResponder(vc) }
        }

        stepTimeoutTimer = Timer.scheduledTimer(withTimeInterval: step.timeoutSeconds, repeats: false) { [weak self] _ in
            self?.advanceStep(skipped: false)
        }
    }

    private func handleViewCEvent(
        kind: ProbeEventKind,
        event: NSEvent?,
        deltaMs: Int?,
        preSource: InputSourceSnapshot,
        handled: Bool?,
        postSource: InputSourceSnapshot?,
        textStructure: String?,
        hasMarked: Bool?
    ) {
        guard let step = engine.currentStep, !engine.isFinished else { return }
        let isRepeat: Bool? = (kind == .keyDown) ? event?.isARepeat : nil
        let record = ProbeEventRecord(
            stepIndex: step.index,
            elapsedMs: elapsedMs(),
            eventDeltaMs: deltaMs,
            view: .viewC,
            kind: kind,
            keyCode: event?.keyCode,
            modifierFlagsRaw: event?.modifierFlags.rawValue,
            capsLockOn: event?.modifierFlags.contains(.capsLock),
            isARepeat: isRepeat,
            sourceID: preSource.sourceID,
            primaryLanguage: preSource.primaryLanguage,
            handleEventReturned: handled,
            postSourceID: postSource?.sourceID,
            postPrimaryLanguage: postSource?.primaryLanguage,
            clientTextLength: nil,
            textStructure: textStructure,
            selectedRangeText: nil,
            replacementRangeText: nil,
            commandSelector: nil,
            hasMarkedResult: hasMarked
        )
        processRecord(record)
    }

    private func handleViewCClientEvent(_ clientEv: CompositionClientEvent, deltaMs: Int?) {
        guard let step = engine.currentStep, !engine.isFinished else { return }
        let src = ReadOnlySystemInspector.currentInputSource()
        let record = ProbeEventRecord(
            stepIndex: step.index,
            elapsedMs: elapsedMs(),
            eventDeltaMs: deltaMs,
            view: .viewC,
            kind: clientEv.kind,
            sourceID: src.sourceID,
            primaryLanguage: src.primaryLanguage,
            clientTextLength: clientEv.textSummary?.utf16Count,
            textStructure: clientEv.textSummary?.compactDescription,
            selectedRangeText: clientEv.selectedRange.map { formatRange($0) },
            replacementRangeText: clientEv.replacementRange.map { formatRange($0) },
            commandSelector: clientEv.commandSelector,
            hasMarkedResult: clientEv.hasMarkedResult
        )
        processRecord(record)
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
            sourceID: src.sourceID,
            primaryLanguage: src.primaryLanguage,
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
            sourceID: src.sourceID,
            primaryLanguage: src.primaryLanguage
        )
        processRecord(record)
    }

    private func processRecord(_ record: ProbeEventRecord) {
        guard let step = engine.currentStep else { return }
        let outcome = engine.recordEvent(record)
        let eventCount = engine.currentEvents.count
        statusLabel.stringValue = "감지됨: \(record.kind.rawValue) (누적 \(eventCount)건, 소스: \(record.sourceID))"

        if case .recorded(let delayOpt) = outcome, let delay = delayOpt {
            if step.isMultiAction {
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
        viewC?.resetForNextStep()

        let now = Date()
        let kstFormatter = DateFormatter()
        kstFormatter.locale = Locale(identifier: "en_US_POSIX")
        kstFormatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        kstFormatter.dateFormat = "yyyy-MM-dd HH:mm KST"
        let timestampKST = kstFormatter.string(from: now)

        let markdown = ReportGenerator.generateMarkdown(
            mode: mode,
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

        viewA?.isActiveTarget = false
        viewB?.isActiveTarget = false
        viewC?.isActiveTarget = false
        forceDiscardButton?.isEnabled = false
        nextButton?.isEnabled = false
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

        let prefix = (mode == .vu2) ? "cndf-keyprobe-uf3" : "cndf-keyprobe"
        var candidateName = "\(prefix)-\(baseStamp).md"
        var candidateURL = desktopURL.appendingPathComponent(candidateName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidateURL.path) {
            candidateName = "\(prefix)-\(baseStamp)-\(suffix).md"
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

    @objc private func forceDiscardButtonClicked() {
        viewC?.forceCommitViaDiscardMarkedText()
    }

    @objc private func nextStepButtonClicked() {
        advanceStep(skipped: false)
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

        // 3. Privacy-safe TextStructureSummary
        let sumEmpty = TextStructureSummary.analyzeString("")
        assertEqual(sumEmpty.compactDescription, "empty(u16=0,jamo=0)", "struct-empty")

        let sumJamo = TextStructureSummary.analyzeString("ㄱ")
        assertEqual(sumJamo.jamoCount, 1, "struct-jamo-count")
        assertEqual(sumJamo.hangulJamoCount, 1, "struct-jamo-cat")
        assertTrue(!sumJamo.compactDescription.contains("ㄱ"), "struct-jamo-no-literal")

        let sumGa = TextStructureSummary.analyzeString("가")
        assertEqual(sumGa.jamoCount, 2, "struct-ga-jamo")
        assertEqual(sumGa.hangulSyllableCount, 1, "struct-ga-syl")
        assertTrue(!sumGa.compactDescription.contains("가"), "struct-ga-no-literal")

        let sumGak = TextStructureSummary.analyzeString("각")
        assertEqual(sumGak.jamoCount, 3, "struct-gak-jamo")

        let sumNFD = TextStructureSummary.analyzeString("\u{1100}\u{1161}")
        assertEqual(sumNFD.scalarCount, 2, "struct-nfd-sc")
        assertEqual(sumNFD.nfcScalarCount, 1, "struct-nfd-nfc")
        assertEqual(sumNFD.jamoCount, 2, "struct-nfd-jamo")

        let sumGaSpace = TextStructureSummary.analyzeString("가 ")
        assertEqual(sumGaSpace.utf16Count, 2, "struct-gaspace-u16")
        assertEqual(sumGaSpace.spaceCount, 1, "struct-gaspace-space")
        assertEqual(sumGaSpace.jamoCount, 2, "struct-gaspace-jamo")

        let sumHanja = TextStructureSummary.analyzeString("家")
        assertEqual(sumHanja.hanjaCount, 1, "struct-hanja")
        assertTrue(!sumHanja.compactDescription.contains("家"), "struct-hanja-no-literal")

        let sumEmoji = TextStructureSummary.analyzeString("😀")
        assertEqual(sumEmoji.utf16Count, 2, "struct-emoji-u16")
        assertEqual(sumEmoji.nonBMPCount, 1, "struct-emoji-nonbmp")
        assertTrue(!sumEmoji.compactDescription.contains("😀"), "struct-emoji-no-literal")

        // 4. View A and View B (existing F0a checks)
        let ko = InputSourceSnapshot(sourceID: "com.apple.inputmethod.Korean.2SetKorean", primaryLanguage: "ko")
        let en = InputSourceSnapshot(sourceID: "com.apple.keylayout.ABC", primaryLanguage: "en")
        let vhEngine = ProbeStepEngine(steps: ProbeSteps.all)
        vhEngine.startCurrentStep(at: 100.0, source: en)
        assertEqual(vhEngine.currentStep?.index, 1, "vh-engine-step-1")

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

        // 5. View C (CompositionKeyProbeView + CompositionProbeClient) synthetic calls
        let viewC = CompositionKeyProbeView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        viewC.sourceReader = { ko }
        assertTrue(viewC.inputContext != nil, "viewC-inputContext-present")

        var viewCKinds: [ProbeEventKind] = []
        var viewCClientKinds: [ProbeEventKind] = []
        var viewCCommands: [String] = []
        viewC.onViewEvent = { kind, _, _, _, _, _, _, _ in
            viewCKinds.append(kind)
        }
        viewC.onClientEvent = { ev, _ in
            viewCClientKinds.append(ev.kind)
            if let cmd = ev.commandSelector {
                viewCCommands.append(cmd)
            }
        }

        // Synthetic NSTextInputClient sequence
        viewC.compositionClient.setMarkedText("ㄱ", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        assertTrue(viewC.compositionClient.hasMarkedText(), "viewC-hasMarked-true")
        assertEqual(viewC.compositionClient.markedRange(), NSRange(location: 0, length: 1), "viewC-markedRange")
        viewC.compositionClient.setMarkedText("가", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        viewC.compositionClient.insertText("가", replacementRange: NSRange(location: NSNotFound, length: 0))
        assertTrue(!viewC.compositionClient.hasMarkedText(), "viewC-hasMarked-false-after-insert")
        viewC.compositionClient.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        viewC.compositionClient.setMarkedText("가", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        viewC.compositionClient.unmarkText()
        assertTrue(!viewC.compositionClient.hasMarkedText(), "viewC-hasMarked-false-after-unmark")

        assertEqual(viewCClientKinds, [
            .clientMarked, .clientHasMarked, .clientMarked,
            .clientInsert, .clientHasMarked, .clientDoCommand,
            .clientMarked, .clientUnmark, .clientHasMarked,
        ], "viewC-client-sequence")
        assertEqual(viewCCommands, ["insertNewline:"], "viewC-doCommand-selector")

        // Esc keyDown on View C goes through keyDown + handleEventEnd (never skips)
        if let syntheticEsc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ) {
            viewC.keyDown(with: syntheticEsc)
        }
        assertTrue(viewCKinds.contains(.keyDown), "viewC-esc-keydown-recorded")
        assertTrue(viewCKinds.contains(.handleEventEnd), "viewC-esc-handleEvent-recorded")

        // Force discard button action records begin + end
        viewC.compositionClient.setMarkedText("가", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        viewC.forceCommitViaDiscardMarkedText()
        assertTrue(viewCKinds.contains(.forceDiscardBegin), "viewC-forceDiscard-begin")
        assertTrue(viewCKinds.contains(.forceDiscardEnd), "viewC-forceDiscard-end")

        // 6. V-U2 13-step progression engine with synthetic events
        let vu2Engine = ProbeStepEngine(steps: ProbeSteps.vu2All)
        assertEqual(vu2Engine.steps.count, 13, "vu2-step-count-13")

        var mockVU2Results: [ProbeStepResult] = []
        for idx in 1...13 {
            vu2Engine.startCurrentStep(at: Double(idx * 10), source: ko)
            assertEqual(vu2Engine.currentStep?.index, idx, "vu2-step-idx-\(idx)")

            switch idx {
            case 2: // rk + Return -> insert + insertNewline:
                let o1 = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: 2, elapsedMs: 10, eventDeltaMs: 0, view: .viewC, kind: .keyDown, keyCode: 15, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage))
                assertEqual(o1, .recorded(scheduleAdvanceAfterSeconds: 2.5), "vu2-step2-kd")
                _ = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: 2, elapsedMs: 12, eventDeltaMs: 2, view: .viewC, kind: .clientMarked, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage, textStructure: TextStructureSummary.analyzeString("가").compactDescription, selectedRangeText: "(0,1)", replacementRangeText: "(NF,0)"))
                _ = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: 2, elapsedMs: 50, eventDeltaMs: 1, view: .viewC, kind: .clientInsert, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage, textStructure: TextStructureSummary.analyzeString("가").compactDescription, replacementRangeText: "(NF,0)"))
                _ = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: 2, elapsedMs: 51, eventDeltaMs: 2, view: .viewC, kind: .clientDoCommand, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage, commandSelector: "insertNewline:"))

            case 7: // Click inside window while composing
                let oBefore = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: 7, elapsedMs: 5, eventDeltaMs: 0, view: .viewC, kind: .mouseDown, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage))
                assertEqual(oBefore, .recorded(scheduleAdvanceAfterSeconds: nil), "vu2-step7-click-before-key-no-advance")
                _ = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: 7, elapsedMs: 20, eventDeltaMs: 0, view: .viewC, kind: .keyDown, keyCode: 15, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage))
                let oClick = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: 7, elapsedMs: 40, eventDeltaMs: 0, view: .viewC, kind: .mouseDown, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage))
                assertEqual(oClick, .recorded(scheduleAdvanceAfterSeconds: 1.5), "vu2-step7-click-after-key-advances")

            case 9: // Switch to another app and return
                let oResign = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: 9, elapsedMs: 100, view: nil, kind: .didResignActive, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage))
                assertEqual(oResign, .recorded(scheduleAdvanceAfterSeconds: nil), "vu2-step9-resign")
                let oReturn = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: 9, elapsedMs: 500, view: nil, kind: .didBecomeActive, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage))
                assertEqual(oReturn, .recorded(scheduleAdvanceAfterSeconds: 1.5), "vu2-step9-return")

            case 10: // Force discard button
                _ = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: 10, elapsedMs: 50, eventDeltaMs: 0, view: .viewC, kind: .forceDiscardBegin, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage, textStructure: TextStructureSummary.analyzeString("가").compactDescription, hasMarkedResult: true))
                _ = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: 10, elapsedMs: 51, eventDeltaMs: 1, view: .viewC, kind: .clientInsert, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage, textStructure: TextStructureSummary.analyzeString("가").compactDescription))
                let oEnd = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: 10, elapsedMs: 52, eventDeltaMs: 2, view: .viewC, kind: .forceDiscardEnd, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage, textStructure: "empty(u16=0,jamo=0)", hasMarkedResult: false))
                assertEqual(oEnd, .recorded(scheduleAdvanceAfterSeconds: 1.5), "vu2-step10-discard-advances")

            case 11, 13: // Hanja / Emoji waits for insertText
                let oKd = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: idx, elapsedMs: 10, eventDeltaMs: 0, view: .viewC, kind: .keyDown, keyCode: 15, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage))
                assertEqual(oKd, .recorded(scheduleAdvanceAfterSeconds: nil), "vu2-step\(idx)-kd-waits")
                let sample = (idx == 11) ? "家" : "😀"
                let oIns = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: idx, elapsedMs: 300, eventDeltaMs: nil, view: .viewC, kind: .clientInsert, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage, textStructure: TextStructureSummary.analyzeString(sample).compactDescription))
                assertEqual(oIns, .recorded(scheduleAdvanceAfterSeconds: 2.0), "vu2-step\(idx)-insert-advances")

            default:
                let oKd = vu2Engine.recordEvent(ProbeEventRecord(stepIndex: idx, elapsedMs: 10, eventDeltaMs: 0, view: .viewC, kind: .keyDown, keyCode: 15, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage))
                assertTrue(oKd != .ignored, "vu2-step\(idx)-recorded")
            }

            let finished = vu2Engine.finishCurrentStep(skipped: false, endSource: ko)
            assertEqual(finished, idx == 13, "vu2-step\(idx)-finish-state")
        }
        assertTrue(vu2Engine.isFinished, "vu2-engine-finished")
        mockVU2Results = vu2Engine.completedResults

        // 7. V-U2 Judgment & Report (no PII, no literal typed text, no em/en-dash)
        let vu2Summary = JudgmentAnalyzer.analyzeVU2(results: mockVU2Results)
        assertEqual(vu2Summary.rows.count, 13, "vu2-summary-rows-13")
        assertTrue(vu2Summary.returnDoCommandFinding.contains("insertNewline:"), "vu2-return-finding")
        assertTrue(vu2Summary.discardMarkedTextFinding.contains("insertText=1회"), "vu2-discard-finding")

        let mockCtx = ProbeEnvironmentContext(
            osVersion: "Version 15.0",
            architecture: "arm64",
            hotkeys: [hk60],
            hotkeysFromFallback: false,
            fnUsageType: "2",
            globalTextInputProperties: "(없음)",
            enabledSources: [en, ko]
        )
        let vu2Md = ReportGenerator.generateMarkdown(mode: .vu2, timestampKST: "2026-11-22 05:00 KST", context: mockCtx, results: mockVU2Results)
        assertTrue(vu2Md.contains("CNDF KeyProbe UF3 (V-U2)"), "vu2-report-title")
        assertTrue(!vu2Md.contains("\u{2014}"), "vu2-report-no-emdash")
        assertTrue(!vu2Md.contains("\u{2013}"), "vu2-report-no-endash")
        assertTrue(!vu2Md.contains(NSUserName()), "vu2-report-no-username")
        assertTrue(!vu2Md.contains(NSHomeDirectory()), "vu2-report-no-homedir")
        assertTrue(!vu2Md.contains(ProcessInfo.processInfo.hostName), "vu2-report-no-hostname")
        assertTrue(!vu2Md.contains("가"), "vu2-report-no-literal-ga")
        assertTrue(!vu2Md.contains("家"), "vu2-report-no-literal-hanja")
        assertTrue(!vu2Md.contains("😀"), "vu2-report-no-literal-emoji")

        // 8. Existing V-H Judgment analyzer & report check
        let steps = ProbeSteps.all
        var mockVHResults: [ProbeStepResult] = []
        for s in steps {
            switch s.index {
            case 1:
                mockVHResults.append(ProbeStepResult(
                    step: s, skipped: false, startSource: en, endSource: ko,
                    events: [
                        ProbeEventRecord(stepIndex: 1, elapsedMs: 100, view: .viewA, kind: .flagsChanged, keyCode: 54, modifierFlagsRaw: 0x100010, capsLockOn: false, sourceID: en.sourceID, primaryLanguage: en.primaryLanguage),
                        ProbeEventRecord(stepIndex: 1, elapsedMs: 280, view: nil, kind: .tisNotify, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage),
                    ]
                ))
            case 2:
                mockVHResults.append(ProbeStepResult(
                    step: s, skipped: false, startSource: en, endSource: en,
                    events: [
                        ProbeEventRecord(stepIndex: 2, elapsedMs: 120, view: .viewA, kind: .keyDown, keyCode: 49, modifierFlagsRaw: 0x40001, capsLockOn: false, isARepeat: false, sourceID: en.sourceID, primaryLanguage: en.primaryLanguage),
                    ]
                ))
            case 7:
                mockVHResults.append(ProbeStepResult(
                    step: s, skipped: false, startSource: en, endSource: ko,
                    events: [
                        ProbeEventRecord(stepIndex: 7, elapsedMs: 120, view: .viewB, kind: .keyDown, keyCode: 49, modifierFlagsRaw: 0x40001, capsLockOn: false, isARepeat: false, sourceID: en.sourceID, primaryLanguage: en.primaryLanguage, handleEventReturned: true, postSourceID: ko.sourceID, postPrimaryLanguage: ko.primaryLanguage),
                    ]
                ))
            case 13:
                mockVHResults.append(ProbeStepResult(
                    step: s, skipped: false, startSource: en, endSource: ko,
                    events: [
                        ProbeEventRecord(stepIndex: 13, elapsedMs: 100, view: nil, kind: .didResignActive, sourceID: en.sourceID, primaryLanguage: en.primaryLanguage),
                        ProbeEventRecord(stepIndex: 13, elapsedMs: 500, view: nil, kind: .didBecomeActive, sourceID: en.sourceID, primaryLanguage: en.primaryLanguage),
                        ProbeEventRecord(stepIndex: 13, elapsedMs: 750, view: nil, kind: .tisNotify, sourceID: ko.sourceID, primaryLanguage: ko.primaryLanguage),
                    ]
                ))
            default:
                mockVHResults.append(ProbeStepResult(step: s, skipped: true, startSource: en, endSource: en, events: []))
            }
        }

        let vhSummary = JudgmentAnalyzer.analyzeAll(results: mockVHResults)
        assertEqual(vhSummary.methodRows[0].decision, "F1 로 지원(비동기 알림)", "vh-judgment-usual-async")
        assertEqual(vhSummary.methodRows[1].decision, "F1b 필요(B 의 handleEvent 에서 전환)", "vh-judgment-ctrl-space-f1b")
        assertEqual(vhSummary.step13ActivationDelayMs, 250, "vh-judgment-step13-delay")
        assertEqual(vhSummary.recommendedTSettleMs, 500, "vh-judgment-tsettle")
        assertEqual(vhSummary.usualKeyUpToNotifyDelayMs, 180, "vh-judgment-merge-delay")
        assertEqual(vhSummary.recommendedTMergeMs, 360, "vh-judgment-tmerge")

        let vhMd = ReportGenerator.generateMarkdown(mode: .vh, timestampKST: "2026-11-21 20:00 KST", context: mockCtx, results: mockVHResults)
        assertTrue(!vhMd.contains("\u{2014}"), "vh-report-no-emdash")
        assertTrue(!vhMd.contains("\u{2013}"), "vh-report-no-endash")
        assertTrue(!vhMd.contains(NSUserName()), "vh-report-no-username")
        assertTrue(!vhMd.contains(NSHomeDirectory()), "vh-report-no-homedir")
        assertTrue(!vhMd.contains(ProcessInfo.processInfo.hostName), "vh-report-no-hostname")

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

var selectedMode: ProbeMode = .vu2
if let idx = args.firstIndex(of: "--mode"), idx + 1 < args.count, let parsed = ProbeMode(rawValue: args[idx + 1]) {
    selectedMode = parsed
}

let isSmokeTest = args.contains("--smoke-test")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = KeyProbeAppController(mode: selectedMode, smokeTestMode: isSmokeTest)
app.delegate = controller
app.run()

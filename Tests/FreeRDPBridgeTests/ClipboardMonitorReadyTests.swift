import Foundation
import XCTest

final class ClipboardMonitorReadyTests: XCTestCase {
    func testMonitorReadyAdvertisesFormatsEvenWithoutLocalClipboard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FreeRDPBridge/FreeRDPBridge.c"), encoding: .utf8)

        func function(_ name: String) throws -> String {
            let start = try XCTUnwrap(source.range(of: "static UINT \(name)("))
            let end = try XCTUnwrap(source.range(of: "\n}", range: start.upperBound..<source.endIndex))
            return String(source[start.lowerBound..<end.upperBound])
        }

        let fixture = """
        #include <assert.h>
        #include <stdbool.h>
        #include <stddef.h>
        #define CHANNEL_RC_OK 0
        #define CF_UNICODETEXT 13
        #define RDP_BRIDGE_FORMAT_FILEGROUPDESCRIPTORW 100
        #define RDP_BRIDGE_FORMAT_FILECONTENTS 101
        #define CB_FORMAT_LIST 2
        #define CB_CLIP_CAPS 7
        #define CB_CAPSTYPE_GENERAL 1
        #define CB_CAPSTYPE_GENERAL_LEN 12
        #define CB_CAPS_VERSION_2 2
        #define CB_USE_LONG_FORMAT_NAMES 2
        #define CB_STREAM_FILECLIP_ENABLED 4
        #define CB_FILECLIP_NO_FILE_PATHS 8
        #define CB_HUGE_FILE_SUPPORT_ENABLED 32
        #define CB_CAN_LOCK_CLIPDATA 16
        typedef unsigned UINT;
        typedef unsigned UINT32;
        typedef struct { UINT msgType; } Header;
        typedef struct { UINT formatId; const char *formatName; } CLIPRDR_FORMAT;
        typedef struct { Header common; UINT numFormats; CLIPRDR_FORMAT *formats; } CLIPRDR_FORMAT_LIST;
        typedef struct { UINT capabilitySetType, capabilitySetLength, version, generalFlags; } CLIPRDR_GENERAL_CAPABILITY_SET;
        typedef CLIPRDR_GENERAL_CAPABILITY_SET CLIPRDR_CAPABILITY_SET;
        typedef struct { Header common; UINT cCapabilitiesSets; CLIPRDR_CAPABILITY_SET *capabilitySets; } CLIPRDR_CAPABILITIES;
        typedef struct { Header common; } CLIPRDR_MONITOR_READY;
        typedef struct CliprdrClientContext CliprdrClientContext;
        struct CliprdrClientContext {
            void *custom;
            UINT (*ClientCapabilities)(CliprdrClientContext *, const CLIPRDR_CAPABILITIES *);
            UINT (*ClientFormatList)(CliprdrClientContext *, const CLIPRDR_FORMAT_LIST *);
        };
        typedef struct { int depth; } CRITICAL_SECTION;
        static void EnterCriticalSection(CRITICAL_SECTION *lock) { assert(lock->depth++ == 0); }
        static void LeaveCriticalSection(CRITICAL_SECTION *lock) { assert(--lock->depth == 0); }
        typedef struct { CliprdrClientContext *cliprdr; const char *local_text; size_t local_file_count; unsigned clip_requests_pending, clip_requests_stale, clip_request_format; unsigned long long clip_local_gen; CRITICAL_SECTION clip_range_lock; } RDPBridgeSession;
        #define bridge_log(...) ((void)0)
        #define bridge_logf(...) ((void)0)
        // 세대 상승·잠금 수명은 ClipboardResponsePairingTests 가 따로 시험한다(설계 D-G3, clip-lock D-L3).
        static void bridge_replace_remote_clipboard(RDPBridgeSession *session, unsigned *released) { (void)session; assert(released == NULL); }
        \(try function("bridge_send_local_format_list"))
        \(try function("bridge_send_client_format_list"))
        \(try function("bridge_cliprdr_monitor_ready"))
        static UINT step, expected_count, expected_first, capability_result;
        static UINT send_capabilities(CliprdrClientContext *context, const CLIPRDR_CAPABILITIES *caps) {
            assert(step++ == 0 && caps->common.msgType == CB_CLIP_CAPS);
            // 클라 caps 에 CAN_LOCK 을 알린다(설계 clip-lock D-L3). 서버가 알리지 않으면 FreeRDP 가 지운다.
            assert(caps->capabilitySets[0].generalFlags == (CB_USE_LONG_FORMAT_NAMES | CB_STREAM_FILECLIP_ENABLED |
                                                            CB_FILECLIP_NO_FILE_PATHS | CB_CAN_LOCK_CLIPDATA |
                                                            CB_HUGE_FILE_SUPPORT_ENABLED));
            return capability_result;
        }
        static UINT send_formats(CliprdrClientContext *context, const CLIPRDR_FORMAT_LIST *list) {
            assert(step++ == 1 && list->common.msgType == CB_FORMAT_LIST);
            assert(list->numFormats == expected_count);
            if (expected_count) assert(list->formats[0].formatId == expected_first);
            if (expected_count == 2) assert(list->formats[1].formatId == RDP_BRIDGE_FORMAT_FILECONTENTS);
            return 0;
        }
        int main(void) {
            const CLIPRDR_MONITOR_READY ready = {0};
            RDPBridgeSession session = {0};
            CliprdrClientContext context = {&session, send_capabilities, send_formats};
            session.cliprdr = &context;

            assert(bridge_cliprdr_monitor_ready(&context, &ready) == 0);
            if (step != 2) return 1;

            step = 0;
            expected_count = 1;
            expected_first = CF_UNICODETEXT;
            session.local_text = "existing text";
            assert(bridge_cliprdr_monitor_ready(&context, &ready) == 0 && step == 2);

            step = 0;
            expected_count = 2;
            expected_first = RDP_BRIDGE_FORMAT_FILEGROUPDESCRIPTORW;
            session.local_text = NULL;
            session.local_file_count = 1;
            assert(bridge_cliprdr_monitor_ready(&context, &ready) == 0 && step == 2);

            step = 0;
            capability_result = 42;
            assert(bridge_cliprdr_monitor_ready(&context, &ready) == 42 && step == 1);
            return 0;
        }
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("monitor-ready.c")
        let executable = directory.appendingPathComponent("monitor-ready")
        try fixture.write(to: file, atomically: true, encoding: .utf8)

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = [file.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        guard compiler.terminationStatus == 0 else { return }

        let test = Process()
        test.executableURL = executable
        try test.run()
        test.waitUntilExit()
        XCTAssertEqual(test.terminationStatus, 0, "Monitor Ready must send a Format List after capabilities")
    }
}

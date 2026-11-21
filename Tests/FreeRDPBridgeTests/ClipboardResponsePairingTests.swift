import Foundation
import XCTest

/// 설계 existing-defects E2: FreeRDPBridge.c 의 클립보드 함수를 떼어 와 FreeRDP 형을 흉내 낸
/// fixture 와 함께 cc 로 컴파일해 돌린다(`ClipboardMonitorReadyTests` 와 같은 방식).
/// C-1 디렉터리 서술자, C-2~C-5 요청·응답 계수(INV-P1), C-6 FileContents FAIL 전달(INV-P2),
/// H 2 GiB 이상 서술자 직렬화, L 로컬 파일 요청 실패 응답.
final class ClipboardResponsePairingTests: XCTestCase {
    func testC1DirectoryMarkerBecomesDirectoryDescriptor() throws { try run("c1") }
    func testC2ResponseToRequestBeforeNewestFormatListIsDropped() throws { try run("c2") }
    func testC2ReverseOrderStillDeliversOnlyTheNewestReply() throws { try run("c2r") }
    func testC3FailedReplyIsCountedSoTheNextTextIsDelivered() throws { try run("c3") }
    func testC4ClassificationIgnoresLastRequestedFormatId() throws { try run("c4") }
    func testC5UnsolicitedReplyIsDroppedAndMonitorReadyResetsCounts() throws { try run("c5") }
    func testC6FileContentsFailIsForwardedAsNullPayload() throws { try run("c6") }
    func testHugeFileDescriptorIsSerializedWhenServerAdvertisesHugeSupport() throws { try run("huge") }
    func testDescriptorSerializationFailureAnswersFail() throws { try run("hugefail") }
    func testLocalFileRequestFailuresAnswerFail() throws { try run("local") }

    private func run(_ scenario: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FreeRDPBridge/FreeRDPBridge.c"), encoding: .utf8)

        func function(_ name: String) throws -> String {
            let start = try XCTUnwrap(source.range(of: "static UINT \(name)("))
            let end = try XCTUnwrap(source.range(of: "\n}", range: start.upperBound..<source.endIndex))
            return String(source[start.lowerBound..<end.upperBound])
        }

        let fixture = #"""
        #include <assert.h>
        #include <stdbool.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/types.h>
        #define CHANNEL_RC_OK 0
        #define CHANNEL_RC_NO_MEMORY 14
        #define ERROR_FILE_TOO_LARGE 223
        #define CF_UNICODETEXT 13
        #define RDP_BRIDGE_FORMAT_FILEGROUPDESCRIPTORW 0xC001
        #define RDP_BRIDGE_FORMAT_FILECONTENTS 0xC002
        #define CB_FORMAT_LIST 2
        #define CB_FORMAT_LIST_RESPONSE 3
        #define CB_FORMAT_DATA_REQUEST 4
        #define CB_FORMAT_DATA_RESPONSE 5
        #define CB_CLIP_CAPS 7
        #define CB_FILECONTENTS_RESPONSE 9
        #define CB_RESPONSE_OK 1
        #define CB_RESPONSE_FAIL 2
        #define CB_CAPSTYPE_GENERAL 1
        #define CB_CAPSTYPE_GENERAL_LEN 12
        #define CB_CAPS_VERSION_2 2
        #define CB_USE_LONG_FORMAT_NAMES 2
        #define CB_STREAM_FILECLIP_ENABLED 4
        #define CB_FILECLIP_NO_FILE_PATHS 8
        #define CB_HUGE_FILE_SUPPORT_ENABLED 32
        #define FD_ATTRIBUTES 0x4
        #define FD_FILESIZE 0x40
        #define FD_UNICODE 0x80000000
        #define FILE_ATTRIBUTE_DIRECTORY 0x10
        #define FILE_ATTRIBUTE_NORMAL 0x80
        #define FILECONTENTS_SIZE 1
        #define FILECONTENTS_RANGE 2
        typedef unsigned UINT;
        typedef uint32_t UINT32;
        typedef uint64_t UINT64;
        typedef uint32_t DWORD;
        typedef uint8_t BYTE;
        typedef uint16_t WCHAR;
        typedef struct { UINT msgType; UINT msgFlags; UINT dataLen; } Header;
        typedef struct { UINT formatId; const char *formatName; } CLIPRDR_FORMAT;
        typedef struct { Header common; UINT numFormats; CLIPRDR_FORMAT *formats; } CLIPRDR_FORMAT_LIST;
        typedef struct { Header common; } CLIPRDR_FORMAT_LIST_RESPONSE;
        typedef struct { Header common; UINT32 requestedFormatId; } CLIPRDR_FORMAT_DATA_REQUEST;
        typedef struct { Header common; const BYTE *requestedFormatData; } CLIPRDR_FORMAT_DATA_RESPONSE;
        typedef struct { UINT capabilitySetType, capabilitySetLength, version, generalFlags; } CLIPRDR_GENERAL_CAPABILITY_SET;
        typedef CLIPRDR_GENERAL_CAPABILITY_SET CLIPRDR_CAPABILITY_SET;
        typedef struct { Header common; UINT cCapabilitiesSets; CLIPRDR_CAPABILITY_SET *capabilitySets; } CLIPRDR_CAPABILITIES;
        typedef struct { Header common; } CLIPRDR_MONITOR_READY;
        typedef struct { DWORD dwFlags; DWORD dwFileAttributes; DWORD nFileSizeHigh; DWORD nFileSizeLow; WCHAR cFileName[260]; } FILEDESCRIPTORW;
        typedef struct { Header common; UINT32 streamId, listIndex, dwFlags, nPositionLow, nPositionHigh, cbRequested; } CLIPRDR_FILE_CONTENTS_REQUEST;
        typedef struct { Header common; UINT32 streamId; UINT32 cbRequested; const BYTE *requestedData; } CLIPRDR_FILE_CONTENTS_RESPONSE;
        typedef struct CliprdrClientContext CliprdrClientContext;
        struct CliprdrClientContext {
            void *custom;
            UINT32 lastRequestedFormatId;
            UINT (*ClientCapabilities)(CliprdrClientContext *, const CLIPRDR_CAPABILITIES *);
            UINT (*ClientFormatList)(CliprdrClientContext *, const CLIPRDR_FORMAT_LIST *);
            UINT (*ClientFormatListResponse)(CliprdrClientContext *, const CLIPRDR_FORMAT_LIST_RESPONSE *);
            UINT (*ClientFormatDataRequest)(CliprdrClientContext *, const CLIPRDR_FORMAT_DATA_REQUEST *);
            UINT (*ClientFormatDataResponse)(CliprdrClientContext *, const CLIPRDR_FORMAT_DATA_RESPONSE *);
            UINT (*ClientFileContentsResponse)(CliprdrClientContext *, const CLIPRDR_FILE_CONTENTS_RESPONSE *);
        };
        typedef struct { const char *path; const char *fileName; uint64_t size; } RDPBridgeLocalFile;
        typedef struct {
            void (*remoteText)(const uint8_t *, size_t, void *);
            void (*remoteFileList)(const uint8_t *, size_t, void *);
            void (*remoteFileContents)(uint32_t, const uint8_t *, size_t, void *);
            void *context;
        } RDPBridgeCallbacks;
        typedef struct {
            RDPBridgeCallbacks callbacks;
            CliprdrClientContext *cliprdr;
            char *local_text;
            size_t local_text_length;
            RDPBridgeLocalFile *local_files;
            size_t local_file_count;
            uint32_t clip_requests_pending;
            uint32_t clip_requests_stale;
            UINT32 clip_request_format;
            UINT32 server_clip_flags;
        } RDPBridgeSession;
        #define bridge_log(...) ((void)0)
        #define bridge_logf(...) ((void)0)

        // WinPR 대역: 시험 이름은 ASCII 만 쓴다.
        static WCHAR *ConvertUtf8NToWCharAlloc(const char *text, size_t length, size_t *count) {
            WCHAR *out = calloc(length + 1, sizeof(WCHAR));
            for (size_t i = 0; i < length; i++) out[i] = (unsigned char)text[i];
            if (count) *count = length;
            return out;
        }
        static char *ConvertWCharNToUtf8Alloc(const WCHAR *text, size_t length, size_t *count) {
            char *out = calloc(length + 1, 1);
            for (size_t i = 0; i < length && text[i]; i++) out[i] = (char)text[i];
            if (count) *count = strlen(out);
            return out;
        }
        static FILEDESCRIPTORW serialized[8];
        static UINT32 serialized_count, serialized_flags;
        static UINT cliprdr_serialize_file_list_ex(UINT32 flags, const FILEDESCRIPTORW *list, UINT32 count, BYTE **data, UINT32 *length) {
            serialized_flags = flags;
            serialized_count = count;
            memcpy(serialized, list, count * sizeof(FILEDESCRIPTORW));
            for (UINT32 i = 0; i < count; i++) {
                if (!(flags & CB_HUGE_FILE_SUPPORT_ENABLED) && (list[i].nFileSizeHigh > 0 || list[i].nFileSizeLow >= 0x80000000u))
                    return ERROR_FILE_TOO_LARGE;
            }
            *data = malloc(4);
            *length = 4;
            return CHANNEL_RC_OK;
        }

        \#(try function("bridge_send_client_format_list"))
        \#(try function("bridge_send_file_group_descriptor"))
        \#(try function("bridge_cliprdr_server_format_data_response"))
        \#(try function("bridge_cliprdr_server_capabilities"))
        \#(try function("bridge_cliprdr_monitor_ready"))
        \#(try function("bridge_cliprdr_server_format_list"))
        \#(try function("bridge_send_file_contents_failure"))
        \#(try function("bridge_cliprdr_server_file_contents_request"))
        \#(try function("bridge_cliprdr_server_file_contents_response"))

        static int texts, lists, contents_calls, requests, data_responses, contents_responses;
        static char last_text[64];
        static UINT32 last_stream, last_contents_flags, last_data_flags;
        static const uint8_t *last_payload;
        static size_t last_length;
        static void on_text(const uint8_t *p, size_t n, void *c) { texts++; snprintf(last_text, sizeof last_text, "%.*s", (int)n, (const char *)p); }
        static void on_list(const uint8_t *p, size_t n, void *c) { lists++; }
        static void on_contents(uint32_t s, const uint8_t *p, size_t n, void *c) { contents_calls++; last_stream = s; last_payload = p; last_length = n; }
        static UINT ok_caps(CliprdrClientContext *c, const CLIPRDR_CAPABILITIES *x) { return 0; }
        static UINT ok_list(CliprdrClientContext *c, const CLIPRDR_FORMAT_LIST *x) { return 0; }
        static UINT ok_list_response(CliprdrClientContext *c, const CLIPRDR_FORMAT_LIST_RESPONSE *x) { return 0; }
        static UINT on_request(CliprdrClientContext *c, const CLIPRDR_FORMAT_DATA_REQUEST *x) { requests++; return 0; }
        static UINT on_data_response(CliprdrClientContext *c, const CLIPRDR_FORMAT_DATA_RESPONSE *x) { data_responses++; last_data_flags = x->common.msgFlags; return 0; }
        static UINT on_contents_response(CliprdrClientContext *c, const CLIPRDR_FILE_CONTENTS_RESPONSE *x) { contents_responses++; last_contents_flags = x->common.msgFlags; last_stream = x->streamId; return 0; }

        static RDPBridgeSession session;
        static CliprdrClientContext context;
        static void reset(void) {
            memset(&session, 0, sizeof session);
            memset(&context, 0, sizeof context);
            context.custom = &session;
            context.ClientCapabilities = ok_caps;
            context.ClientFormatList = ok_list;
            context.ClientFormatListResponse = ok_list_response;
            context.ClientFormatDataRequest = on_request;
            context.ClientFormatDataResponse = on_data_response;
            context.ClientFileContentsResponse = on_contents_response;
            session.cliprdr = &context;
            session.callbacks.remoteText = on_text;
            session.callbacks.remoteFileList = on_list;
            session.callbacks.remoteFileContents = on_contents;
            texts = lists = contents_calls = requests = data_responses = contents_responses = 0;
            last_text[0] = 0;
        }
        static void fl_files(void) {
            CLIPRDR_FORMAT formats[] = { { 49300, "FileGroupDescriptorW" } };
            CLIPRDR_FORMAT_LIST list = { { CB_FORMAT_LIST, 0, 0 }, 1, formats };
            assert(bridge_cliprdr_server_format_list(&context, &list) == 0);
        }
        static void fl_text(void) {
            CLIPRDR_FORMAT formats[] = { { CF_UNICODETEXT, NULL } };
            CLIPRDR_FORMAT_LIST list = { { CB_FORMAT_LIST, 0, 0 }, 1, formats };
            assert(bridge_cliprdr_server_format_list(&context, &list) == 0);
        }
        static void fl_none(void) {
            CLIPRDR_FORMAT formats[] = { { 2, NULL } };
            CLIPRDR_FORMAT_LIST list = { { CB_FORMAT_LIST, 0, 0 }, 1, formats };
            assert(bridge_cliprdr_server_format_list(&context, &list) == 0);
        }
        static void reply_descriptor(void) {
            static const BYTE fgd[8] = { 1, 0, 0, 0, 0, 0, 0, 0 };
            CLIPRDR_FORMAT_DATA_RESPONSE r = { { CB_FORMAT_DATA_RESPONSE, CB_RESPONSE_OK, sizeof fgd }, fgd };
            assert(bridge_cliprdr_server_format_data_response(&context, &r) == 0);
        }
        static void reply_text(const char *text) {
            WCHAR wide[32] = { 0 };
            size_t n = strlen(text);
            for (size_t i = 0; i < n; i++) wide[i] = (unsigned char)text[i];
            CLIPRDR_FORMAT_DATA_RESPONSE r = { { CB_FORMAT_DATA_RESPONSE, CB_RESPONSE_OK, (UINT)((n + 1) * 2) }, (const BYTE *)wide };
            assert(bridge_cliprdr_server_format_data_response(&context, &r) == 0);
        }
        static void reply_fail(void) {
            CLIPRDR_FORMAT_DATA_RESPONSE r = { { CB_FORMAT_DATA_RESPONSE, CB_RESPONSE_FAIL, 0 }, NULL };
            assert(bridge_cliprdr_server_format_data_response(&context, &r) == 0);
        }
        static void monitor_ready(void) {
            CLIPRDR_MONITOR_READY ready = { { 0 } };
            assert(bridge_cliprdr_monitor_ready(&context, &ready) == 0);
        }
        static void server_caps(UINT32 flags) {
            CLIPRDR_GENERAL_CAPABILITY_SET general = { CB_CAPSTYPE_GENERAL, CB_CAPSTYPE_GENERAL_LEN, 2, flags };
            CLIPRDR_CAPABILITIES caps = { { CB_CLIP_CAPS, 0, 0 }, 1, &general };
            assert(bridge_cliprdr_server_capabilities(&context, &caps) == 0);
        }
        static void request_descriptor(void) {
            CLIPRDR_FORMAT_DATA_REQUEST request = { { CB_FORMAT_DATA_REQUEST, 0, 4 }, RDP_BRIDGE_FORMAT_FILEGROUPDESCRIPTORW };
            // 서버 요청 콜백은 정의에 없으므로 서술자 함수를 바로 부른다(요청 분기는 그대로).
            assert(bridge_send_file_group_descriptor(&context, &session) == 0);
            (void)request;
        }
        static int file_request(UINT32 index, UINT32 flags, UINT64 offset) {
            CLIPRDR_FILE_CONTENTS_REQUEST request = { { 8, 0, 24 }, 77, index, flags, (UINT32)offset, (UINT32)(offset >> 32), 16 };
            const int before = contents_responses;
            assert(bridge_cliprdr_server_file_contents_request(&context, &request) == 0);
            return contents_responses - before;
        }

        int main(int argc, char **argv) {
            const char *s = argc > 1 ? argv[1] : "";
            reset();
            if (!strcmp(s, "c1")) {
                RDPBridgeLocalFile files[] = { { "/x", "M\\", 0 }, { "/x/e", "M\\E\\", 99 }, { "/x/a", "M\\a.txt", 3 } };
                session.local_files = files;
                session.local_file_count = 3;
                request_descriptor();
                assert(serialized_count == 3 && data_responses == 1 && last_data_flags == CB_RESPONSE_OK);
                for (int i = 0; i < 2; i++) {
                    assert(serialized[i].dwFlags & FD_ATTRIBUTES);
                    assert(serialized[i].dwFileAttributes == FILE_ATTRIBUTE_DIRECTORY);
                    assert(serialized[i].nFileSizeHigh == 0 && serialized[i].nFileSizeLow == 0);
                }
                assert(serialized[0].cFileName[0] == 'M' && serialized[0].cFileName[1] == 0);
                assert(serialized[1].cFileName[2] == 'E' && serialized[1].cFileName[3] == 0);
                assert(serialized[2].dwFileAttributes == FILE_ATTRIBUTE_NORMAL && serialized[2].nFileSizeLow == 3);
                assert(serialized[2].cFileName[6] == 't' && serialized[2].cFileName[7] == 0);
                return 0;
            }
            if (!strcmp(s, "c2")) {
                fl_files(); fl_text(); reply_descriptor(); reply_text("T");
                assert(requests == 2 && texts == 1 && lists == 0 && !strcmp(last_text, "T"));
                return 0;
            }
            if (!strcmp(s, "c2r")) {
                fl_text(); fl_files(); reply_text("T"); reply_descriptor();
                assert(requests == 2 && texts == 0 && lists == 1);
                return 0;
            }
            if (!strcmp(s, "c3")) {
                fl_files(); reply_fail(); fl_text(); reply_text("T");
                assert(texts == 1 && lists == 0 && !strcmp(last_text, "T"));
                return 0;
            }
            if (!strcmp(s, "c4")) {
                fl_files();
                context.lastRequestedFormatId = CF_UNICODETEXT;
                reply_descriptor();
                assert(lists == 1 && texts == 0);
                fl_text();
                context.lastRequestedFormatId = RDP_BRIDGE_FORMAT_FILEGROUPDESCRIPTORW;
                reply_text("T");
                assert(lists == 1 && texts == 1);
                return 0;
            }
            if (!strcmp(s, "c5")) {
                reply_text("U");
                assert(texts == 0 && lists == 0);
                fl_text(); fl_text();
                monitor_ready();
                fl_text(); reply_text("V");
                assert(texts == 1 && !strcmp(last_text, "V"));
                fl_none(); reply_text("W");
                assert(texts == 1);
                return 0;
            }
            if (!strcmp(s, "c6")) {
                CLIPRDR_FILE_CONTENTS_RESPONSE fail = { { CB_FILECONTENTS_RESPONSE, CB_RESPONSE_FAIL, 4 }, 5, 0, NULL };
                assert(bridge_cliprdr_server_file_contents_response(&context, &fail) == 0);
                assert(contents_calls == 1 && last_stream == 5 && last_payload == NULL && last_length == 0);
                CLIPRDR_FILE_CONTENTS_RESPONSE empty = { { CB_FILECONTENTS_RESPONSE, CB_RESPONSE_OK, 4 }, 6, 0, NULL };
                assert(bridge_cliprdr_server_file_contents_response(&context, &empty) == 0);
                assert(contents_calls == 2 && last_stream == 6 && last_payload != NULL && last_length == 0);
                static const BYTE abc[3] = { 'a', 'b', 'c' };
                CLIPRDR_FILE_CONTENTS_RESPONSE ok = { { CB_FILECONTENTS_RESPONSE, CB_RESPONSE_OK, 7 }, 7, 3, abc };
                assert(bridge_cliprdr_server_file_contents_response(&context, &ok) == 0);
                assert(contents_calls == 3 && last_payload == abc && last_length == 3);
                return 0;
            }
            if (!strcmp(s, "huge")) {
                RDPBridgeLocalFile files[] = { { "/big", "big.bin", 0x100000000ull + 5 } };
                session.local_files = files;
                session.local_file_count = 1;
                server_caps(CB_STREAM_FILECLIP_ENABLED | CB_HUGE_FILE_SUPPORT_ENABLED);
                request_descriptor();
                assert(serialized_flags & CB_HUGE_FILE_SUPPORT_ENABLED);
                assert(serialized_flags & CB_STREAM_FILECLIP_ENABLED);
                assert(data_responses == 1 && last_data_flags == CB_RESPONSE_OK);
                assert(serialized[0].nFileSizeHigh == 1 && serialized[0].nFileSizeLow == 5);
                return 0;
            }
            if (!strcmp(s, "hugefail")) {
                RDPBridgeLocalFile files[] = { { "/big", "big.bin", 0x100000000ull + 5 } };
                session.local_files = files;
                session.local_file_count = 1;
                server_caps(CB_STREAM_FILECLIP_ENABLED);
                request_descriptor();
                assert(!(serialized_flags & CB_HUGE_FILE_SUPPORT_ENABLED));
                assert(data_responses == 1 && last_data_flags == CB_RESPONSE_FAIL);
                return 0;
            }
            if (!strcmp(s, "local")) {
                const char *scratch = getenv("PAIRING_SCRATCH");
                char path[512];
                snprintf(path, sizeof path, "%s/f.bin", scratch);
                FILE *f = fopen(path, "wb"); fwrite("abcdef", 1, 6, f); fclose(f);
                char missing[512];
                snprintf(missing, sizeof missing, "%s/missing.bin", scratch);
                RDPBridgeLocalFile files[] = { { path, "f.bin", 6 }, { missing, "missing.bin", 6 } };
                session.local_files = files;
                session.local_file_count = 2;
                assert(file_request(0, FILECONTENTS_RANGE, 0) == 1 && last_contents_flags == CB_RESPONSE_OK);
                assert(file_request(0, FILECONTENTS_SIZE, 0) == 1 && last_contents_flags == CB_RESPONSE_OK);
                assert(file_request(2, FILECONTENTS_RANGE, 0) == 1 && last_contents_flags == CB_RESPONSE_FAIL && last_stream == 77);
                assert(file_request(1, FILECONTENTS_RANGE, 0) == 1 && last_contents_flags == CB_RESPONSE_FAIL);
                assert(file_request(0, FILECONTENTS_RANGE, 0x8000000000000000ull) == 1 && last_contents_flags == CB_RESPONSE_FAIL);
                assert(file_request(0, 0, 0) == 1 && last_contents_flags == CB_RESPONSE_FAIL);
                return 0;
            }
            return 2;
        }
        """#

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cFile = directory.appendingPathComponent("pairing.c")
        let executable = directory.appendingPathComponent("pairing")
        try fixture.write(to: cFile, atomically: true, encoding: .utf8)

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = [cFile.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, file: file, line: line)
        guard compiler.terminationStatus == 0 else { return }

        let test = Process()
        test.executableURL = executable
        test.arguments = [scenario]
        test.environment = ["PAIRING_SCRATCH": directory.path]
        try test.run()
        test.waitUntilExit()
        XCTAssertEqual(test.terminationStatus, 0, "scenario \(scenario)", file: file, line: line)
    }
}

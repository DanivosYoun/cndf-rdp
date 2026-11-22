import Foundation
import XCTest

/// 설계 existing-defects E2: FreeRDPBridge.c 의 클립보드 함수를 떼어 와 FreeRDP 형을 흉내 낸
/// fixture 와 함께 cc 로 컴파일해 돌린다(`ClipboardMonitorReadyTests` 와 같은 방식).
/// C-1 디렉터리 서술자, C-2~C-5 요청·응답 계수(INV-P1), C-6 FileContents FAIL 전달(INV-P2),
/// H 2 GiB 이상 서술자 직렬화, L 로컬 파일 요청 실패 응답.
/// 설계 download-lifecycle D-G3: C-G1~C-G5 원격 복사 세대·RANGE 관문·기다리는 스트림 표(INV-G1~G4).
/// 잠금 흉내는 FreeRDP 호출·Swift 콜백이 잠금 밖에서 불리는지도 단언한다.
final class ClipboardResponsePairingTests: XCTestCase {
    func testC1DirectoryMarkerBecomesDirectoryDescriptor() throws { try run("c1") }
    func testC2ResponseToRequestBeforeNewestFormatListIsDropped() throws { try run("c2") }
    func testC2ReverseOrderStillDeliversOnlyTheNewestReply() throws { try run("c2r") }
    func testC3FailedReplyIsCountedSoTheNextTextIsDelivered() throws { try run("c3") }
    func testC4ClassificationIgnoresLastRequestedFormatId() throws { try run("c4") }
    func testC5UnsolicitedReplyIsDroppedAndMonitorReadyResetsCounts() throws { try run("c5") }
    func testC6WaitingStreamFailIsForwardedAsNullPayload() throws { try run("c6") }
    func testCG1FormatListFailsWaitingRangeAndDropsItsLateReply() throws { try run("cg1") }
    func testCG2ConsecutiveFormatListsStillAcceptRangesForTheDeliveredList() throws { try run("cg2") }
    func testCG3MonitorReadyRefusesRangesForTheDeliveredList() throws { try run("cg3") }
    func testCG4FailedDescriptorAfterNewFormatListRefusesOldRanges() throws { try run("cg4") }
    func testCG5RangeBeforeTheNewDescriptorArrivesIsRefused() throws { try run("cg5") }
    func testCGRangeInsideFileListCallbackIsAccepted() throws { try run("cgcb") }
    func testCGWaitingTableIsBoundedAndSendFailureLeavesNoEntry() throws { try run("cgtable") }
    func testHugeFileDescriptorIsSerializedWhenServerAdvertisesHugeSupport() throws { try run("huge") }
    func testDescriptorSerializationFailureAnswersFail() throws { try run("hugefail") }
    func testLocalFileRequestFailuresAnswerFail() throws { try run("local") }
    // 설계 clip-lock K3: C-L1~C-L8 과 관문~큐 투입 경합(ThreadSanitizer 로도 돌린다).
    func testCL1FormatListOrderIsResponseUnlockLockRequest() throws { try run("cl1") }
    func testCL2NoLocksWhenTheServerDoesNotAdvertiseCanLock() throws { try run("cl2") }
    func testCL3RangeCarriesTheListLockAndIsQueuedInsideTheLock() throws { try run("cl3") }
    func testCL4LocklessListAfterAStaleAnswerIsRefused() throws { try run("cl4") }
    func testCL5FormatListClearsTheStaleAnswerMark() throws { try run("cl5") }
    func testCL6LockedListIsDeliveredDespiteAStaleAnswer() throws { try run("cl6") }
    func testCL7NewChannelForgetsLocksWithoutUnlock() throws { try run("cl7") }
    func testCL8ServerLockOfAReplacedOfferAnswersFail() throws { try run("cl8") }
    func testCLRangeRacingFormatListsNeverSendsAReleasedLock() throws { try run("clrace") }
    func testCLRangeRacingFormatListsUnderThreadSanitizer() throws {
        try run("clrace", extraFlags: ["-fsanitize=thread", "-g", "-O1"])
    }
    // 설계 clip-lock-boundary K-B1: C-B0~C-B6 로컬 제공의 교체·읽기 경계(INV-L8′·L9·L10·L11).
    // 교차는 잠금 대역의 "이 스레드의 n번째 Leave 뒤 콜백" 훅으로 결정적으로 만든다(제품 코드에 훅 없음).
    func testCB0FileRequestsAreAnsweredFromTheOfferOfTheirCriticalSection() throws { try run("cb0") }
    func testCB1OfferReplacedAfterTheCheckStillSendsTheBoundBytesUnderAddressSanitizer() throws {
        try run("cb1", extraFlags: ["-fsanitize=address", "-g", "-O1"])
    }
    func testCB2RequestRightAfterTheSwapIsRefusedAsReplacedOffer() throws { try run("cb2") }
    func testCB3FailedReplacementKeepsTheOldOfferAndSendsNoFormatList() throws { try run("cb3") }
    func testCB4TextRequestDuringReplacementUnderAddressSanitizer() throws {
        try run("cb4", extraFlags: ["-fsanitize=address", "-g", "-O1"])
    }
    func testCB5DescriptorRequestDuringReplacementUnderAddressSanitizer() throws {
        try run("cb5", extraFlags: ["-fsanitize=address", "-g", "-O1"])
    }
    func testCB6ChannelAndCallerRacingUnderThreadSanitizer() throws {
        try run("cb6", extraFlags: ["-fsanitize=thread", "-g", "-O1"])
    }

    private func run(_ scenario: String, extraFlags: [String] = [], file: StaticString = #filePath, line: UInt = #line) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FreeRDPBridge/FreeRDPBridge.c"), encoding: .utf8)

        func function(_ name: String, prefix: String = "static UINT") throws -> String {
            let start = try XCTUnwrap(source.range(of: "\(prefix) \(name)("))
            let end = try XCTUnwrap(source.range(of: "\n}", range: start.upperBound..<source.endIndex))
            return String(source[start.lowerBound..<end.upperBound])
        }

        let fixture = #"""
        #include <assert.h>
        #include <errno.h>
        #include <pthread.h>
        #include <stdbool.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/types.h>
        #define RDP_FREERDP_REAL 1
        #define RDP_BRIDGE_CLIP_RANGES 8
        #define RDP_BRIDGE_CLIP_SERVER_LOCKS 100
        #define CB_CAN_LOCK_CLIPDATA 0x10
        #define CB_LOCK_CLIPDATA 0x0A
        #define CB_UNLOCK_CLIPDATA 0x0B
        #define TRUE 1
        #define FALSE 0
        #define CB_FILECONTENTS_REQUEST 8
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
        typedef int BOOL;
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
        typedef struct { Header common; UINT32 streamId, listIndex, dwFlags, nPositionLow, nPositionHigh, cbRequested; BOOL haveClipDataId; UINT32 clipDataId; } CLIPRDR_FILE_CONTENTS_REQUEST;
        typedef struct { Header common; UINT32 clipDataId; } CLIPRDR_LOCK_CLIPBOARD_DATA;
        typedef struct { Header common; UINT32 clipDataId; } CLIPRDR_UNLOCK_CLIPBOARD_DATA;
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
            UINT (*ClientFileContentsRequest)(CliprdrClientContext *, const CLIPRDR_FILE_CONTENTS_REQUEST *);
            UINT (*ClientLockClipboardData)(CliprdrClientContext *, const CLIPRDR_LOCK_CLIPBOARD_DATA *);
            UINT (*ClientUnlockClipboardData)(CliprdrClientContext *, const CLIPRDR_UNLOCK_CLIPBOARD_DATA *);
        };
        typedef enum {
            RDPBridgeStatusOK = 0,
            RDPBridgeStatusInvalidArgument = 1,
            RDPBridgeStatusNotConnected = 2,
            RDPBridgeStatusBackendUnavailable = 3,
            RDPBridgeStatusInternalError = 4
        } RDPBridgeStatus;
        // WinPR CRITICAL_SECTION 대역: 진짜 mutex 에 스레드별 깊이를 붙여 재진입·짝 어긋남을 잡는다.
        // 경합 시나리오(clrace)는 두 스레드가 이 잠금을 다툰다.
        typedef struct { pthread_mutex_t mutex; } CRITICAL_SECTION;
        static _Thread_local int lock_depth;
        static void EnterCriticalSection(CRITICAL_SECTION *lock) { assert(lock_depth == 0); pthread_mutex_lock(&lock->mutex); lock_depth++; }
        // 교차 훅(C-B*): 이 스레드의 n번째 Leave 뒤(잠금 밖)에 콜백을 한 번 부른다.
        static _Thread_local int leave_hook_countdown;
        static _Thread_local void (*leave_hook)(void);
        static void after_leave(int n, void (*hook)(void)) { leave_hook_countdown = n; leave_hook = hook; }
        static void LeaveCriticalSection(CRITICAL_SECTION *lock) {
            assert(lock_depth == 1);
            lock_depth--;
            pthread_mutex_unlock(&lock->mutex);
            if ((leave_hook != NULL) && (--leave_hook_countdown == 0)) {
                void (*hook)(void) = leave_hook;
                leave_hook = NULL;
                hook();
            }
        }
        // 새니타이저 변형: 시험이 일부러 남기는 제공을 누수로 보지 않는다(ASan 이 없으면 쓰이지 않는다).
        const char *__asan_default_options(void) { return "detect_leaks=0"; }
        // FreeRDP 호출·Swift 콜백(로그 포함)은 clip_range_lock 밖에서만 불려야 한다(설계 D-G3 잠금 범위).
        // 예외는 RANGE 송신 하나다(설계 clip-lock D-L3).
        #define UNLOCKED() assert(lock_depth == 0)
        #define LOCKED() assert(lock_depth == 1)
        typedef struct { const char *path; const char *fileName; uint64_t size; } RDPBridgeLocalFile;
        typedef struct {
            void (*remoteText)(const uint8_t *, size_t, void *);
            void (*remoteFileList)(const uint8_t *, size_t, void *);
            void (*remoteFileContents)(uint32_t, const uint8_t *, size_t, void *);
            void *context;
        } RDPBridgeCallbacks;
        typedef struct {
            RDPBridgeCallbacks callbacks;
            bool connected;
            CliprdrClientContext *cliprdr;
            char *local_text;
            size_t local_text_length;
            RDPBridgeLocalFile *local_files;
            size_t local_file_count;
            uint32_t clip_requests_pending;
            uint32_t clip_requests_stale;
            UINT32 clip_request_format;
            UINT32 server_clip_flags;
            uint64_t clip_copy;
            uint64_t clip_ranges_copy;
            uint32_t clip_ranges[RDP_BRIDGE_CLIP_RANGES];
            size_t clip_range_count;
            UINT32 clip_lock_next;
            UINT32 clip_lock_cur;
            UINT32 clip_ranges_lock;
            bool clip_stale_answer;
            uint64_t clip_local_gen;
            struct { UINT32 id; uint64_t gen; } clip_server_locks[RDP_BRIDGE_CLIP_SERVER_LOCKS];
            size_t clip_server_lock_count;
            CRITICAL_SECTION clip_range_lock;
        } RDPBridgeSession;
        // 로그는 Swift 콜백이다: 잠금 밖에서만 불려야 한다.
        #define bridge_log(...) UNLOCKED()
        #define bridge_logf(...) UNLOCKED()

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

        \#(try function("bridge_take_waiting_range", prefix: "static bool"))
        \#(try function("bridge_replace_remote_clipboard", prefix: "static void"))
        \#(try function("bridge_reset_clip_channel", prefix: "static void"))
        \#(try function("bridge_find_server_lock", prefix: "static size_t"))
        \#(try function("bridge_drop_server_lock", prefix: "static void"))
        \#(try function("bridge_cliprdr_server_lock_clipboard_data"))
        \#(try function("bridge_cliprdr_server_unlock_clipboard_data"))
        \#(try function("bridge_free_local_files", prefix: "static void"))
        \#(try function("bridge_send_local_format_list"))
        \#(try function("bridge_send_client_format_list"))
        \#(try function("bridge_publish_local_offer"))
        \#(try function("bridge_send_file_group_descriptor"))
        \#(try function("bridge_cliprdr_server_format_data_request"))
        \#(try function("bridge_cliprdr_server_format_data_response"))
        \#(try function("bridge_cliprdr_server_capabilities"))
        \#(try function("bridge_cliprdr_monitor_ready"))
        \#(try function("bridge_cliprdr_server_format_list"))
        \#(try function("bridge_send_file_contents_failure"))
        \#(try function("bridge_cliprdr_server_file_contents_request"))
        \#(try function("bridge_cliprdr_server_file_contents_response"))
        \#(try function("rdp_bridge_request_remote_file_range", prefix: "RDPBridgeStatus"))
        \#(try function("rdp_bridge_send_local_text", prefix: "RDPBridgeStatus"))
        \#(try function("rdp_bridge_send_local_files", prefix: "RDPBridgeStatus"))

        static RDPBridgeSession session;
        // 와이어 기록: FreeRDP 큐에 들어간 순서(설계 clip-lock INV-L2·L4). 큐 잠금 대역 wire_mutex 아래에서 쓴다.
        typedef struct { char kind; UINT32 value; BOOL have; } WireEvent;
        enum { WIRE_MAX = 200000 };
        static WireEvent wire[WIRE_MAX];
        static size_t wire_count;
        static pthread_mutex_t wire_mutex = PTHREAD_MUTEX_INITIALIZER;
        static void record(char kind, UINT32 value, BOOL have) {
            pthread_mutex_lock(&wire_mutex);
            assert(wire_count < WIRE_MAX);
            wire[wire_count++] = (WireEvent){ kind, value, have };
            pthread_mutex_unlock(&wire_mutex);
        }
        static size_t wire_mark;
        // 마지막 표시 뒤의 와이어를 "R U1 L2 D49300 F1" 꼴 문자열로 비교한다(R=FLR, F=RANGE 와 clipDataId, F-=id 없음).
        static void expect_wire(const char *expected) {
            char text[512] = { 0 };
            size_t used = 0;
            for (size_t i = wire_mark; i < wire_count; i++) {
                const WireEvent *e = &wire[i];
                if (e->kind == 'R') used += snprintf(text + used, sizeof text - used, "%sR", used ? " " : "");
                else if (e->kind == 'F' && !e->have) used += snprintf(text + used, sizeof text - used, "%sF-", used ? " " : "");
                else used += snprintf(text + used, sizeof text - used, "%s%c%u", used ? " " : "", e->kind, e->value);
            }
            if (strcmp(text, expected) != 0) { fprintf(stderr, "wire: [%s] expected [%s]\n", text, expected); assert(0); }
            wire_mark = wire_count;
        }
        static UINT lock_result;
        static int texts, lists, contents_calls, requests, data_responses, contents_responses, range_requests;
        static UINT range_request_result;
        static RDPBridgeStatus callback_range_status = (RDPBridgeStatus)-1;
        static bool range_from_list_callback;
        static char last_text[64];
        static UINT32 last_stream, last_contents_flags, last_data_flags;
        static const uint8_t *last_payload;
        static size_t last_length;
        // 로컬 제공 응답의 내용(C-B*): FileContents 응답 바이트, Format Data 응답 바이트, 보낸 FL 수.
        static BYTE last_contents[16];
        static UINT32 last_contents_size;
        static BYTE last_data[128];
        static UINT last_data_size;
        static int format_lists;
        static void on_text(const uint8_t *p, size_t n, void *c) { UNLOCKED(); texts++; snprintf(last_text, sizeof last_text, "%.*s", (int)n, (const char *)p); }
        static void on_list(const uint8_t *p, size_t n, void *c) {
            UNLOCKED();
            lists++;
            if (range_from_list_callback) callback_range_status = rdp_bridge_request_remote_file_range(&session, 900, 0, 0, 16);
        }
        static void on_contents(uint32_t s, const uint8_t *p, size_t n, void *c) { UNLOCKED(); contents_calls++; last_stream = s; last_payload = p; last_length = n; }
        static UINT ok_caps(CliprdrClientContext *c, const CLIPRDR_CAPABILITIES *x) { UNLOCKED(); return 0; }
        static UINT ok_list(CliprdrClientContext *c, const CLIPRDR_FORMAT_LIST *x) { UNLOCKED(); __atomic_fetch_add(&format_lists, 1, __ATOMIC_RELAXED); return 0; }
        static UINT ok_list_response(CliprdrClientContext *c, const CLIPRDR_FORMAT_LIST_RESPONSE *x) { UNLOCKED(); record('R', 0, FALSE); return 0; }
        static UINT on_request(CliprdrClientContext *c, const CLIPRDR_FORMAT_DATA_REQUEST *x) { UNLOCKED(); requests++; record('D', x->requestedFormatId, FALSE); return 0; }
        static UINT on_lock(CliprdrClientContext *c, const CLIPRDR_LOCK_CLIPBOARD_DATA *x) { UNLOCKED(); if (lock_result == 0) record('L', x->clipDataId, TRUE); return lock_result; }
        static UINT on_unlock(CliprdrClientContext *c, const CLIPRDR_UNLOCK_CLIPBOARD_DATA *x) { UNLOCKED(); record('U', x->clipDataId, TRUE); return 0; }
        static UINT on_data_response(CliprdrClientContext *c, const CLIPRDR_FORMAT_DATA_RESPONSE *x) {
            UNLOCKED();
            data_responses++;
            last_data_flags = x->common.msgFlags;
            last_data_size = x->common.dataLen;
            memset(last_data, 0, sizeof last_data);
            if ((x->common.msgFlags == CB_RESPONSE_OK) && (x->requestedFormatData != NULL) && (x->common.dataLen <= sizeof last_data))
                memcpy(last_data, x->requestedFormatData, x->common.dataLen);
            return 0;
        }
        static UINT on_contents_response(CliprdrClientContext *c, const CLIPRDR_FILE_CONTENTS_RESPONSE *x) {
            UNLOCKED();
            contents_responses++;
            last_contents_flags = x->common.msgFlags;
            last_stream = x->streamId;
            last_contents_size = x->cbRequested;
            memset(last_contents, 0, sizeof last_contents);
            if ((x->requestedData != NULL) && (x->cbRequested <= sizeof last_contents)) memcpy(last_contents, x->requestedData, x->cbRequested);
            return 0;
        }
        // RANGE 는 관문을 통과한 그 잠금 안에서 큐에 들어가야 한다(설계 clip-lock D-L3, C-L3).
        static UINT on_range_request(CliprdrClientContext *c, const CLIPRDR_FILE_CONTENTS_REQUEST *x) {
            LOCKED();
            range_requests++;
            assert(x->dwFlags == FILECONTENTS_RANGE);
            if (range_request_result == CHANNEL_RC_OK) record('F', x->clipDataId, x->haveClipDataId);
            return range_request_result;
        }

        static CliprdrClientContext context;
        static void reset(void) {
            memset(&session, 0, sizeof session);
            pthread_mutex_init(&session.clip_range_lock.mutex, NULL);
            memset(&context, 0, sizeof context);
            context.custom = &session;
            context.ClientCapabilities = ok_caps;
            context.ClientFormatList = ok_list;
            context.ClientFormatListResponse = ok_list_response;
            context.ClientFormatDataRequest = on_request;
            context.ClientFormatDataResponse = on_data_response;
            context.ClientFileContentsResponse = on_contents_response;
            context.ClientFileContentsRequest = on_range_request;
            context.ClientLockClipboardData = on_lock;
            context.ClientUnlockClipboardData = on_unlock;
            session.connected = true;
            session.cliprdr = &context;
            session.callbacks.remoteText = on_text;
            session.callbacks.remoteFileList = on_list;
            session.callbacks.remoteFileContents = on_contents;
            texts = lists = contents_calls = requests = data_responses = contents_responses = range_requests = format_lists = 0;
            range_request_result = CHANNEL_RC_OK;
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
        static int file_request_lock(UINT32 index, UINT32 flags, UINT64 offset, BOOL have, UINT32 id) {
            CLIPRDR_FILE_CONTENTS_REQUEST request = { { 8, 0, 24 }, 77, index, flags, (UINT32)offset, (UINT32)(offset >> 32), 16, have, id };
            const int before = contents_responses;
            assert(bridge_cliprdr_server_file_contents_request(&context, &request) == 0);
            return contents_responses - before;
        }
        static void server_lock(UINT32 id) {
            CLIPRDR_LOCK_CLIPBOARD_DATA lock = { { CB_LOCK_CLIPDATA, 0, 4 }, id };
            assert(bridge_cliprdr_server_lock_clipboard_data(&context, &lock) == 0);
        }
        static void server_unlock(UINT32 id) {
            CLIPRDR_UNLOCK_CLIPBOARD_DATA unlock = { { CB_UNLOCK_CLIPDATA, 0, 4 }, id };
            assert(bridge_cliprdr_server_unlock_clipboard_data(&context, &unlock) == 0);
        }
        static int file_request(UINT32 index, UINT32 flags, UINT64 offset) {
            CLIPRDR_FILE_CONTENTS_REQUEST request = { { 8, 0, 24 }, 77, index, flags, (UINT32)offset, (UINT32)(offset >> 32), 16 };
            const int before = contents_responses;
            assert(bridge_cliprdr_server_file_contents_request(&context, &request) == 0);
            return contents_responses - before;
        }

        static RDPBridgeStatus range(UINT32 stream) {
            const RDPBridgeStatus status = rdp_bridge_request_remote_file_range(&session, stream, 0, 0, 16);
            UNLOCKED();
            return status;
        }
        static void contents_reply(UINT32 stream, UINT flags) {
            static const BYTE abc[3] = { 'a', 'b', 'c' };
            CLIPRDR_FILE_CONTENTS_RESPONSE r = { { CB_FILECONTENTS_RESPONSE, flags, 3 }, stream, flags == CB_RESPONSE_OK ? 3 : 0, flags == CB_RESPONSE_OK ? abc : NULL };
            assert(bridge_cliprdr_server_file_contents_response(&context, &r) == 0);
        }
        // 파일 FL 과 그 서술자 응답: 목록이 앱에 넘어가 지금 세대가 RANGE 대상이 된다.
        static void deliver_files(void) {
            const int before = lists;
            fl_files(); reply_descriptor();
            assert(lists == before + 1);
        }

        // 로컬 제공 시험 고정물(C-B*): 임시 파일 A=AAAA, B=BBBBB, C=CCCC.
        static char path_a[512], path_b[512], path_c[512];
        static void write_file(char *path, const char *name, const char *bytes) {
            snprintf(path, 512, "%s/%s", getenv("PAIRING_SCRATCH"), name);
            FILE *f = fopen(path, "wb"); fwrite(bytes, 1, strlen(bytes), f); fclose(f);
        }
        static void make_files(void) { write_file(path_a, "a.bin", "AAAA"); write_file(path_b, "b.bin", "BBBBB"); write_file(path_c, "c.bin", "CCCC"); }
        static void offer_one(const char *path, const char *name, uint64_t size) {
            RDPBridgeLocalFile file = { path, name, size };
            assert(rdp_bridge_send_local_files(&session, &file, 1) == RDPBridgeStatusOK);
        }
        static void offer_a(void) { offer_one(path_a, "a.bin", 4); }
        static void offer_b(void) { offer_one(path_b, "b.bin", 5); }
        static void offer_text(const char *text) { assert(rdp_bridge_send_local_text(&session, (const uint8_t *)text, strlen(text)) == RDPBridgeStatusOK); }
        static void offer_new_text(void) { offer_text("NEWTEXT-LONGER"); }
        static void range_id7(void) { assert(file_request_lock(0, FILECONTENTS_RANGE, 0, TRUE, 7) == 1); }
        static void expect_contents(UINT flags, const char *bytes) {
            assert(last_contents_flags == flags);
            if (bytes != NULL) assert(last_contents_size == strlen(bytes) && memcmp(last_contents, bytes, strlen(bytes)) == 0);
        }
        static void request_text(void) {
            CLIPRDR_FORMAT_DATA_REQUEST request = { { CB_FORMAT_DATA_REQUEST, 0, 4 }, CF_UNICODETEXT };
            assert(bridge_cliprdr_server_format_data_request(&context, &request) == 0);
        }
        static void request_text_now(void) { request_text(); }
        static void expect_text(const char *text) {
            const size_t n = strlen(text);
            assert(last_data_flags == CB_RESPONSE_OK && last_data_size == (n + 1) * 2);
            const WCHAR *wide = (const WCHAR *)last_data;
            for (size_t i = 0; i < n; i++) assert(wide[i] == (unsigned char)text[i]);
            assert(wide[n] == 0);
        }

        // C-B6: 호출자 스레드가 제공을 바꾸는 동안 채널 스레드가 잠금을 걸고 그 잠금으로 크기·내용을 묻는다.
        static void *cb6_publisher(void *unused) {
            for (int i = 0; i < 10000; i++) {
                if (i % 3 == 0) offer_a();
                else if (i % 3 == 1) offer_b();
                else offer_text("T");
            }
            return NULL;
        }

        static bool race_done;
        static void *race_sender(void *unused) {
            for (UINT32 stream = 1; !__atomic_load_n(&race_done, __ATOMIC_SEQ_CST); stream++) (void)range(stream);
            return NULL;
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
                // INV-P2(D-G3 개정): 기다리는 스트림의 응답만 전달한다.
                deliver_files();
                assert(range(5) == RDPBridgeStatusOK && range(6) == RDPBridgeStatusOK && range(7) == RDPBridgeStatusOK);
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
                assert(session.clip_range_count == 0);
                return 0;
            }
            if (!strcmp(s, "cg1")) {
                // C-G1: 넘긴 목록의 s1 이 기다리는 중에 텍스트 FL → s1 즉시 FAIL, 늦은 s1 응답은 버린다.
                deliver_files();
                assert(range(1) == RDPBridgeStatusOK && range_requests == 1);
                fl_text();
                assert(contents_calls == 1 && last_stream == 1 && last_payload == NULL && last_length == 0);
                contents_reply(1, CB_RESPONSE_OK);
                assert(contents_calls == 1);
                assert(range(2) == RDPBridgeStatusNotConnected && range_requests == 1);
                return 0;
            }
            if (!strcmp(s, "cg2")) {
                // C-G2: FL → FL → 오래된 r1 버림 → r2 목록 → RANGE 수락(정상 경로).
                fl_files(); fl_files();
                reply_descriptor();
                assert(lists == 0);
                reply_descriptor();
                assert(lists == 1);
                assert(range(1) == RDPBridgeStatusOK && range_requests == 1);
                contents_reply(1, CB_RESPONSE_OK);
                assert(contents_calls == 1 && last_stream == 1 && last_length == 3);
                return 0;
            }
            if (!strcmp(s, "cg3")) {
                // C-G3: 목록을 넘긴 뒤 MonitorReady → RANGE 거부.
                deliver_files();
                assert(range(1) == RDPBridgeStatusOK);
                monitor_ready();
                assert(contents_calls == 1 && last_stream == 1 && last_payload == NULL);
                assert(range(2) == RDPBridgeStatusNotConnected && range_requests == 1);
                return 0;
            }
            if (!strcmp(s, "cg4")) {
                // C-G4(4B 의 FreeRDP 판): 새 파일 FL 의 서술자가 FAIL 이면 옛 목록의 RANGE 는 거부.
                deliver_files();
                assert(range(1) == RDPBridgeStatusOK);
                fl_files();
                assert(contents_calls == 1 && last_stream == 1 && last_payload == NULL);
                reply_fail();
                assert(lists == 1);
                assert(range(2) == RDPBridgeStatusNotConnected && range_requests == 1);
                return 0;
            }
            if (!strcmp(s, "cg5")) {
                // C-G5: 새 파일 FL 뒤 서술자 응답이 오기 전의 RANGE 는 거부, 응답이 오면 수락.
                assert(range(1) == RDPBridgeStatusNotConnected);
                deliver_files();
                fl_files();
                assert(range(2) == RDPBridgeStatusNotConnected && range_requests == 0);
                reply_descriptor();
                assert(lists == 2 && range(3) == RDPBridgeStatusOK && range_requests == 1);
                return 0;
            }
            if (!strcmp(s, "cgcb")) {
                // INV-G4: 목록 콜백 안에서 곧바로 보낸 RANGE 는 수락된다.
                range_from_list_callback = true;
                deliver_files();
                assert(callback_range_status == RDPBridgeStatusOK && range_requests == 1);
                return 0;
            }
            if (!strcmp(s, "cgtable")) {
                // 표가 가득 차면 fail-closed, 보내기 실패는 표에 남지 않는다.
                deliver_files();
                range_request_result = 5;
                assert(range(50) == RDPBridgeStatusInternalError && session.clip_range_count == 0);
                contents_reply(50, CB_RESPONSE_OK);
                assert(contents_calls == 0);
                range_request_result = CHANNEL_RC_OK;
                for (UINT32 i = 0; i < RDP_BRIDGE_CLIP_RANGES; i++) assert(range(100 + i) == RDPBridgeStatusOK);
                const int sent = range_requests;
                assert(range(200) == RDPBridgeStatusInternalError && range_requests == sent);
                contents_reply(103, CB_RESPONSE_OK);
                assert(contents_calls == 1 && last_stream == 103);
                assert(range(201) == RDPBridgeStatusOK);
                fl_text();
                assert(contents_calls == 1 + RDP_BRIDGE_CLIP_RANGES && session.clip_range_count == 0);
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
            if (!strcmp(s, "cl1")) {
                // C-L1: FLR → Unlock(이전) → Lock(파일일 때) → 서술자 요청(INV-L2), 보유 잠금은 1개 이하(INV-L1).
                server_caps(CB_STREAM_FILECLIP_ENABLED | CB_CAN_LOCK_CLIPDATA);
                fl_files();
                expect_wire("R L1 D49300");
                reply_descriptor();
                fl_files();
                expect_wire("R U1 L2 D49300");
                fl_text();
                expect_wire("R U2 D13");
                fl_text();
                expect_wire("R D13");
                return 0;
            }
            if (!strcmp(s, "cl2")) {
                // C-L2: 서버가 CAN_LOCK 을 알리지 않으면(또는 Caps 가 없으면) Lock/Unlock 0, RANGE 에 id 없음(INV-L5).
                deliver_files();
                expect_wire("R D49300");
                server_caps(CB_STREAM_FILECLIP_ENABLED);
                deliver_files();
                assert(range(1) == RDPBridgeStatusOK);
                fl_text();
                expect_wire("R D49300 F- R D13");
                return 0;
            }
            if (!strcmp(s, "cl3")) {
                // C-L3: 넘긴 목록의 RANGE 는 그 목록의 잠금 id 를 달고, 관문을 통과한 잠금 안에서 큐에 들어간다
                // (on_range_request 의 LOCKED). FL 이 푼 id 는 다시 나가지 않는다(INV-L3·L4).
                server_caps(CB_STREAM_FILECLIP_ENABLED | CB_CAN_LOCK_CLIPDATA);
                deliver_files();
                assert(range(1) == RDPBridgeStatusOK);
                expect_wire("R L1 D49300 F1");
                fl_files();
                assert(range(2) == RDPBridgeStatusNotConnected);
                reply_descriptor();
                assert(range(3) == RDPBridgeStatusOK);
                expect_wire("R U1 L2 D49300 F2");
                // Lock 송신이 실패하면 그 목록은 잠금 없이 넘어가고 RANGE 에도 id 가 없다.
                lock_result = 5;
                deliver_files();
                assert(range(4) == RDPBridgeStatusOK);
                expect_wire("R U2 D49300 F-");
                return 0;
            }
            if (!strcmp(s, "cl4")) {
                // C-L4(R-L2): 잠금 없음, A 를 넘기고 s1 이 나간 상태 → FL(B) → 옛 s1 응답 → D_B 는 넘기지 않는다(P4).
                deliver_files();
                assert(range(1) == RDPBridgeStatusOK);
                fl_files();
                contents_reply(1, CB_RESPONSE_OK);
                reply_descriptor();
                assert(lists == 1);
                assert(range(2) == RDPBridgeStatusNotConnected && range_requests == 1);
                return 0;
            }
            if (!strcmp(s, "cl5")) {
                // C-L5(R-L3): FL → 옛 응답 → FL → D 이면 넘긴다(표지는 서버 FL 마다 지운다).
                deliver_files();
                assert(range(1) == RDPBridgeStatusOK);
                fl_files();
                contents_reply(1, CB_RESPONSE_OK);
                fl_files();
                reply_descriptor();
                reply_descriptor();
                assert(lists == 2);
                assert(range(2) == RDPBridgeStatusOK);
                return 0;
            }
            if (!strcmp(s, "cl6")) {
                // C-L6(R-L4): 잠금이 있으면 C-L4 와 같은 순서여도 넘긴다(P4 는 잠금 없는 목록에만).
                server_caps(CB_STREAM_FILECLIP_ENABLED | CB_CAN_LOCK_CLIPDATA);
                deliver_files();
                assert(range(1) == RDPBridgeStatusOK);
                fl_files();
                contents_reply(1, CB_RESPONSE_OK);
                reply_descriptor();
                assert(lists == 2);
                assert(range(2) == RDPBridgeStatusOK);
                expect_wire("R L1 D49300 F1 R U1 L2 D49300 F2");
                return 0;
            }
            if (!strcmp(s, "cl7")) {
                // C-L7: 새 채널은 이전 채널의 잠금·서버 능력을 Unlock 없이 잊는다(INV-L6). MonitorReady 는 잊지 않는다.
                server_caps(CB_STREAM_FILECLIP_ENABLED | CB_CAN_LOCK_CLIPDATA);
                deliver_files();
                monitor_ready();
                fl_files();
                expect_wire("R L1 D49300 R U1 L2 D49300");
                reply_descriptor();
                bridge_reset_clip_channel(&session);
                assert(range(1) == RDPBridgeStatusOK);
                fl_files();
                expect_wire("F- R D49300");
                server_caps(CB_STREAM_FILECLIP_ENABLED | CB_CAN_LOCK_CLIPDATA);
                fl_files();
                expect_wire("R L3 D49300");
                return 0;
            }
            if (!strcmp(s, "cl8")) {
                // C-L8(R-L6): 서버 잠금은 받은 때의 로컬 제공에 묶인다(INV-L8). 제공이 바뀌면 그 id 는 FAIL.
                const char *scratch = getenv("PAIRING_SCRATCH");
                char path[512];
                snprintf(path, sizeof path, "%s/f.bin", scratch);
                FILE *f = fopen(path, "wb"); fwrite("abcdef", 1, 6, f); fclose(f);
                RDPBridgeLocalFile files[] = { { path, "f.bin", 6 } };
                session.local_files = files;
                session.local_file_count = 1;
                assert(bridge_send_client_format_list(&session) == 0);
                server_lock(7);
                assert(file_request_lock(0, FILECONTENTS_RANGE, 0, TRUE, 7) == 1 && last_contents_flags == CB_RESPONSE_OK);
                assert(bridge_send_client_format_list(&session) == 0);
                assert(file_request_lock(0, FILECONTENTS_RANGE, 0, TRUE, 7) == 1 && last_contents_flags == CB_RESPONSE_FAIL);
                assert(file_request(0, FILECONTENTS_RANGE, 0) == 1 && last_contents_flags == CB_RESPONSE_OK);
                server_lock(8);
                assert(file_request_lock(0, FILECONTENTS_SIZE, 0, TRUE, 8) == 1 && last_contents_flags == CB_RESPONSE_OK);
                assert(file_request_lock(0, FILECONTENTS_RANGE, 0, TRUE, 9) == 1 && last_contents_flags == CB_RESPONSE_FAIL);
                server_unlock(8);
                assert(file_request_lock(0, FILECONTENTS_RANGE, 0, TRUE, 8) == 1 && last_contents_flags == CB_RESPONSE_FAIL);
                // 표는 100칸: 101번째 잠금이 오면 가장 오래된 것을 잊는다.
                for (UINT32 id = 1000; id <= 1100; id++) server_lock(id);
                assert(session.clip_server_lock_count == RDP_BRIDGE_CLIP_SERVER_LOCKS);
                assert(file_request_lock(0, FILECONTENTS_RANGE, 0, TRUE, 1000) == 1 && last_contents_flags == CB_RESPONSE_FAIL);
                assert(file_request_lock(0, FILECONTENTS_RANGE, 0, TRUE, 1001) == 1 && last_contents_flags == CB_RESPONSE_OK);
                assert(file_request_lock(0, FILECONTENTS_RANGE, 0, TRUE, 1100) == 1 && last_contents_flags == CB_RESPONSE_OK);
                return 0;
            }
            if (!strcmp(s, "cb0")) {
                // C-B0: 파일 3개에 RANGE·SIZE, 잠금 id 있음·없음, 범위 밖 색인.
                make_files();
                RDPBridgeLocalFile files[] = { { path_a, "a.bin", 4 }, { path_b, "b.bin", 5 }, { path_c, "c.bin", 4 } };
                assert(rdp_bridge_send_local_files(&session, files, 3) == RDPBridgeStatusOK && format_lists == 1);
                server_lock(7);
                const char *expected[] = { "AAAA", "BBBBB", "CCCC" };
                for (UINT32 i = 0; i < 3; i++) {
                    assert(file_request_lock(i, FILECONTENTS_RANGE, 0, TRUE, 7) == 1); expect_contents(CB_RESPONSE_OK, expected[i]);
                    assert(file_request(i, FILECONTENTS_RANGE, 0) == 1); expect_contents(CB_RESPONSE_OK, expected[i]);
                    assert(file_request_lock(i, FILECONTENTS_SIZE, 0, TRUE, 7) == 1 && last_contents_flags == CB_RESPONSE_OK);
                    UINT64 size = 0; memcpy(&size, last_contents, sizeof size);
                    assert(last_contents_size == 8 && size == strlen(expected[i]));
                    assert(file_request(i, FILECONTENTS_SIZE, 0) == 1 && last_contents_flags == CB_RESPONSE_OK);
                }
                assert(file_request_lock(3, FILECONTENTS_RANGE, 0, TRUE, 7) == 1 && last_contents_flags == CB_RESPONSE_FAIL);
                assert(file_request(3, FILECONTENTS_SIZE, 0) == 1 && last_contents_flags == CB_RESPONSE_FAIL);
                // 색인 검사와 대상 선택은 한 임계 구역이다: 그 구역을 나온 직후 파일 하나짜리로 바뀌어도
                // 검사를 통과한 색인 2 의 (옛 제공) 바이트가 나간다. 색인 검사를 잠금 밖에서 하면 FAIL 이 된다.
                after_leave(1, offer_a);
                assert(file_request(2, FILECONTENTS_RANGE, 0) == 1); expect_contents(CB_RESPONSE_OK, "CCCC");
                assert(session.local_file_count == 1);
                return 0;
            }
            if (!strcmp(s, "cb1")) {
                // C-B1: 잠금 7(gen 1). RANGE(id 7) 의 Leave 직후 제공이 B 로 바뀌어도 그 잠금의 세대(A) 바이트가 나간다.
                make_files();
                offer_a();
                assert(session.clip_local_gen == 1);
                server_lock(7);
                after_leave(1, offer_b);
                range_id7();
                expect_contents(CB_RESPONSE_OK, "AAAA");
                assert(session.clip_local_gen == 2 && format_lists == 2);
                range_id7();
                expect_contents(CB_RESPONSE_FAIL, NULL);
                return 0;
            }
            if (!strcmp(s, "cb2")) {
                // C-B2: publish 의 교체 직후(그 Leave 뒤) 온 RANGE(id 7) 는 replaced-offer FAIL 이다(교체·세대 상승이 한 구역).
                make_files();
                offer_a();
                server_lock(7);
                after_leave(1, range_id7);
                offer_b();
                assert(contents_responses == 1);
                expect_contents(CB_RESPONSE_FAIL, NULL);
                assert(file_request(0, FILECONTENTS_RANGE, 0) == 1); expect_contents(CB_RESPONSE_OK, "BBBBB");
                return 0;
            }
            if (!strcmp(s, "cb3")) {
                // C-B3: 새 제공을 만들다 실패하면(path=NULL) 옛 제공·세대가 그대로이고 FL 을 보내지 않는다(INV-L11).
                make_files();
                offer_a();
                server_lock(7);
                RDPBridgeLocalFile bad[] = { { path_b, "b.bin", 5 }, { NULL, "x.bin", 1 } };
                assert(rdp_bridge_send_local_files(&session, bad, 2) == RDPBridgeStatusInvalidArgument);
                assert(format_lists == 1 && session.clip_local_gen == 1);
                range_id7(); expect_contents(CB_RESPONSE_OK, "AAAA");
                assert(file_request(0, FILECONTENTS_RANGE, 0) == 1); expect_contents(CB_RESPONSE_OK, "AAAA");
                return 0;
            }
            if (!strcmp(s, "cb4")) {
                // C-B4: 텍스트 요청 중 교체 → 옛 텍스트 그대로. 교체 직후의 요청 → 새 텍스트 그대로(길이·바이트가 한 단위).
                offer_text("OLD");
                after_leave(1, offer_new_text);
                request_text();
                expect_text("OLD");
                assert(format_lists == 2);
                after_leave(1, request_text_now);
                offer_text("NEW");
                expect_text("NEW");
                after_leave(1, request_text_now);
                offer_new_text();
                expect_text("NEWTEXT-LONGER");
                return 0;
            }
            if (!strcmp(s, "cb5")) {
                // C-B5: 서술자 요청 중 교체 → 서술자는 전부 옛 제공(A)의 것이다.
                make_files();
                RDPBridgeLocalFile files[] = { { path_a, "a0.bin", 4 }, { path_a, "a1.bin", 4 }, { path_a, "a2.bin", 4 } };
                assert(rdp_bridge_send_local_files(&session, files, 3) == RDPBridgeStatusOK);
                after_leave(1, offer_b);
                request_descriptor();
                assert(serialized_count == 3 && data_responses == 1 && last_data_flags == CB_RESPONSE_OK);
                for (int i = 0; i < 3; i++) {
                    assert(serialized[i].cFileName[0] == 'a' && serialized[i].cFileName[1] == '0' + i && serialized[i].nFileSizeLow == 4);
                }
                assert(session.local_file_count == 1);
                return 0;
            }
            if (!strcmp(s, "cb6")) {
                // C-B6: 채널·호출자 각 1만 회 교차. 한 잠금으로 OK 가 나간 크기·내용은 모두 같은 제공(A 4바이트 또는
                // B 5바이트)의 것이어야 한다(INV-L8′). ThreadSanitizer 로 돈다.
                make_files();
                offer_a();
                pthread_t publisher;
                if (pthread_create(&publisher, NULL, cb6_publisher, NULL) != 0) return 3;
                size_t ok = 0, refused = 0;
                for (UINT32 i = 0; i < 10000; i++) {
                    const UINT32 id = 1 + i;
                    if (i % 1000 == 999) monitor_ready();
                    server_lock(id);
                    UINT32 bound = 0;
                    for (int k = 0; k < 3; k++) {
                        const bool size_request = (k == 0);
                        assert(file_request_lock(0, size_request ? FILECONTENTS_SIZE : FILECONTENTS_RANGE, 0, TRUE, id) == 1);
                        if (last_contents_flags != CB_RESPONSE_OK) { refused++; continue; }
                        ok++;
                        UINT32 which = 0;
                        if (size_request) {
                            UINT64 size = 0; memcpy(&size, last_contents, sizeof size);
                            assert(last_contents_size == 8);
                            which = (UINT32)size;
                        } else {
                            which = last_contents_size;
                            assert((which == 4 && !memcmp(last_contents, "AAAA", 4)) || (which == 5 && !memcmp(last_contents, "BBBBB", 5)));
                        }
                        assert(which == 4 || which == 5);
                        if (bound == 0) bound = which;
                        assert(which == bound);
                    }
                    server_unlock(id);
                }
                pthread_join(publisher, NULL);
                printf("cb6: ok=%zu refused=%zu\n", ok, refused);
                return 0;
            }
            if (!strcmp(s, "clrace")) {
                // 관문~큐 투입 경합(설계 clip-lock D-L3, E3): 한 스레드가 RANGE 를 쉬지 않고 보내는 동안 채널 스레드가
                // 파일 FL 과 서술자 응답을 되풀이한다. 와이어에서 RANGE 의 id 는 그 순간 보유 중인 단 하나의 잠금이어야 하고,
                // Unlock 된 id 를 단 RANGE 는 나오지 않아야 한다(INV-L1·L3·L4).
                server_caps(CB_STREAM_FILECLIP_ENABLED | CB_CAN_LOCK_CLIPDATA);
                deliver_files();
                pthread_t sender;
                if (pthread_create(&sender, NULL, race_sender, NULL) != 0) return 3;
                for (int i = 0; i < 2000; i++) { fl_files(); reply_descriptor(); }
                __atomic_store_n(&race_done, true, __ATOMIC_SEQ_CST);
                pthread_join(sender, NULL);
                UINT32 held = 0;
                size_t ranges = 0;
                for (size_t i = 0; i < wire_count; i++) {
                    const WireEvent *e = &wire[i];
                    if (e->kind == 'L') { assert(held == 0); held = e->value; }
                    if (e->kind == 'U') { assert(held == e->value); held = 0; }
                    if (e->kind == 'F') { assert(e->have && e->value == held && held != 0); ranges++; }
                }
                printf("clrace: wire=%zu ranges=%zu\n", wire_count, ranges);
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
        compiler.arguments = [cFile.path, "-pthread", "-o", executable.path] + extraFlags
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

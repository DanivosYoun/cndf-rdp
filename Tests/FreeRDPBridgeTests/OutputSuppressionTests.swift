import Foundation
import XCTest

final class OutputSuppressionTests: XCTestCase {
    // Compile the production suppression function with controlled GDI and update callbacks.
    // This exercises the return boundary without opening an RDP connection.
    func testUnsupportedServerNeverChangesLocalGDIAndResumeRefreshes() throws { try runFixture("baseline") }
    func testReleaseAfterSupportDisappears() throws { try runFixture("support-flip") }
    func testInputReleasesBeforeSendingAndMoveDoesNotRelease() throws { try runFixture("input") }

    private func runFixture(_ scenario: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FreeRDPBridge/FreeRDPBridge.c"), encoding: .utf8)
        let capabilityStart = try XCTUnwrap(source.range(of: "bool rdp_bridge_supports_output_suppression("))
        let function = String(source[capabilityStart.lowerBound...])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = """
        #include <stdint.h>
        #include <stdbool.h>
        #include <stddef.h>
        #include <string.h>
        #define RDP_FREERDP_REAL 1
        #define TRUE 1
        typedef uint16_t UINT16;
        #define FALSE 0
        #define FreeRDP_SuppressOutput 1
        #define FreeRDP_RefreshRect 2
        #define FreeRDP_DesktopWidth 3
        #define FreeRDP_DesktopHeight 4
        typedef struct { uint16_t left, top, right, bottom; } RECTANGLE_16;
        typedef enum {RDPBridgeStatusOK, RDPBridgeStatusInvalidArgument, RDPBridgeStatusNotConnected, RDPBridgeStatusBackendUnavailable, RDPBridgeStatusInternalError} RDPBridgeStatus;
        typedef struct { bool suppressOutput; } GDI;
        typedef struct Context Context;
        typedef Context rdpContext;
        typedef uint32_t UINT32;
        #define PTR_FLAGS_MOVE 1
        #define PTR_FLAGS_DOWN 2
        #define PTR_FLAGS_BUTTON1 4
        #define PTR_FLAGS_BUTTON2 8
        #define PTR_FLAGS_BUTTON3 16
        #define PTR_FLAGS_WHEEL 32
        #define PTR_FLAGS_HWHEEL 64
        #define PTR_FLAGS_WHEEL_NEGATIVE 128
        #define WheelRotationMask 511
        #define KBD_FLAGS_RELEASE 1
        typedef enum { RDPBridgePointerButtonLeft, RDPBridgePointerButtonRight, RDPBridgePointerButtonMiddle } RDPBridgePointerButton;
        typedef struct { int (*RefreshRect)(Context *, uint8_t, const RECTANGLE_16 *); } Update;
        struct Context { GDI *gdi; bool *settings; Update *update; void *input; };
        typedef struct { Context *context; } Instance;
        typedef struct { void (*outputResumedForInput)(void *); void *context; } Callbacks;
        typedef struct { bool connected; Instance *instance; Callbacks callbacks; } RDPBridgeSession;
        static int calls, refreshes, inputs, notifications, failed, failAllow, failRefresh;
        static GDI *activeGDI;
        static bool freerdp_settings_get_bool(bool *settings, int key) { return *settings; }
        static uint32_t freerdp_settings_get_uint32(bool *settings, int key) { return key == FreeRDP_DesktopWidth ? 640 : 480; }
        static int gdi_send_suppress_output(GDI *gdi, int value) { if (gdi->suppressOutput == value) return 1; ++calls; gdi->suppressOutput = value; return !failAllow; }
        static void bridge_logf(RDPBridgeSession *s, const char *format, ...) {}
        static int refresh(Context *c, uint8_t count, const RECTANGLE_16 *r) {
            if (c->gdi->suppressOutput || count != 1 || r->left || r->top || r->right != 639 || r->bottom != 479) return 0;
            ++refreshes; return !failRefresh;
        }
        static void resumed(void *ctx) { ++notifications; if (activeGDI->suppressOutput) failed = 1; }
        static int mouse(void *i, UINT16 flags, UINT16 x, UINT16 y) {
            if (flags != PTR_FLAGS_MOVE && (activeGDI->suppressOutput || !refreshes || !notifications)) failed = 1;
            ++inputs; return 1;
        }
        static int keyboard(void *i, int down, int repeat, uint32_t code) { return mouse(i, 0, 0, 0); }
        static int unicode(void *i, UINT16 flags, UINT16 code) { return mouse(i, 0, 0, 0); }
        #define freerdp_input_send_mouse_event mouse
        #define freerdp_input_send_keyboard_event_ex keyboard
        #define freerdp_input_send_unicode_keyboard_event unicode
        \(function)
        int main(void) {
            bool supported = false; GDI g = {false}; Update u = {refresh};
            Context c = {&g, &supported, &u, &g}; Instance i = {&c}; RDPBridgeSession s = {true, &i, {resumed, 0}};
            activeGDI = &g;
            if (strcmp("\(scenario)", "support-flip") == 0) {
                supported = true;
                rdp_bridge_set_output_suppressed(&s, true);
                supported = false;
                return rdp_bridge_set_output_suppressed(&s, false) != RDPBridgeStatusOK || g.suppressOutput;
            }
            if (strcmp("\(scenario)", "input") == 0) {
                supported = true;
                for (int n = 0; n < 5; ++n) {
                    rdp_bridge_set_output_suppressed(&s, true);
                    int before = calls;
                    rdp_bridge_set_output_suppressed(&s, true);
                    if (calls != before) return 10;
                    rdp_bridge_send_pointer_move(&s, 2, 3);
                    if (!g.suppressOutput || calls != before) return 11;
                    RDPBridgeStatus status;
                    switch (n) {
                        case 0: status = rdp_bridge_send_key(&s, 30, true); break;
                        case 1: status = rdp_bridge_send_key_ex(&s, 30, false, true); break;
                        case 2: status = rdp_bridge_send_unicode(&s, 65, true); break;
                        case 3: status = rdp_bridge_send_pointer_button(&s, 2, 3, RDPBridgePointerButtonLeft, true); break;
                        default: status = rdp_bridge_send_scroll_at(&s, 2, 3, -120, 120); break;
                    }
                    if (status || g.suppressOutput || failed || notifications != n + 1 || refreshes != n + 1) return 12;
                }
                rdp_bridge_set_output_suppressed(&s, true);
                int before = inputs;
                failAllow = 1;
                if (rdp_bridge_send_key(&s, 30, true) != RDPBridgeStatusInternalError || inputs != before || g.suppressOutput || notifications != 6) return 13;
                failAllow = 0; rdp_bridge_set_output_suppressed(&s, true); failRefresh = 1;
                if (rdp_bridge_send_unicode(&s, 65, true) != RDPBridgeStatusInternalError || inputs != before || g.suppressOutput || notifications != 7) return 14;
                return 0;
            }
            if (rdp_bridge_supports_output_suppression(&s)) return 4;
            if (rdp_bridge_set_output_suppressed(&s, true) != RDPBridgeStatusBackendUnavailable) return 5;
            if (calls || g.suppressOutput) return 1;
            supported = true;
            if (!rdp_bridge_supports_output_suppression(&s)) return 6;
            if (rdp_bridge_set_output_suppressed(&s, true) != RDPBridgeStatusOK || !g.suppressOutput) return 2;
            if (rdp_bridge_set_output_suppressed(&s, false) != RDPBridgeStatusOK || g.suppressOutput || refreshes != 1) return 3;
            return 0;
        }
        """
        let file = directory.appendingPathComponent("wheel.c")
        let executable = directory.appendingPathComponent("wheel")
        try fixture.write(to: file, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", "-fsanitize=undefined", "-fno-sanitize-recover=undefined", file.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        guard compiler.terminationStatus == 0 else { return }
        let test = Process()
        test.executableURL = executable
        try test.run()
        test.waitUntilExit()
        XCTAssertEqual(test.terminationStatus, 0)
    }
}

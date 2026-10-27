import Foundation
import XCTest

final class OutputSuppressionTests: XCTestCase {
    // Compile the production suppression function with controlled GDI and update callbacks.
    // This exercises the return boundary without opening an RDP connection.
    func testUnsupportedServerNeverChangesLocalGDIAndResumeRefreshes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FreeRDPBridge/FreeRDPBridge.c"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "RDPBridgeStatus rdp_bridge_set_output_suppressed("))
        let end = try XCTUnwrap(source.range(of: "\nRDPBridgeStatus rdp_bridge_send_pointer_move(", range: start.upperBound..<source.endIndex))
        let capabilityStart = try XCTUnwrap(source.range(of: "bool rdp_bridge_supports_output_suppression("))
        let function = String(source[capabilityStart.lowerBound..<end.lowerBound])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = """
        #include <stdint.h>
        #include <stdbool.h>
        #include <stddef.h>
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
        typedef struct { int (*RefreshRect)(Context *, uint8_t, const RECTANGLE_16 *); } Update;
        struct Context { GDI *gdi; bool *settings; Update *update; };
        typedef struct { Context *context; } Instance;
        typedef struct { bool connected; Instance *instance; } RDPBridgeSession;
        static int calls, refreshes;
        static bool freerdp_settings_get_bool(bool *settings, int key) { return *settings; }
        static uint32_t freerdp_settings_get_uint32(bool *settings, int key) { return key == FreeRDP_DesktopWidth ? 640 : 480; }
        static int gdi_send_suppress_output(GDI *gdi, int value) { ++calls; gdi->suppressOutput = value; return 1; }
        static void bridge_logf(RDPBridgeSession *s, const char *format, ...) {}
        static int refresh(Context *c, uint8_t count, const RECTANGLE_16 *r) {
            if (c->gdi->suppressOutput || count != 1 || r->left || r->top || r->right != 639 || r->bottom != 479) return 0;
            ++refreshes; return 1;
        }
        \(function)
        int main(void) {
            bool supported = false; GDI g = {false}; Update u = {refresh};
            Context c = {&g, &supported, &u}; Instance i = {&c}; RDPBridgeSession s = {true, &i};
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

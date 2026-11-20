import Foundation
import XCTest

final class ScrollSendResultTests: XCTestCase {
    func testBothWheelAxesPropagateSendFailure() throws {
        try compileAndRun(main: """
        int main(void) {
            Context c = {(void *)1}; Instance i = {&c}; RDPBridgeSession s = {true, &i};
            for (int failure = 0; failure <= 2; ++failure) {
                calls = 0; fail_at = failure;
                RDPBridgeStatus result = rdp_bridge_send_scroll_at(&s, 12, 34, -3, 4);
                if (result != (failure ? RDPBridgeStatusInternalError : RDPBridgeStatusOK)) return 1;
                if (calls != (failure ? failure : 2)) return 2;
            }
            calls = 0; fail_at = 1;
            if (rdp_bridge_send_scroll_at(&s, 12, 34, -3, 0) != RDPBridgeStatusInternalError) return 3;
            calls = 0; fail_at = 0;
            if (rdp_bridge_send_scroll_at(&s, 12, 34, INT32_MIN, INT32_MIN) != RDPBridgeStatusOK) return 4;
            return 0;
        }
        """)
    }

    // The wheel field is 9-bit two's complement (MS-RDPBCGR 2.2.8.1.1.3.1.1.3), the same bytes
    // IronRDP's MousePdu encoder writes (Rust/cndf-ironrdp/src/input.rs, same table). The old
    // |delta| | NEGATIVE encoding sent -1 as 0x0301, which Windows injects as -255.
    func testWheelDeltaEncodesAsNineBitTwosComplement() throws {
        try compileAndRun(main: """
        int main(void) {
            Context c = {(void *)1}; Instance i = {&c}; RDPBridgeSession s = {true, &i};
            static const struct { int32_t dy, dx; uint16_t first; } cases[] = {
                {-1, 0, 0x03FF}, {1, 0, 0x0201}, {-120, 0, 0x0388}, {120, 0, 0x0278},
                {-256, 0, 0x0300}, {255, 0, 0x02FF}, {-300, 0, 0x0300}, {300, 0, 0x02FF},
                {INT32_MIN, 0, 0x0300}, {INT32_MAX, 0, 0x02FF},
                {0, -1, 0x05FF}, {0, 120, 0x0478}, {0, -120, 0x0588},
            };
            for (size_t n = 0; n < sizeof(cases) / sizeof(cases[0]); ++n) {
                calls = 0; fail_at = 0;
                if (rdp_bridge_send_scroll_at(&s, 0, 0, cases[n].dx, cases[n].dy) != RDPBridgeStatusOK) return 10;
                if (calls != 1 || last_flags != cases[n].first) {
                    fprintf(stderr, "case %zu: dy=%d dx=%d flags=0x%04x expected 0x%04x\\n", n, cases[n].dy, cases[n].dx, last_flags, cases[n].first);
                    return (int)n + 20;
                }
            }
            return 0;
        }
        """)
    }

    // Compile the production wheel code with a controlled FreeRDP sender.
    // This exercises the return boundary without opening an RDP connection.
    private func compileAndRun(main: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FreeRDPBridge/FreeRDPBridge.c"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "#if defined(RDP_FREERDP_REAL)\n/* Wheel rotation field"))
        let end = try XCTUnwrap(source.range(of: "\nRDPBridgeStatus rdp_bridge_send_scroll(", range: start.upperBound..<source.endIndex))
        let function = String(source[start.lowerBound..<end.lowerBound])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = """
        #include <stdint.h>
        #include <stdbool.h>
        #include <stdlib.h>
        #include <stddef.h>
        #include <stdio.h>
        #define RDP_FREERDP_REAL 1
        #define PTR_FLAGS_WHEEL 0x200
        #define PTR_FLAGS_HWHEEL 0x400
        #define PTR_FLAGS_WHEEL_NEGATIVE 0x100
        #define WheelRotationMask 0x01FF
        #define UINT16 uint16_t
        typedef enum {RDPBridgeStatusOK, RDPBridgeStatusInvalidArgument, RDPBridgeStatusNotConnected, RDPBridgeStatusInternalError} RDPBridgeStatus;
        typedef struct { void *input; } Context;
        typedef struct { Context *context; } Instance;
        typedef struct { bool connected; Instance *instance; } RDPBridgeSession;
        static RDPBridgeStatus bridge_release_output_for_input(RDPBridgeSession *s) { return RDPBridgeStatusOK; }
        static int calls, fail_at;
        static uint16_t last_flags;
        static int freerdp_input_send_mouse_event(void *input, uint16_t flags, uint16_t x, uint16_t y) {
            last_flags = flags;
            return ++calls != fail_at;
        }
        \(function)
        \(main)
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

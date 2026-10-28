import Foundation
import XCTest

final class ScrollSendResultTests: XCTestCase {
    // Compile the production wheel function with a controlled FreeRDP sender.
    // This exercises the return boundary without opening an RDP connection.
    func testBothWheelAxesPropagateSendFailure() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FreeRDPBridge/FreeRDPBridge.c"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "RDPBridgeStatus rdp_bridge_send_scroll_at("))
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
        #define RDP_FREERDP_REAL 1
        #define PTR_FLAGS_WHEEL 0x200
        #define PTR_FLAGS_HWHEEL 0x400
        #define PTR_FLAGS_WHEEL_NEGATIVE 0x100
        #define WheelRotationMask 0xff
        #define UINT16 uint16_t
        typedef enum {RDPBridgeStatusOK, RDPBridgeStatusInvalidArgument, RDPBridgeStatusNotConnected, RDPBridgeStatusInternalError} RDPBridgeStatus;
        typedef struct { void *input; } Context;
        typedef struct { Context *context; } Instance;
        typedef struct { bool connected; Instance *instance; } RDPBridgeSession;
        static RDPBridgeStatus bridge_release_output_for_input(RDPBridgeSession *s) { return RDPBridgeStatusOK; }
        static int calls, fail_at;
        static int freerdp_input_send_mouse_event(void *input, uint16_t flags, uint16_t x, uint16_t y) {
            return ++calls != fail_at;
        }
        \(function)
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

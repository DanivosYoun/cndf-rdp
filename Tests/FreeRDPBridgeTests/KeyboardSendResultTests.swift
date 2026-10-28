import Foundation
import XCTest

final class KeyboardSendResultTests: XCTestCase {
    func testExtendedBitIsEncodedInScancodeAndSendFailureIsReturned() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FreeRDPBridge/FreeRDPBridge.c"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "RDPBridgeStatus rdp_bridge_send_key_ex("))
        let end = try XCTUnwrap(source.range(of: "\nRDPBridgeStatus rdp_bridge_send_key(", range: start.upperBound..<source.endIndex))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = """
        #include <stdint.h>
        #include <stdbool.h>
        #include <stddef.h>
        #define RDP_FREERDP_REAL 1
        #define TRUE 1
        #define FALSE 0
        typedef enum {RDPBridgeStatusOK, RDPBridgeStatusInvalidArgument, RDPBridgeStatusNotConnected, RDPBridgeStatusInternalError} RDPBridgeStatus;
        typedef struct { void *input; } Context;
        typedef struct { Context *context; } Instance;
        typedef struct { bool connected; Instance *instance; } RDPBridgeSession;
        static RDPBridgeStatus bridge_release_output_for_input(RDPBridgeSession *s) { return RDPBridgeStatusOK; }
        static int last_down, last_repeat, success = 1;
        static uint32_t last_code;
        static int freerdp_input_send_keyboard_event_ex(void *input, int down, int repeat, uint32_t code) {
            last_down = down; last_repeat = repeat; last_code = code; return success;
        }
        \(source[start.lowerBound..<end.lowerBound])
        int main(void) {
            Context c = {(void *)1}; Instance i = {&c}; RDPBridgeSession s = {true, &i};
            if (rdp_bridge_send_key_ex(&s, 0x53, true, true) != RDPBridgeStatusOK) return 1;
            if (last_code != 0x153 || last_repeat != 0 || last_down != 1) return 2;
            if (rdp_bridge_send_key_ex(&s, 0x53, false, true) != RDPBridgeStatusOK) return 3;
            if (last_code != 0x153 || last_down != 0) return 4;
            if (rdp_bridge_send_key_ex(&s, 0x153, true, false) != RDPBridgeStatusOK || last_code != 0x153) return 5;
            success = 0;
            if (rdp_bridge_send_key_ex(&s, 0x53, true, false) != RDPBridgeStatusInternalError) return 6;
            return 0;
        }
        """
        let file = directory.appendingPathComponent("keyboard.c")
        let executable = directory.appendingPathComponent("keyboard")
        try fixture.write(to: file, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", file.path, "-o", executable.path]
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

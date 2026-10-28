import Foundation
import XCTest

final class NetworkAutoDetectLogTests: XCTestCase {
    func testInitialValuesAndMissingBandwidthAreExplicit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FreeRDPBridge/FreeRDPBridge.c"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static BOOL bridge_network_characteristics_result("))
        let end = try XCTUnwrap(source.range(of: "\nstatic BOOL bridge_pre_connect(", range: start.upperBound..<source.endIndex))
        let summaryStart = try XCTUnwrap(source.range(of: "    if (session->netchar_result_count > 0) {"))
        let summaryEnd = try XCTUnwrap(source.range(of: #"    bridge_log(session, "FreeRDP disconnected.");"#, range: summaryStart.upperBound..<source.endIndex))
        let fixture = """
        #include <stdbool.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdarg.h>
        #include <string.h>
        typedef int BOOL;
        typedef uint16_t UINT16;
        typedef int RDP_TRANSPORT_TYPE;
        #define TRUE 1
        #define RDP_NETCHAR_RESULT_TYPE_BASE_RTT_AVG_RTT 0x0840
        #define RDP_NETCHAR_RESULT_TYPE_BW_AVG_RTT 0x0880
        #define RDP_NETCHAR_RESULT_TYPE_BASE_RTT_BW_AVG_RTT 0x08c0
        typedef struct { bool hasBaseRTT, hasBandwidth; uint32_t baseRTTMs, averageRTTMs, bandwidthKbps; } RDPBridgeNetworkCharacteristics;
        typedef struct { uint16_t type; uint32_t baseRTT, averageRTT, bandwidth; } rdpNetworkCharacteristicsResult;
        typedef struct { RDPBridgeNetworkCharacteristics last_netchar; unsigned netchar_result_count;
            struct { void (*networkCharacteristics)(const RDPBridgeNetworkCharacteristics *, void *); void *context; } callbacks;
        } RDPBridgeSession;
        typedef struct { void *context; } rdpAutoDetect;
        static char message[2048];
        static RDPBridgeSession *session_from_context(void *ctx) { return ctx; }
        static void bridge_logf(RDPBridgeSession *s, const char *format, ...) {
            va_list ap; va_start(ap, format); vsnprintf(message, sizeof(message), format, ap); va_end(ap);
        }
        \(source[start.lowerBound..<end.lowerBound])
        static void summary(RDPBridgeSession *session) {
        \(source[summaryStart.lowerBound..<summaryEnd.lowerBound])
        }
        int main(void) {
            RDPBridgeSession session = {0}; rdpAutoDetect a = {&session};
            rdpNetworkCharacteristicsResult r = {0x08c0, 400, 400, 512};
            bridge_network_characteristics_result(&a, 0, 0, &r);
            if (!strstr(message, "initial server values") || !strstr(message, "may be defaults")) return 1;
            r.type = 0x0840; r.bandwidth = 0;
            bridge_network_characteristics_result(&a, 0, 1, &r); summary(&session);
            if (!strstr(message, "bandwidthPresent=no") || !strstr(message, "no bandwidth")) return 2;
            r.type = 0x08c0;
            bridge_network_characteristics_result(&a, 0, 2, &r); summary(&session);
            if (!strstr(message, "bandwidthPresent=yes") || !strstr(message, "not a measured zero-throughput link")) return 3;
            return 0;
        }
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("netchar.c")
        let executable = directory.appendingPathComponent("netchar")
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

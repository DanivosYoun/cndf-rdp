import Darwin
import Foundation

/// Process CPU time (user + system) in milliseconds.
func processCPUMilliseconds() -> (user: Double, system: Double) {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func ms(_ value: timeval) -> Double {
        Double(value.tv_sec) * 1000 + Double(value.tv_usec) / 1000
    }
    return (ms(usage.ru_utime), ms(usage.ru_stime))
}

/// `phys_footprint` of this process in bytes (what Activity Monitor calls "Memory").
func physFootprintBytes() -> UInt64 {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? info.ri_phys_footprint : 0
}

/// Samples phys_footprint once per second while a run is active.
final class FootprintSampler {
    private var timer: Timer?
    private(set) var samples: [UInt64] = []

    func start() {
        samples = [physFootprintBytes()]
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.samples.append(physFootprintBytes())
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        samples.append(physFootprintBytes())
    }

    var maxBytes: UInt64 { samples.max() ?? 0 }
    var averageBytes: UInt64 {
        samples.isEmpty ? 0 : samples.reduce(0, +) / UInt64(samples.count)
    }
}

/// Nearest-rank percentile; nil for an empty list.
func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
}

struct DistributionSummary: Encodable {
    var count: Int
    var p50: Double?
    var p95: Double?
    var min: Double?
    var max: Double?

    init(_ values: [Double]) {
        count = values.count
        p50 = percentile(values, 50)
        p95 = percentile(values, 95)
        min = values.min()
        max = values.max()
    }
}

/// Metrics of one iteration of one run.
struct IterationResult: Encodable {
    var iteration: Int
    var connected = false
    var connectToConnectedMs: Double?
    var firstFrameMs: Double?
    var firstFrameSize: [Int]?
    var trustCallbacks: [String] = []
    /// SHA-256 of each certificate inside each trust string (see HarnessDelegate).
    var trustStringCertificates: [[String]] = []
    /// SHA-256 of each raw trust string (see HarnessDelegate).
    var trustStringDigests: [String] = []
    var prompts = 0
    var failure: String?
    var failureDetail: String?
    var disconnectReason: String?
    var disconnectBeforeShutdown: String?
    /// Not-connected -> connected rises in this iteration; more than one = reconnected.
    var connectRises = 0
    /// After the resize step: still connected with no disconnect, and the last remote frame
    /// size seen during the step (nil = no frame arrived).
    var connectedAfterResize: Bool?
    var displayControlReady: Bool?
    var resizeFrameSize: [Int]?
    var requestedResizeFrameSize: [Int]?
    /// Final resize frame size check outcome: "pass", "fail", or "N/A".
    var resizeFrameSizeCheck: String?
    var shutdownMs: Double?
    var shutdownDiagnostics: [String: Int]?
    /// Delegate callbacks delivered after `shutdown()` returned (must be 0).
    var callbacksAfterShutdown = 0
    var cpuUserMs: Double = 0
    var cpuSystemMs: Double = 0
    var physFootprintMaxBytes: UInt64 = 0
    var physFootprintAvgBytes: UInt64 = 0
    var framesReceived: UInt64?
    var frameBytesReceived: UInt64?
    var audioWavesReceived: UInt64?
    /// Frames shown on main while a frame tap was attached.
    var framesDisplayedWithTap = 0
    /// Bytes copied into tap CVPixelBuffers (the share-path copy point).
    var tapPixelBufferBytes: UInt64 = 0
    var inputLatencyMs: DistributionSummary?
    var inputLatencyTimeouts = 0
    var durationMs: Double = 0
    /// The session log was checked for the password string (M1 condition 5 style check).
    var passwordFoundInSessionLog: Bool?
    var steps: [String] = []
    /// One line per resize step: requested and last seen remote frame size, still connected.
    var resizeLog: [String] = []
    /// clipboardExpectLocalFiles: name, byte count and SHA-256 of each pasteboard file URL
    /// (directories are listed with their entry count instead).
    var localFiles: [[String: String]] = []
    /// clipboardWaitLocalPrefix: the pasteboard text that matched.
    var localTexts: [String] = []
    /// cpuWindow steps (M4 acceptance), in order.
    var cpuWindows: [CPUWindowResult] = []
    /// dumpFrame step (M4 acceptance): the last frame written to the work directory.
    var finalFrame: FinalFrameResult?
}

/// Client CPU over one cpuWindow step. getrusage(RUSAGE_SELF): the same user + system time
/// proc_pid_rusage reports for this process.
struct CPUWindowResult: Encodable {
    var seconds: Double
    var userMs: Double
    var systemMs: Double
    var framesReceived: UInt64
}

struct FinalFrameResult: Encodable {
    /// PPM file name inside the work directory.
    var file: String
    var size: [Int]
    var sha256: String
}

struct RunResult: Encodable {
    var id: String
    var engine: String
    var host: String
    var port: UInt16
    var iterations: [IterationResult]
    var firstFrameMs: DistributionSummary
    var connectToConnectedMs: DistributionSummary
    var shutdownMs: DistributionSummary
    var passed: Bool
    var expectationFailures: [String]
}

struct ScenarioResult: Encodable {
    var schema = "cndf-engine-harness/v0"
    var scenario: String
    var engine: String
    var startedAt: String
    var finishedAt: String
    var host: [String: String]
    var runs: [RunResult]
    var passed: Bool
}

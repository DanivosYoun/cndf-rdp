import Foundation

/// A harness scenario file: one or more runs executed in order inside one process, sharing
/// one certificate trust store (so "new -> same -> changed -> rejected" can be chained).
struct HarnessScenario: Decodable {
    var name: String
    /// Default engine for runs without their own: `freerdp` or `ironrdp` (`--engine` overrides).
    var engine: String?
    var runs: [HarnessRun]
}

struct HarnessRun: Decodable {
    var id: String
    var host: String
    var port: UInt16
    var username: String?
    /// Name of the environment variable holding the password (never put secrets in JSON).
    var passwordEnv: String?
    var domain: String?
    /// "auto" or "compat" (RDPGraphicsMode raw values).
    var graphicsMode: String?
    /// RDPConnectionOptions.networkAutoDetect (app default false). Default false.
    var networkAutoDetect: Bool?
    /// Window content size in points.
    var window: HarnessSize?
    /// Repeat the whole step list this many times (fresh window/view each time). Default 1.
    var repeatCount: Int?
    /// Answer to a "certificate changed" prompt: "approve" or "deny". Default "deny".
    var promptAnswer: String?
    var steps: [HarnessStep]
    var expect: HarnessExpectation?
    /// Engine for this run only (overrides `--engine`); lets one scenario mix engines.
    var engine: String?
    /// Replaces `expect` when this run uses the keyed engine. IronRDP has no known_hosts of
    /// its own, so a stored certificate reaches the app as a "same" callback instead of none.
    var expectByEngine: [String: HarnessExpectation]?

    enum CodingKeys: String, CodingKey {
        case id, host, port, username, passwordEnv, domain, graphicsMode, networkAutoDetect, window, steps, expect
        case engine, expectByEngine
        case promptAnswer
        case repeatCount = "repeat"
    }
}

struct HarnessSize: Decodable {
    var width: Double
    var height: Double
}

struct HarnessStep: Decodable {
    /// connect | waitConnected | waitFirstFrame | idle | inputLatency | resize | tap | shutdown
    var op: String
    var timeout: Double?
    var seconds: Double?
    var width: Double?
    var height: Double?
    /// inputLatency: number of key presses to time.
    var samples: Int?
    /// inputLatency: remote pixel whose colour the probe app changes on each key press.
    var probeX: Int?
    var probeY: Int?
    /// inputLatency: scan code to press (default 0x1E, "A").
    var scanCode: UInt16?
}

struct HarnessExpectation: Decodable {
    var connected: Bool?
    var firstFrame: Bool?
    /// Exact sequence of trust callback classifications, e.g. ["new"] or [] or ["changed"].
    var trustCallbacks: [String]?
    /// Number of "certificate changed" prompts the user would have seen.
    var prompts: Int?
    /// Expected failure case name (e.g. "certificateRejected"); nil = no failure expected.
    var failure: String?
    /// Upper bound for view.shutdown() wall time.
    var maxShutdownMs: Int?
}

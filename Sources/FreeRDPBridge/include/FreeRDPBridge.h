#ifndef RDP_FREERDP_BRIDGE_H
#define RDP_FREERDP_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RDPBridgeSession RDPBridgeSession;

typedef enum RDPBridgeStatus {
    RDPBridgeStatusOK = 0,
    RDPBridgeStatusInvalidArgument = 1,
    RDPBridgeStatusNotConnected = 2,
    RDPBridgeStatusBackendUnavailable = 3,
    RDPBridgeStatusInternalError = 4
} RDPBridgeStatus;

typedef enum RDPBridgeClipboardDirection {
    RDPBridgeClipboardDirectionLocalToRemote = 0,
    RDPBridgeClipboardDirectionRemoteToLocal = 1
} RDPBridgeClipboardDirection;

typedef enum RDPBridgePointerButton {
    RDPBridgePointerButtonLeft = 0,
    RDPBridgePointerButtonRight = 1,
    RDPBridgePointerButtonMiddle = 2
} RDPBridgePointerButton;

typedef enum RDPBridgeAudioPlaybackMode {
    RDPBridgeAudioPlaybackDisabled = 0,
    RDPBridgeAudioPlaybackLocal = 1,
    RDPBridgeAudioPlaybackRemote = 2
} RDPBridgeAudioPlaybackMode;

typedef enum RDPBridgeFailureKind {
    RDPBridgeFailureNetwork = 0,
    RDPBridgeFailureTLS = 1,
    RDPBridgeFailureAuthentication = 2,
    RDPBridgeFailureCertificate = 3,
    RDPBridgeFailureConfiguration = 4,
    RDPBridgeFailureFreeRDP = 5
} RDPBridgeFailureKind;

typedef enum RDPBridgeDisconnectKind {
    RDPBridgeDisconnectLocalRequest = 0,
    RDPBridgeDisconnectServer = 1,
    RDPBridgeDisconnectTimeout = 2,
    RDPBridgeDisconnectError = 3
} RDPBridgeDisconnectKind;

typedef void (*RDPBridgeLogCallback)(const char *message, void *context);
typedef bool (*RDPBridgeCertificateTrustCallback)(
    const char *fingerprint,
    const char *hostname,
    uint16_t port,
    void *context);
typedef void (*RDPBridgeFailureCallback)(
    RDPBridgeFailureKind kind,
    uint32_t code,
    const char *description,
    void *context);
typedef void (*RDPBridgeDisconnectCallback)(
    RDPBridgeDisconnectKind kind,
    uint32_t code,
    void *context);
typedef void (*RDPBridgeRemoteTextCallback)(const uint8_t *utf8, size_t length, void *context);
typedef void (*RDPBridgeRemoteFileListCallback)(const uint8_t *payload, size_t length, void *context);
typedef void (*RDPBridgeRemoteFileContentsCallback)(
    uint32_t streamId,
    const uint8_t *payload,
    size_t length,
    void *context);
typedef void (*RDPBridgeFrameCallback)(
    const uint8_t *bgra,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    void *context);

// A Network Characteristics Result the server sent after network auto-detection.
typedef struct RDPBridgeNetworkCharacteristics {
    bool hasBaseRTT;
    bool hasBandwidth;
    uint32_t baseRTTMs;
    uint32_t averageRTTMs;
    uint32_t bandwidthKbps;
} RDPBridgeNetworkCharacteristics;

typedef enum RDPBridgePointerKind {
    RDPBridgePointerKindImage = 0,
    RDPBridgePointerKindHidden = 1,
    RDPBridgePointerKindDefault = 2
} RDPBridgePointerKind;

// Server pointer shape. For Image, `bgra` is top-down BGRA with straight (not
// premultiplied) alpha and is only valid during the call; otherwise it is NULL.
typedef void (*RDPBridgePointerCallback)(
    RDPBridgePointerKind kind,
    const uint8_t *bgra,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    uint32_t hotX,
    uint32_t hotY,
    void *context);

typedef void (*RDPBridgeNetworkCharacteristicsCallback)(
    const RDPBridgeNetworkCharacteristics *result,
    void *context);

typedef struct RDPBridgeCallbacks {
    RDPBridgeLogCallback log;
    RDPBridgeCertificateTrustCallback certificateTrust;
    RDPBridgeFailureCallback failure;
    RDPBridgeDisconnectCallback disconnect;
    RDPBridgeRemoteTextCallback remoteText;
    RDPBridgeRemoteFileListCallback remoteFileList;
    RDPBridgeRemoteFileContentsCallback remoteFileContents;
    RDPBridgeFrameCallback frame;
    RDPBridgeNetworkCharacteristicsCallback networkCharacteristics;
    RDPBridgePointerCallback pointer;
    void *context;
} RDPBridgeCallbacks;

typedef struct RDPBridgeConnectionOptions {
    const char *host;
    uint16_t port;
    const char *username;
    const char *password;
    const char *domain;
    bool enableClipboard;
    bool enableDriveRedirection;
    const char *redirectedFolderPath;
    const char *redirectedFolderName;
    RDPBridgeAudioPlaybackMode audioPlaybackMode;
    const char *logLevel;
    const char *logFilters;
    uint32_t colorDepth;
    uint32_t desktopWidth;
    uint32_t desktopHeight;
    double desktopScale;
    // Advertise RNS_UD_CS_SUPPORT_NETCHAR_AUTODETECT so the server can measure RTT and
    // bandwidth. Leaves ConnectionType, perf flags, Heartbeat and Multitransport alone.
    bool networkAutoDetect;
} RDPBridgeConnectionOptions;

typedef struct RDPBridgeLocalFile {
    const char *path;
    const char *fileName;
    uint64_t size;
} RDPBridgeLocalFile;

// Connect-time TLS profile ladder. A connect that fails at the TLS stage is
// retried once per step, in order, so no host connects with a weaker profile
// than the earliest one it accepts.
typedef enum RDPBridgeTLSStage {
    // FreeRDP defaults (3.27+: TLS >= 1.2, SECLEVEL 2).
    RDPBridgeTLSStageDefault = 0,
    // FreeRDP 3.26 defaults: TLS >= 1.0, SECLEVEL 1.
    RDPBridgeTLSStagePrevious = 1,
    // Legacy-compatible: TLS 1.0-1.2, SECLEVEL 0, DEFAULT@SECLEVEL=0 ciphers.
    RDPBridgeTLSStageLegacy = 2
} RDPBridgeTLSStage;

typedef struct RDPBridgeTLSSettings {
    uint16_t minVersion;
    uint16_t maxVersion;
    uint32_t secLevel;
    char allowedCiphers[64];
} RDPBridgeTLSSettings;

// Reports the TLS settings a fresh client instance ends up with at `stage`.
// Exposed so the ladder can be pinned by unit tests.
bool rdp_bridge_tls_settings_for_stage(RDPBridgeTLSStage stage, RDPBridgeTLSSettings *out);

// Converts RDP pointer XOR/AND masks to what the pointer callback delivers (top-down,
// straight-alpha BGRA, stride width * 4). `bgra` must hold width * height * 4 bytes.
// 8bpp masks need the session palette and are rejected here. Exposed for unit tests.
bool rdp_bridge_pointer_to_bgra(
    uint32_t width,
    uint32_t height,
    uint32_t xorBpp,
    const uint8_t *xorMask,
    uint32_t xorMaskLength,
    const uint8_t *andMask,
    uint32_t andMaskLength,
    uint8_t *bgra);

// "<version> (<revision>)" of the FreeRDP library actually loaded at runtime.
const char *rdp_bridge_freerdp_version(void);

RDPBridgeSession *rdp_bridge_session_create(const RDPBridgeCallbacks *callbacks);
void rdp_bridge_session_destroy(RDPBridgeSession *session);

RDPBridgeStatus rdp_bridge_connect(RDPBridgeSession *session, const RDPBridgeConnectionOptions *options);
RDPBridgeStatus rdp_bridge_disconnect(RDPBridgeSession *session);
bool rdp_bridge_is_connected(const RDPBridgeSession *session);

RDPBridgeStatus rdp_bridge_send_local_text(RDPBridgeSession *session, const uint8_t *utf8, size_t length);
RDPBridgeStatus rdp_bridge_send_local_file_list(RDPBridgeSession *session, const uint8_t *payload, size_t length);
RDPBridgeStatus rdp_bridge_send_local_files(
    RDPBridgeSession *session,
    const RDPBridgeLocalFile *files,
    size_t count);
RDPBridgeStatus rdp_bridge_request_remote_file_contents(
    RDPBridgeSession *session,
    uint32_t stream_id,
    uint64_t offset,
    uint32_t length);
RDPBridgeStatus rdp_bridge_request_remote_file_range(
    RDPBridgeSession *session,
    uint32_t stream_id,
    uint32_t list_index,
    uint64_t offset,
    uint32_t length);
RDPBridgeStatus rdp_bridge_update_desktop_size(RDPBridgeSession *session, uint32_t width, uint32_t height, double scale);
// Sends Suppress Output (suppressed) or Allow Display Updates (!suppressed). A no-op
// when the server did not advertise support. Call from the caller's thread.
bool rdp_bridge_supports_output_suppression(RDPBridgeSession *session);
RDPBridgeStatus rdp_bridge_set_output_suppressed(RDPBridgeSession *session, bool suppressed);
RDPBridgeStatus rdp_bridge_send_pointer_move(RDPBridgeSession *session, uint32_t x, uint32_t y);
RDPBridgeStatus rdp_bridge_send_pointer_button(
    RDPBridgeSession *session,
    uint32_t x,
    uint32_t y,
    RDPBridgePointerButton button,
    bool pressed);
RDPBridgeStatus rdp_bridge_send_scroll(RDPBridgeSession *session, int32_t delta_x, int32_t delta_y);
RDPBridgeStatus rdp_bridge_send_scroll_at(
    RDPBridgeSession *session,
    uint32_t x,
    uint32_t y,
    int32_t delta_x,
    int32_t delta_y);
RDPBridgeStatus rdp_bridge_send_key(RDPBridgeSession *session, uint16_t key_code, bool pressed);
RDPBridgeStatus rdp_bridge_send_key_ex(
    RDPBridgeSession *session,
    uint16_t key_code,
    bool pressed,
    bool extended);
RDPBridgeStatus rdp_bridge_send_unicode(RDPBridgeSession *session, uint16_t code, bool pressed);

#ifdef __cplusplus
}
#endif

#endif

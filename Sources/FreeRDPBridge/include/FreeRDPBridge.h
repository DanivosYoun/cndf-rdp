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

typedef struct RDPBridgeCallbacks {
    RDPBridgeLogCallback log;
    RDPBridgeCertificateTrustCallback certificateTrust;
    RDPBridgeFailureCallback failure;
    RDPBridgeDisconnectCallback disconnect;
    RDPBridgeRemoteTextCallback remoteText;
    RDPBridgeRemoteFileListCallback remoteFileList;
    RDPBridgeRemoteFileContentsCallback remoteFileContents;
    RDPBridgeFrameCallback frame;
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
} RDPBridgeConnectionOptions;

typedef struct RDPBridgeLocalFile {
    const char *path;
    const char *fileName;
    uint64_t size;
} RDPBridgeLocalFile;

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

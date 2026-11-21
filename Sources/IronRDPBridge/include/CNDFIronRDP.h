#ifndef CNDF_IRONRDP_H
#define CNDF_IRONRDP_H

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#define CNDF_IRON_ABI_VERSION 1

#define CNDF_IRON_CAP_CLIPBOARD 1

#define CNDF_IRON_CAP_DRIVE 2

#define CNDF_IRON_CAP_AUDIO_LOCAL 4

#define CNDF_IRON_CAP_AUDIO_REMOTE 8

#define CNDF_IRON_CERT_CHAIN_UNTRUSTED 1

#define CNDF_IRON_CERT_NAME_MISMATCH 2

#define CNDF_IRON_CERT_EXPIRED 4

#define CNDF_IRON_CERT_OTHER 8

typedef enum CNDFIronLogLevel {
  CNDF_IRON_LOG_TRACE = 0,
  CNDF_IRON_LOG_DEBUG = 1,
  CNDF_IRON_LOG_INFO = 2,
  CNDF_IRON_LOG_WARN = 3,
  CNDF_IRON_LOG_ERROR = 4,
  CNDF_IRON_LOG_FATAL = 5,
  CNDF_IRON_LOG_OFF = 6,
} CNDFIronLogLevel;

typedef enum CNDFIronFailureKind {
  CNDF_IRON_FAILURE_NETWORK = 0,
  CNDF_IRON_FAILURE_TLS = 1,
  CNDF_IRON_FAILURE_AUTHENTICATION = 2,
  CNDF_IRON_FAILURE_CERTIFICATE = 3,
  CNDF_IRON_FAILURE_CONFIGURATION = 4,
  CNDF_IRON_FAILURE_ENGINE = 5,
} CNDFIronFailureKind;

typedef enum CNDFIronStage {
  CNDF_IRON_STAGE_UNKNOWN = 0,
  CNDF_IRON_STAGE_INITIAL = 1,
  CNDF_IRON_STAGE_NEGOTIATION = 2,
  CNDF_IRON_STAGE_AUTHENTICATION = 3,
  CNDF_IRON_STAGE_CHANNEL_SETUP = 4,
  CNDF_IRON_STAGE_LICENSING = 5,
  CNDF_IRON_STAGE_CAPABILITIES = 6,
  CNDF_IRON_STAGE_FINALIZATION = 7,
  CNDF_IRON_STAGE_ACTIVE = 8,
} CNDFIronStage;

typedef enum CNDFIronDisconnectKind {
  CNDF_IRON_DISCONNECT_LOCAL_REQUEST = 0,
  CNDF_IRON_DISCONNECT_SERVER = 1,
  CNDF_IRON_DISCONNECT_TIMEOUT = 2,
  CNDF_IRON_DISCONNECT_ERROR = 3,
} CNDFIronDisconnectKind;

typedef enum CNDFIronPointerKind {
  CNDF_IRON_POINTER_IMAGE = 0,
  CNDF_IRON_POINTER_HIDDEN = 1,
  CNDF_IRON_POINTER_DEFAULT = 2,
} CNDFIronPointerKind;

typedef enum CNDFIronStatus {
  CNDF_IRON_OK = 0,
  CNDF_IRON_INVALID_ARGUMENT = 1,
  CNDF_IRON_NOT_CONNECTED = 2,
  CNDF_IRON_BUSY = 3,
  CNDF_IRON_CLOSED = 4,
  CNDF_IRON_INTERNAL = 5,
} CNDFIronStatus;

typedef enum CNDFIronAudioMode {
  CNDF_IRON_AUDIO_OFF = 0,
  CNDF_IRON_AUDIO_LOCAL = 1,
  CNDF_IRON_AUDIO_REMOTE = 2,
} CNDFIronAudioMode;

typedef enum CNDFIronInputKind {
  CNDF_IRON_INPUT_KEY = 0,
  CNDF_IRON_INPUT_UNICODE = 1,
  CNDF_IRON_INPUT_POINTER_MOVE = 2,
  CNDF_IRON_INPUT_POINTER_BUTTON = 3,
  CNDF_IRON_INPUT_WHEEL = 4,
} CNDFIronInputKind;

typedef enum CNDFIronPointerButton {
  CNDF_IRON_BUTTON_LEFT = 0,
  CNDF_IRON_BUTTON_RIGHT = 1,
  CNDF_IRON_BUTTON_MIDDLE = 2,
} CNDFIronPointerButton;

typedef struct CNDFIronSession CNDFIronSession;

/**
 * Pointers supplied to callbacks are valid for the duration of the callback.
 */
typedef void (*CNDFIronLogCallback)(uint64_t generation,
                                    enum CNDFIronLogLevel level,
                                    const uint8_t *utf8,
                                    size_t length,
                                    void *context);

typedef struct CNDFIronCertificateChain {
  /**
   * Leaf first, followed by the intermediates in server order.
   */
  const uint8_t *const *der;
  const size_t *der_length;
  size_t count;
  const char *hostname;
  uint16_t port;
  uint32_t problems;
} CNDFIronCertificateChain;

/**
 * Runs synchronously on the session thread. Returning true accepts this handshake.
 */
typedef bool (*CNDFIronCertificateTrustCallback)(uint64_t generation,
                                                 const struct CNDFIronCertificateChain *chain,
                                                 void *context);

typedef void (*CNDFIronConnectedCallback)(uint64_t generation, void *context);

typedef void (*CNDFIronFailureCallback)(uint64_t generation,
                                        enum CNDFIronFailureKind kind,
                                        uint32_t code,
                                        enum CNDFIronStage stage,
                                        const uint8_t *utf8,
                                        size_t length,
                                        void *context);

typedef void (*CNDFIronDisconnectCallback)(uint64_t generation,
                                           enum CNDFIronDisconnectKind kind,
                                           uint32_t code,
                                           void *context);

typedef struct CNDFIronRect {
  uint32_t x;
  uint32_t y;
  uint32_t width;
  uint32_t height;
} CNDFIronRect;

/**
 * Borrows the full BGRA framebuffer (alpha 255). Dirty is the union for the batch.
 */
typedef void (*CNDFIronFrameCallback)(uint64_t generation,
                                      const uint8_t *bgra,
                                      uint32_t width,
                                      uint32_t height,
                                      uint32_t stride,
                                      struct CNDFIronRect dirty,
                                      uint64_t sequence,
                                      void *context);

/**
 * IMAGE supplies top-down straight-alpha BGRA with width * 4 stride.
 */
typedef void (*CNDFIronPointerCallback)(uint64_t generation,
                                        enum CNDFIronPointerKind kind,
                                        const uint8_t *bgra,
                                        uint32_t width,
                                        uint32_t height,
                                        uint32_t stride,
                                        uint32_t hot_x,
                                        uint32_t hot_y,
                                        void *context);

/**
 * Clipboard callbacks run on the clip thread. Copy borrowed data before returning.
 */
typedef void (*CNDFIronRemoteTextCallback)(uint64_t generation,
                                           const uint8_t *utf8,
                                           size_t length,
                                           void *context);

typedef struct CNDFIronRemoteFile {
  const uint8_t *name_utf8;
  size_t name_length;
  uint64_t size;
} CNDFIronRemoteFile;

typedef void (*CNDFIronRemoteFileListCallback)(uint64_t generation,
                                               const struct CNDFIronRemoteFile *files,
                                               size_t count,
                                               void *context);

/**
 * On failure, bytes is NULL and length is zero.
 */
typedef void (*CNDFIronRemoteFileContentsCallback)(uint64_t generation,
                                                   uint32_t stream_id,
                                                   bool ok,
                                                   const uint8_t *bytes,
                                                   size_t length,
                                                   void *context);

typedef struct CNDFIronCallbacks {
  CNDFIronLogCallback log;
  CNDFIronCertificateTrustCallback certificate_trust;
  CNDFIronConnectedCallback connected;
  CNDFIronFailureCallback failure;
  CNDFIronDisconnectCallback disconnect;
  CNDFIronFrameCallback frame;
  CNDFIronPointerCallback pointer;
  CNDFIronRemoteTextCallback remote_text;
  CNDFIronRemoteFileListCallback remote_file_list;
  CNDFIronRemoteFileContentsCallback remote_file_contents;
  void *context;
} CNDFIronCallbacks;

typedef struct CNDFIronConnectOptions {
  uint32_t struct_size;
  const char *host;
  uint16_t port;
  const char *username;
  const char *domain;
  uint32_t desktop_width;
  uint32_t desktop_height;
  uint32_t scale_percent;
  uint32_t color_depth;
  bool graphics_pipeline;
  enum CNDFIronLogLevel log_level;
  /**
   * The v1 options default to disabled when struct_size does not cover them all.
   */
  bool clipboard;
  /**
   * NULL disables drive sharing. A non-directory path is rejected.
   */
  const char *drive_path;
  /**
   * NULL selects "RemoteShare".
   */
  const char *drive_name;
  enum CNDFIronAudioMode audio_mode;
} CNDFIronConnectOptions;

typedef struct CNDFIronInputEvent {
  enum CNDFIronInputKind kind;
  uint16_t code;
  bool extended;
  bool pressed;
  enum CNDFIronPointerButton button;
  uint32_t x;
  uint32_t y;
  int32_t delta_x;
  int32_t delta_y;
} CNDFIronInputEvent;

typedef struct CNDFIronStatistics {
  uint64_t updates_received;
  uint64_t dirty_bytes_composed;
  uint64_t frames_delivered;
  uint64_t frame_bytes_delivered;
  uint64_t input_events_sent;
  uint64_t input_busy;
  uint64_t audio_waves_received;
  uint64_t drive_io_requests;
} CNDFIronStatistics;

typedef struct CNDFIronLocalFile {
  const char *path;
  const char *name;
  uint64_t size;
} CNDFIronLocalFile;

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

uint32_t cndf_iron_abi_version(void);

/**
 * Returns a static string with the crate version, upstream SHA and patch count.
 */
const char *cndf_iron_version(void);

struct CNDFIronSession *cndf_iron_session_create(const struct CNDFIronCallbacks *callbacks);

/**
 * Starts an asynchronous connection. The password is read during this call and the bridge copy is zeroized.
 */
enum CNDFIronStatus cndf_iron_connect(struct CNDFIronSession *session,
                                      const struct CNDFIronConnectOptions *options,
                                      const uint8_t *password_utf8,
                                      size_t password_length,
                                      uint64_t *out_generation);

enum CNDFIronStatus cndf_iron_send_input(struct CNDFIronSession *session,
                                         uint64_t generation,
                                         const struct CNDFIronInputEvent *events,
                                         size_t count,
                                         uint32_t timeout_ms);

enum CNDFIronStatus cndf_iron_resize(struct CNDFIronSession *session,
                                     uint64_t generation,
                                     uint32_t width,
                                     uint32_t height,
                                     uint32_t scale_percent);

/**
 * Re-delivers the current framebuffer with a full dirty rectangle and no server round trip.
 */
enum CNDFIronStatus cndf_iron_redeliver_frame(struct CNDFIronSession *session, uint64_t generation);

bool cndf_iron_is_connected(const struct CNDFIronSession *session, uint64_t generation);

bool cndf_iron_get_statistics(const struct CNDFIronSession *session,
                              struct CNDFIronStatistics *out);

/**
 * Requests orderly shutdown and returns immediately.
 */
enum CNDFIronStatus cndf_iron_disconnect(struct CNDFIronSession *session);

/**
 * Closes the callback gate and waits up to the join deadline for worker exit.
 * If a worker outlives that deadline the closed session is retained. Finish pending
 * certificate callbacks before calling destroy, and keep the context alive until it returns.
 */
void cndf_iron_session_destroy(struct CNDFIronSession *session, uint32_t join_timeout_ms);

uint32_t cndf_iron_capabilities(void);

/**
 * Copies UTF-8 text into the clipboard command queue.
 */
enum CNDFIronStatus cndf_iron_clipboard_offer_text(struct CNDFIronSession *session,
                                                   uint64_t generation,
                                                   const uint8_t *utf8,
                                                   size_t length);

/**
 * Copies local file metadata into the clipboard command queue.
 */
enum CNDFIronStatus cndf_iron_clipboard_offer_files(struct CNDFIronSession *session,
                                                    uint64_t generation,
                                                    const struct CNDFIronLocalFile *files,
                                                    size_t count);

/**
 * Queues a range request for an active, ready clipboard channel.
 */
enum CNDFIronStatus cndf_iron_clipboard_request_file_range(struct CNDFIronSession *session,
                                                           uint64_t generation,
                                                           uint32_t stream_id,
                                                           uint32_t list_index,
                                                           uint64_t offset,
                                                           uint32_t length);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* CNDF_IRONRDP_H */

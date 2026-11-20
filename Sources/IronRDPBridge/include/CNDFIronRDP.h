#ifndef CNDF_IRONRDP_H
#define CNDF_IRONRDP_H

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#define CNDF_IRON_ABI_VERSION 0

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

typedef void (*CNDFIronLogCallback)(uint64_t generation,
                                    enum CNDFIronLogLevel level,
                                    const uint8_t *utf8,
                                    size_t length,
                                    void *context);

typedef struct CNDFIronCertificateChain {
  const uint8_t *const *der;
  const size_t *der_length;
  size_t count;
  const char *hostname;
  uint16_t port;
  uint32_t problems;
} CNDFIronCertificateChain;

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

typedef void (*CNDFIronFrameCallback)(uint64_t generation,
                                      const uint8_t *bgra,
                                      uint32_t width,
                                      uint32_t height,
                                      uint32_t stride,
                                      struct CNDFIronRect dirty,
                                      uint64_t sequence,
                                      void *context);

typedef void (*CNDFIronPointerCallback)(uint64_t generation,
                                        enum CNDFIronPointerKind kind,
                                        const uint8_t *bgra,
                                        uint32_t width,
                                        uint32_t height,
                                        uint32_t stride,
                                        uint32_t hot_x,
                                        uint32_t hot_y,
                                        void *context);

typedef struct CNDFIronCallbacks {
  CNDFIronLogCallback log;
  CNDFIronCertificateTrustCallback certificate_trust;
  CNDFIronConnectedCallback connected;
  CNDFIronFailureCallback failure;
  CNDFIronDisconnectCallback disconnect;
  CNDFIronFrameCallback frame;
  CNDFIronPointerCallback pointer;
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
} CNDFIronStatistics;

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

uint32_t cndf_iron_abi_version(void);

const char *cndf_iron_version(void);

struct CNDFIronSession *cndf_iron_session_create(const struct CNDFIronCallbacks *callbacks);

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

enum CNDFIronStatus cndf_iron_redeliver_frame(struct CNDFIronSession *session, uint64_t generation);

bool cndf_iron_is_connected(const struct CNDFIronSession *session, uint64_t generation);

bool cndf_iron_get_statistics(const struct CNDFIronSession *session,
                              struct CNDFIronStatistics *out);

enum CNDFIronStatus cndf_iron_disconnect(struct CNDFIronSession *session);

void cndf_iron_session_destroy(struct CNDFIronSession *session, uint32_t join_timeout_ms);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* CNDF_IRONRDP_H */

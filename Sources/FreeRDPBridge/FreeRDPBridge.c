#include "FreeRDPBridge.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#if defined(RDP_FREERDP_REAL)
#include <freerdp/freerdp.h>
#include <freerdp/autodetect.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/codec/color.h>
#include <freerdp/graphics.h>
#include <freerdp/channels/channels.h>
#include <freerdp/error.h>
#include <freerdp/event.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/scancode.h>
#include <freerdp/settings.h>
#include <freerdp/settings_keys.h>
#include <freerdp/utils/cliprdr_utils.h>
#include <freerdp/utils/gfx.h>
#include <freerdp/version.h>
#include <winpr/file.h>
#include <winpr/shell.h>
#include <winpr/string.h>
#include <winpr/synch.h>
#include <winpr/thread.h>
#include <winpr/user.h>
#include <winpr/wlog.h>
#endif

#define RDP_BRIDGE_FORMAT_FILEGROUPDESCRIPTORW 0xC001
#define RDP_BRIDGE_FORMAT_FILECONTENTS 0xC002
// RDPGFX codec ids are < RDPGFX_CODECID_MAX (0x10); the last slot counts anything else.
#define RDP_BRIDGE_CODEC_SLOTS 17

struct RDPBridgeSession {
    RDPBridgeCallbacks callbacks;
    bool connected;
#if defined(RDP_FREERDP_REAL)
    freerdp *instance;
    HANDLE thread;
    volatile bool stop_requested;
    uint32_t desktop_width;
    uint32_t desktop_height;
    double desktop_scale;
    UINT32 last_error_code;
    BOOL certificate_rejected;
    DispClientContext *disp;
    CliprdrClientContext *cliprdr;
    char *local_text;
    size_t local_text_length;
    RDPBridgeLocalFile *local_files;
    size_t local_file_count;
    // TLS 1.2 자동 폴백 재시도: 첫 연결이 TLS connect 단계에서 실패하면(예: Entra
    // 하드닝 Azure VM의 TLS 1.3/SCHANNEL 비호환) 보관해 둔 옵션으로 인스턴스를 다시
    // 만들어 TLS 1.2를 강제한 뒤 한 번만 재시도한다. retry_options의 문자열은 소유
    // 복사본이라 호출자의 옵션이 사라진 뒤에도 안전하게 재구성할 수 있다.
    RDPBridgeConnectionOptions retry_options;
    bool retry_options_valid;
    RDPBridgeTLSStage tls_stage;
    // Serializes session->instance free/rebuild in the retry path (worker thread)
    // against freerdp_abort_connect_context in bridge_disconnect (caller thread).
    CRITICAL_SECTION instance_lock;
    bool instance_lock_initialized;
    // Graphics-path diagnostics, reset per connection: whether RDPGFX caps were
    // confirmed, how many surface commands each codec carried, and whether the
    // first frame has been classified (GFX vs legacy bitmap path).
    pcRdpgfxSurfaceCommand gfx_surface_command;
    bool gfx_caps_confirmed;
    bool first_frame_seen;
    uint64_t codec_counts[RDP_BRIDGE_CODEC_SLOTS];
    // Network auto-detect results received on this connection; the first is logged
    // as it arrives, the count and the last one at disconnect.
    uint32_t netchar_result_count;
    RDPBridgeNetworkCharacteristics last_netchar;
#endif
};

#if defined(RDP_FREERDP_REAL)
typedef struct RDPBridgeContext {
    rdpContext _p;
    RDPBridgeSession *session;
} RDPBridgeContext;

// FreeRDP allocates pointers at the prototype's size, so the converted image rides along.
typedef struct RDPBridgePointer {
    rdpPointer pointer;
    BYTE *bgra;
} RDPBridgePointer;

static RDPBridgeStatus bridge_disconnect(RDPBridgeSession *session, DWORD wait_timeout);
static RDPBridgeStatus bridge_build_instance(RDPBridgeSession *session,
                                             const RDPBridgeConnectionOptions *options,
                                             RDPBridgeTLSStage tls_stage);
#endif

static void bridge_log(RDPBridgeSession *session, const char *message) {
    if ((session != NULL) && (session->callbacks.log != NULL)) {
        session->callbacks.log(message, session->callbacks.context);
    }
}

static void bridge_logf(RDPBridgeSession *session, const char *format, ...) {
    if ((session == NULL) || (session->callbacks.log == NULL)) {
        return;
    }

    char message[256] = { 0 };
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    session->callbacks.log(message, session->callbacks.context);
}

static void bridge_failure(RDPBridgeSession *session, RDPBridgeFailureKind kind, UINT32 code, const char *description) {
    if ((session != NULL) && (session->callbacks.failure != NULL)) {
        session->callbacks.failure(kind, code, description != NULL ? description : "", session->callbacks.context);
    }
}

static void bridge_disconnect_event(RDPBridgeSession *session, RDPBridgeDisconnectKind kind, UINT32 code) {
    if ((session != NULL) && (session->callbacks.disconnect != NULL)) {
        session->callbacks.disconnect(kind, code, session->callbacks.context);
    }
}

RDPBridgeSession *rdp_bridge_session_create(const RDPBridgeCallbacks *callbacks) {
    RDPBridgeSession *session = (RDPBridgeSession *)calloc(1, sizeof(RDPBridgeSession));
    if (session == NULL) {
        return NULL;
    }

    if (callbacks != NULL) {
        session->callbacks = *callbacks;
    }

#if defined(RDP_FREERDP_REAL)
    InitializeCriticalSection(&session->instance_lock);
    session->instance_lock_initialized = true;
#endif

    return session;
}

void rdp_bridge_session_destroy(RDPBridgeSession *session) {
    if (session == NULL) {
        return;
    }

#if defined(RDP_FREERDP_REAL)
    (void)bridge_disconnect(session, INFINITE);
    if (session->instance_lock_initialized) {
        DeleteCriticalSection(&session->instance_lock);
        session->instance_lock_initialized = false;
    }
#else
    (void)rdp_bridge_disconnect(session);
#endif
    free(session);
}

#if defined(RDP_FREERDP_REAL)
static RDPBridgeSession *session_from_context(rdpContext *context) {
    if (context == NULL) {
        return NULL;
    }
    return ((RDPBridgeContext *)context)->session;
}

static BOOL bridge_begin_paint(rdpContext *context) {
    if ((context == NULL) || (context->gdi == NULL) || (context->gdi->primary == NULL) ||
        (context->gdi->primary->hdc == NULL) || (context->gdi->primary->hdc->hwnd == NULL) ||
        (context->gdi->primary->hdc->hwnd->invalid == NULL)) {
        return TRUE;
    }
    context->gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

static BOOL bridge_end_paint(rdpContext *context) {
    RDPBridgeSession *session = session_from_context(context);
    if ((session != NULL) && !session->first_frame_seen) {
        session->first_frame_seen = true;
        if (!session->gfx_caps_confirmed) {
            bridge_log(session, "Graphics: first frame arrived without RDPGFX caps confirm; legacy bitmap path.");
        }
    }
    if ((session == NULL) || (session->callbacks.frame == NULL) || (context == NULL) || (context->gdi == NULL)) {
        return TRUE;
    }

    rdpGdi *gdi = context->gdi;
    if ((gdi->primary_buffer == NULL) || (gdi->width <= 0) || (gdi->height <= 0)) {
        return TRUE;
    }

    session->callbacks.frame(
        gdi->primary_buffer,
        (uint32_t)gdi->width,
        (uint32_t)gdi->height,
        gdi->stride,
        session->callbacks.context);
    return TRUE;
}

static BOOL bridge_desktop_resize(rdpContext *context) {
    if ((context == NULL) || (context->gdi == NULL) || (context->settings == NULL)) {
        return FALSE;
    }
    const UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    bridge_logf(session_from_context(context), "Desktop resize received: %ux%u.", width, height);
    return gdi_resize(context->gdi, width, height);
}

static void bridge_clear_local_files(RDPBridgeSession *session) {
    if (session == NULL) {
        return;
    }
    for (size_t index = 0; index < session->local_file_count; index++) {
        free((void *)session->local_files[index].path);
        free((void *)session->local_files[index].fileName);
    }
    free(session->local_files);
    session->local_files = NULL;
    session->local_file_count = 0;
}

static UINT bridge_send_client_format_list(RDPBridgeSession *session) {
    if ((session == NULL) || (session->cliprdr == NULL)) {
        return CHANNEL_RC_OK;
    }

    CLIPRDR_FORMAT formats[3] = { 0 };
    UINT32 count = 0;

    if (session->local_text != NULL) {
        formats[count].formatId = CF_UNICODETEXT;
        count++;
    }
    if (session->local_file_count > 0) {
        formats[count].formatId = RDP_BRIDGE_FORMAT_FILEGROUPDESCRIPTORW;
        formats[count].formatName = "FileGroupDescriptorW";
        count++;
        formats[count].formatId = RDP_BRIDGE_FORMAT_FILECONTENTS;
        formats[count].formatName = "FileContents";
        count++;
    }

    CLIPRDR_FORMAT_LIST list = { 0 };
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = count;
    list.formats = formats;
    bridge_logf(
        session,
        "Clipboard local formats advertised: text=%s files=%zu.",
        session->local_text != NULL ? "yes" : "no",
        session->local_file_count);
    return session->cliprdr->ClientFormatList(session->cliprdr, &list);
}

static UINT bridge_send_file_group_descriptor(
    CliprdrClientContext *cliprdr,
    RDPBridgeSession *session) {
    FILEDESCRIPTORW *descriptors = (FILEDESCRIPTORW *)calloc(
        session->local_file_count,
        sizeof(FILEDESCRIPTORW));
    if (descriptors == NULL) {
        return CHANNEL_RC_NO_MEMORY;
    }

    for (size_t index = 0; index < session->local_file_count; index++) {
        descriptors[index].dwFlags = FD_ATTRIBUTES | FD_FILESIZE | FD_UNICODE;
        descriptors[index].dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
        descriptors[index].nFileSizeHigh = (DWORD)(session->local_files[index].size >> 32);
        descriptors[index].nFileSizeLow = (DWORD)(session->local_files[index].size & 0xFFFFFFFF);

        size_t wchar_count = 0;
        WCHAR *name = ConvertUtf8ToWCharAlloc(session->local_files[index].fileName, &wchar_count);
        if (name != NULL) {
            const size_t copy_count = (wchar_count < 259) ? wchar_count : 259;
            memcpy(descriptors[index].cFileName, name, copy_count * sizeof(WCHAR));
            descriptors[index].cFileName[copy_count] = 0;
            free(name);
        }
    }

    BYTE *data = NULL;
    UINT32 data_length = 0;
    UINT status = cliprdr_serialize_file_list(
        descriptors,
        (UINT32)session->local_file_count,
        &data,
        &data_length);
    free(descriptors);
    if (status != CHANNEL_RC_OK) {
        bridge_logf(session, "Clipboard local file descriptor serialization failed: %u.", status);
        return status;
    }

    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    response.common.dataLen = data_length;
    response.requestedFormatData = data;
    status = cliprdr->ClientFormatDataResponse(cliprdr, &response);
    bridge_logf(session, "Clipboard sent local file descriptor list: files=%zu bytes=%u.", session->local_file_count, data_length);
    free(data);
    return status;
}

static UINT bridge_cliprdr_server_format_data_request(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    if ((cliprdr == NULL) || (cliprdr->custom == NULL) || (request == NULL)) {
        return CHANNEL_RC_OK;
    }

    RDPBridgeSession *session = (RDPBridgeSession *)cliprdr->custom;
    if (request->requestedFormatId == RDP_BRIDGE_FORMAT_FILEGROUPDESCRIPTORW) {
        bridge_log(session, "Clipboard server requested local file descriptor list.");
        return bridge_send_file_group_descriptor(cliprdr, session);
    }

    if ((request->requestedFormatId != CF_UNICODETEXT) || (session->local_text == NULL)) {
        bridge_logf(session, "Clipboard server requested unsupported local format: id=%u.", request->requestedFormatId);
        CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
        response.common.msgType = CB_FORMAT_DATA_RESPONSE;
        response.common.msgFlags = CB_RESPONSE_FAIL;
        response.common.dataLen = 0;
        return cliprdr->ClientFormatDataResponse(cliprdr, &response);
    }

    size_t wchar_count = 0;
    WCHAR *wide = ConvertUtf8NToWCharAlloc(session->local_text, session->local_text_length, &wchar_count);
    if (wide == NULL) {
        return CHANNEL_RC_NO_MEMORY;
    }

    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    response.common.dataLen = (UINT32)((wchar_count + 1) * sizeof(WCHAR));
    response.requestedFormatData = (const BYTE *)wide;
    UINT status = cliprdr->ClientFormatDataResponse(cliprdr, &response);
    bridge_logf(session, "Clipboard sent local text: utf8Bytes=%zu utf16Bytes=%u.", session->local_text_length, response.common.dataLen);
    free(wide);
    return status;
}

static UINT bridge_cliprdr_server_format_data_response(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    if ((cliprdr == NULL) || (cliprdr->custom == NULL) || (response == NULL) ||
        (response->common.msgFlags != CB_RESPONSE_OK) || (response->requestedFormatData == NULL) ||
        (response->common.dataLen == 0)) {
        return CHANNEL_RC_OK;
    }

    RDPBridgeSession *session = (RDPBridgeSession *)cliprdr->custom;
    if (cliprdr->lastRequestedFormatId != CF_UNICODETEXT) {
        if (cliprdr->lastRequestedFormatId == RDP_BRIDGE_FORMAT_FILEGROUPDESCRIPTORW &&
            session->callbacks.remoteFileList != NULL) {
            bridge_logf(session, "Clipboard received remote file descriptor list: bytes=%u.", response->common.dataLen);
            session->callbacks.remoteFileList(
                response->requestedFormatData,
                response->common.dataLen,
                session->callbacks.context);
        }
        return CHANNEL_RC_OK;
    }

    const size_t wchar_count = response->common.dataLen / sizeof(WCHAR);
    char *utf8 = ConvertWCharNToUtf8Alloc((const WCHAR *)response->requestedFormatData, wchar_count, NULL);
    if (utf8 == NULL) {
        return CHANNEL_RC_NO_MEMORY;
    }

    if (session->callbacks.remoteText != NULL) {
        bridge_logf(session, "Clipboard received remote text: utf16Bytes=%u.", response->common.dataLen);
        session->callbacks.remoteText((const uint8_t *)utf8, strlen(utf8), session->callbacks.context);
    }
    free(utf8);
    return CHANNEL_RC_OK;
}

static UINT bridge_cliprdr_server_format_list_response(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    if ((cliprdr == NULL) || (cliprdr->custom == NULL) || (response == NULL)) {
        return CHANNEL_RC_OK;
    }
    RDPBridgeSession *session = (RDPBridgeSession *)cliprdr->custom;
    bridge_logf(session, "Clipboard remote acknowledged local format list: flags=0x%04x.", response->common.msgFlags);
    return CHANNEL_RC_OK;
}

static UINT bridge_cliprdr_server_capabilities(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_CAPABILITIES *capabilities) {
    if ((cliprdr == NULL) || (cliprdr->custom == NULL) || (capabilities == NULL)) {
        return CHANNEL_RC_OK;
    }

    RDPBridgeSession *session = (RDPBridgeSession *)cliprdr->custom;
    for (UINT32 index = 0; index < capabilities->cCapabilitiesSets; index++) {
        const CLIPRDR_CAPABILITY_SET *capability = &capabilities->capabilitySets[index];
        if ((capability->capabilitySetType == CB_CAPSTYPE_GENERAL) &&
            (capability->capabilitySetLength >= CB_CAPSTYPE_GENERAL_LEN)) {
            const CLIPRDR_GENERAL_CAPABILITY_SET *general =
                (const CLIPRDR_GENERAL_CAPABILITY_SET *)capability;
            bridge_logf(
                session,
                "Clipboard server capabilities: version=%u flags=0x%08x.",
                general->version,
                general->generalFlags);
        }
    }
    return CHANNEL_RC_OK;
}

static UINT bridge_cliprdr_monitor_ready(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_MONITOR_READY *monitor_ready) {
    if ((cliprdr == NULL) || (cliprdr->custom == NULL)) {
        return CHANNEL_RC_OK;
    }

    RDPBridgeSession *session = (RDPBridgeSession *)cliprdr->custom;
    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    CLIPRDR_CAPABILITIES capabilities = { 0 };
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES |
                           CB_STREAM_FILECLIP_ENABLED |
                           CB_FILECLIP_NO_FILE_PATHS |
                           CB_HUGE_FILE_SUPPORT_ENABLED;
    capabilities.common.msgType = CB_CLIP_CAPS;
    capabilities.cCapabilitiesSets = 1;
    capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;

    bridge_log(session, "Clipboard monitor ready; sending client capabilities.");
    UINT status = cliprdr->ClientCapabilities(cliprdr, &capabilities);
    if (status != CHANNEL_RC_OK) {
        return status;
    }

    if ((session->local_text != NULL) || (session->local_file_count > 0)) {
        return bridge_send_client_format_list(session);
    }
    return CHANNEL_RC_OK;
}

static UINT bridge_cliprdr_server_format_list(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FORMAT_LIST *format_list) {
    if ((cliprdr == NULL) || (format_list == NULL)) {
        return CHANNEL_RC_OK;
    }

    CLIPRDR_FORMAT_LIST_RESPONSE list_response = { 0 };
    list_response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    list_response.common.msgFlags = CB_RESPONSE_OK;
    cliprdr->ClientFormatListResponse(cliprdr, &list_response);
    RDPBridgeSession *session = (RDPBridgeSession *)cliprdr->custom;
    bridge_logf(session, "Clipboard remote format list received: count=%u.", format_list->numFormats);

    for (UINT32 index = 0; index < format_list->numFormats; index++) {
        bridge_logf(
            session,
            "Clipboard remote format[%u]: id=%u name=%s.",
            index,
            format_list->formats[index].formatId,
            format_list->formats[index].formatName != NULL ? format_list->formats[index].formatName : "(null)");
        if (format_list->formats[index].formatName != NULL &&
            strcmp(format_list->formats[index].formatName, "FileGroupDescriptorW") == 0) {
            CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
            request.common.msgType = CB_FORMAT_DATA_REQUEST;
            request.requestedFormatId = format_list->formats[index].formatId;
            cliprdr->lastRequestedFormatId = RDP_BRIDGE_FORMAT_FILEGROUPDESCRIPTORW;
            bridge_logf(session, "Clipboard requesting remote file descriptor format: id=%u.", request.requestedFormatId);
            return cliprdr->ClientFormatDataRequest(cliprdr, &request);
        }
        if (format_list->formats[index].formatId == CF_UNICODETEXT) {
            CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
            request.common.msgType = CB_FORMAT_DATA_REQUEST;
            request.requestedFormatId = CF_UNICODETEXT;
            cliprdr->lastRequestedFormatId = CF_UNICODETEXT;
            bridge_log(session, "Clipboard requesting remote text format.");
            return cliprdr->ClientFormatDataRequest(cliprdr, &request);
        }
    }

    return CHANNEL_RC_OK;
}

static UINT bridge_cliprdr_server_file_contents_request(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FILE_CONTENTS_REQUEST *request) {
    if ((cliprdr == NULL) || (cliprdr->custom == NULL) || (request == NULL)) {
        return CHANNEL_RC_OK;
    }

    RDPBridgeSession *session = (RDPBridgeSession *)cliprdr->custom;
    if (request->listIndex >= session->local_file_count) {
        bridge_logf(session, "Clipboard local file request rejected: listIndex=%u count=%zu.", request->listIndex, session->local_file_count);
        return CHANNEL_RC_OK;
    }

    const RDPBridgeLocalFile *file = &session->local_files[request->listIndex];
    BYTE size_data[8] = { 0 };
    BYTE *buffer = NULL;
    UINT32 response_size = 0;

    if (request->dwFlags & FILECONTENTS_SIZE) {
        UINT64 size = file->size;
        memcpy(size_data, &size, sizeof(size));
        buffer = size_data;
        response_size = sizeof(size_data);
        bridge_logf(session, "Clipboard server requested local file size: index=%u size=%llu.", request->listIndex, (unsigned long long)file->size);
    } else if (request->dwFlags & FILECONTENTS_RANGE) {
        FILE *handle = fopen(file->path, "rb");
        if (handle == NULL) {
            bridge_logf(session, "Clipboard local file open failed: %s.", file->path);
            return CHANNEL_RC_OK;
        }
        const UINT64 offset = ((UINT64)request->nPositionHigh << 32) | request->nPositionLow;
        if (fseeko(handle, (off_t)offset, SEEK_SET) != 0) {
            fclose(handle);
            return CHANNEL_RC_OK;
        }
        response_size = request->cbRequested;
        buffer = (BYTE *)malloc(response_size);
        if (buffer == NULL) {
            fclose(handle);
            return CHANNEL_RC_NO_MEMORY;
        }
        response_size = (UINT32)fread(buffer, 1, response_size, handle);
        fclose(handle);
        bridge_logf(
            session,
            "Clipboard server requested local file range: index=%u offset=%llu requested=%u sent=%u.",
            request->listIndex,
            (unsigned long long)offset,
            request->cbRequested,
            response_size);
    } else {
        return CHANNEL_RC_OK;
    }

    CLIPRDR_FILE_CONTENTS_RESPONSE response = { 0 };
    response.common.msgType = CB_FILECONTENTS_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    response.common.dataLen = response_size;
    response.streamId = request->streamId;
    response.cbRequested = response_size;
    response.requestedData = buffer;
    UINT status = cliprdr->ClientFileContentsResponse(cliprdr, &response);
    if (buffer != size_data) {
        free(buffer);
    }
    return status;
}

static UINT bridge_cliprdr_server_file_contents_response(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FILE_CONTENTS_RESPONSE *response) {
    if ((cliprdr == NULL) || (cliprdr->custom == NULL) || (response == NULL) ||
        (response->common.msgFlags != CB_RESPONSE_OK) || (response->requestedData == NULL)) {
        return CHANNEL_RC_OK;
    }

    RDPBridgeSession *session = (RDPBridgeSession *)cliprdr->custom;
    if (session->callbacks.remoteFileContents != NULL) {
        bridge_logf(session, "Clipboard received remote file contents: stream=%u bytes=%u.", response->streamId, response->cbRequested);
        session->callbacks.remoteFileContents(
            response->streamId,
            response->requestedData,
            response->cbRequested,
            session->callbacks.context);
    }
    return CHANNEL_RC_OK;
}

static const char *bridge_build_flag(const char *name) {
    const char *config = freerdp_get_build_config();
    if ((config == NULL) || (name == NULL)) {
        return "unknown";
    }
    const size_t name_length = strlen(name);
    for (const char *match = strstr(config, name); match != NULL; match = strstr(match + 1, name)) {
        const bool starts_token = (match == config) || (match[-1] == ' ');
        if (starts_token && (match[name_length] == '=')) {
            return (strncmp(match + name_length + 1, "ON", 2) == 0) ? "ON" : "OFF";
        }
    }
    return "unknown";
}

static UINT bridge_gfx_caps_confirm(RdpgfxClientContext *gfx, const RDPGFX_CAPS_CONFIRM_PDU *confirm) {
    rdpGdi *gdi = (gfx != NULL) ? (rdpGdi *)gfx->custom : NULL;
    RDPBridgeSession *session = (gdi != NULL) ? session_from_context(gdi->context) : NULL;
    if ((session != NULL) && (confirm != NULL) && (confirm->capsSet != NULL)) {
        session->gfx_caps_confirmed = true;
        bridge_logf(
            session,
            "Graphics: RDPGFX caps confirmed: version=%s [0x%08x] flags=0x%08x.",
            rdpgfx_caps_version_str(confirm->capsSet->version),
            confirm->capsSet->version,
            confirm->capsSet->flags);
    }
    return CHANNEL_RC_OK;
}

static UINT bridge_gfx_surface_command(RdpgfxClientContext *gfx, const RDPGFX_SURFACE_COMMAND *cmd) {
    rdpGdi *gdi = (gfx != NULL) ? (rdpGdi *)gfx->custom : NULL;
    RDPBridgeSession *session = (gdi != NULL) ? session_from_context(gdi->context) : NULL;
    if ((session == NULL) || (session->gfx_surface_command == NULL)) {
        return ERROR_INVALID_PARAMETER;
    }
    if (cmd != NULL) {
        const size_t slot = (cmd->codecId < RDP_BRIDGE_CODEC_SLOTS - 1) ? cmd->codecId : RDP_BRIDGE_CODEC_SLOTS - 1;
        if (session->codec_counts[slot]++ == 0) {
            bridge_logf(
                session,
                "Graphics: first RDPGFX surface command with codec %s [0x%04x].",
                rdpgfx_get_codec_id_string((UINT16)cmd->codecId),
                cmd->codecId);
        }
    }
    return session->gfx_surface_command(gfx, cmd);
}

// Wraps the gdi RDPGFX handlers installed by freerdp_client_OnChannelConnectedEventHandler
// so the caps the server confirmed and the codecs it actually uses are logged.
static void bridge_attach_gfx_diagnostics(RDPBridgeSession *session, RdpgfxClientContext *gfx) {
    if ((gfx == NULL) || (gfx->SurfaceCommand == NULL) || (gfx->SurfaceCommand == bridge_gfx_surface_command)) {
        return;
    }
    session->gfx_surface_command = gfx->SurfaceCommand;
    gfx->SurfaceCommand = bridge_gfx_surface_command;
    gfx->CapsConfirm = bridge_gfx_caps_confirm;
}

static void bridge_reset_graphics_diagnostics(RDPBridgeSession *session) {
    session->gfx_caps_confirmed = false;
    session->first_frame_seen = false;
    memset(session->codec_counts, 0, sizeof(session->codec_counts));
    session->netchar_result_count = 0;
    memset(&session->last_netchar, 0, sizeof(session->last_netchar));
}

static void bridge_log_graphics_summary(RDPBridgeSession *session) {
    char summary[192] = { 0 };
    size_t used = 0;
    for (size_t slot = 0; slot < RDP_BRIDGE_CODEC_SLOTS; slot++) {
        if ((session->codec_counts[slot] == 0) || (used >= sizeof(summary))) {
            continue;
        }
        const int written = (slot < RDP_BRIDGE_CODEC_SLOTS - 1)
            ? snprintf(summary + used, sizeof(summary) - used, " 0x%04zx=%llu", slot,
                       (unsigned long long)session->codec_counts[slot])
            : snprintf(summary + used, sizeof(summary) - used, " other=%llu",
                       (unsigned long long)session->codec_counts[slot]);
        if (written > 0) {
            used += (size_t)written;
        }
    }
    bridge_logf(
        session,
        "Graphics summary: rdpgfx=%s surfaceCommands:%s.",
        session->gfx_caps_confirmed ? "yes" : "no",
        used > 0 ? summary : " none");
}

static void bridge_channel_connected(void *context, const ChannelConnectedEventArgs *event) {
    freerdp_client_OnChannelConnectedEventHandler(context, event);

    rdpContext *rdp_context = (rdpContext *)context;
    RDPBridgeSession *session = session_from_context(rdp_context);
    if ((session == NULL) || (event == NULL) || (event->name == NULL)) {
        return;
    }

    char message[128] = { 0 };
    snprintf(message, sizeof(message), "FreeRDP channel connected: %s", event->name);
    bridge_log(session, message);

    if (event->pInterface == NULL) {
        return;
    }

    if (strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        bridge_attach_gfx_diagnostics(session, (RdpgfxClientContext *)event->pInterface);
        return;
    }

    if ((strcmp(event->name, DISP_CHANNEL_NAME) == 0) ||
        (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0)) {
        session->disp = (DispClientContext *)event->pInterface;
        session->disp->custom = session;
        bridge_log(session, "Display control channel connected.");
        return;
    }

    if (strcmp(event->name, CLIPRDR_CHANNEL_NAME) == 0) {
        session->cliprdr = (CliprdrClientContext *)event->pInterface;
        session->cliprdr->custom = session;
        session->cliprdr->ServerCapabilities = bridge_cliprdr_server_capabilities;
        session->cliprdr->MonitorReady = bridge_cliprdr_monitor_ready;
        session->cliprdr->ServerFormatList = bridge_cliprdr_server_format_list;
        session->cliprdr->ServerFormatListResponse = bridge_cliprdr_server_format_list_response;
        session->cliprdr->ServerFormatDataRequest = bridge_cliprdr_server_format_data_request;
        session->cliprdr->ServerFormatDataResponse = bridge_cliprdr_server_format_data_response;
        session->cliprdr->ServerFileContentsRequest = bridge_cliprdr_server_file_contents_request;
        session->cliprdr->ServerFileContentsResponse = bridge_cliprdr_server_file_contents_response;
        bridge_log(session, "Clipboard channel connected.");
    }
}

static void bridge_attach_cliprdr(RDPBridgeSession *session) {
    if ((session == NULL) || (session->instance == NULL) || (session->instance->context == NULL) ||
        (session->instance->context->channels == NULL)) {
        return;
    }
    CliprdrClientContext *cliprdr = (CliprdrClientContext *)freerdp_channels_get_static_channel_interface(
        session->instance->context->channels,
        CLIPRDR_CHANNEL_NAME);
    if (cliprdr == NULL) {
        bridge_log(session, "Clipboard channel unavailable.");
        return;
    }

    session->cliprdr = cliprdr;
    session->cliprdr->custom = session;
    session->cliprdr->ServerCapabilities = bridge_cliprdr_server_capabilities;
    session->cliprdr->MonitorReady = bridge_cliprdr_monitor_ready;
    session->cliprdr->ServerFormatList = bridge_cliprdr_server_format_list;
    session->cliprdr->ServerFormatListResponse = bridge_cliprdr_server_format_list_response;
    session->cliprdr->ServerFormatDataRequest = bridge_cliprdr_server_format_data_request;
    session->cliprdr->ServerFormatDataResponse = bridge_cliprdr_server_format_data_response;
    session->cliprdr->ServerFileContentsRequest = bridge_cliprdr_server_file_contents_request;
    session->cliprdr->ServerFileContentsResponse = bridge_cliprdr_server_file_contents_response;
    bridge_log(session, "Clipboard channel attached.");
}

static void bridge_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *event) {
    freerdp_client_OnChannelDisconnectedEventHandler(context, event);

    rdpContext *rdp_context = (rdpContext *)context;
    RDPBridgeSession *session = session_from_context(rdp_context);
    if ((session == NULL) || (event == NULL) || (event->name == NULL)) {
        return;
    }
    if ((strcmp(event->name, DISP_CHANNEL_NAME) == 0) ||
        (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0)) {
        session->disp = NULL;
    } else if (strcmp(event->name, CLIPRDR_CHANNEL_NAME) == 0) {
        session->cliprdr = NULL;
    }
}

static BOOL bridge_load_channels(freerdp *instance) {
    if ((instance == NULL) || (instance->context == NULL) || (instance->context->settings == NULL)) {
        return FALSE;
    }
    if (!freerdp_client_load_addins(instance->context->channels, instance->context->settings)) {
        return FALSE;
    }
    bridge_log(session_from_context(instance->context), "FreeRDP channel addins loaded.");
    return TRUE;
}

static BOOL bridge_network_characteristics_result(
    rdpAutoDetect *autodetect,
    RDP_TRANSPORT_TYPE transport,
    UINT16 sequence_number,
    const rdpNetworkCharacteristicsResult *result) {
    (void)transport;
    (void)sequence_number;
    RDPBridgeSession *session = (autodetect != NULL) ? session_from_context(autodetect->context) : NULL;
    if ((session == NULL) || (result == NULL)) {
        return TRUE;
    }

    RDPBridgeNetworkCharacteristics netchar = { 0 };
    netchar.hasBaseRTT = (result->type == RDP_NETCHAR_RESULT_TYPE_BASE_RTT_AVG_RTT) ||
                         (result->type == RDP_NETCHAR_RESULT_TYPE_BASE_RTT_BW_AVG_RTT);
    netchar.hasBandwidth = (result->type == RDP_NETCHAR_RESULT_TYPE_BW_AVG_RTT) ||
                           (result->type == RDP_NETCHAR_RESULT_TYPE_BASE_RTT_BW_AVG_RTT);
    netchar.baseRTTMs = result->baseRTT;
    netchar.averageRTTMs = result->averageRTT;
    netchar.bandwidthKbps = result->bandwidth;
    session->last_netchar = netchar;
    if (session->netchar_result_count++ == 0) {
        bridge_logf(
            session,
            "Network auto-detect initial server values (may be defaults, not a measured link estimate): type=0x%04x baseRTT=%ums averageRTT=%ums bandwidth=%ukbps.",
            (unsigned)result->type,
            result->baseRTT,
            result->averageRTT,
            result->bandwidth);
    }
    if (session->callbacks.networkCharacteristics != NULL) {
        session->callbacks.networkCharacteristics(&netchar, session->callbacks.context);
    }
    return TRUE;
}

static BOOL bridge_pre_connect(freerdp *instance) {
    if ((instance == NULL) || (instance->context == NULL) || (instance->context->settings == NULL)) {
        return FALSE;
    }
    // If a disconnect was requested before this connect actually started its
    // transport (e.g. a cancel that raced the TLS-1.2 retry, after FreeRDP reset
    // the abort event at connect-begin), bail here so the connect doesn't ignore
    // the lost abort and make bridge_disconnect wait out its timeout.
    RDPBridgeSession *pre_session = session_from_context(instance->context);
    if ((pre_session != NULL) && pre_session->stop_requested) {
        return FALSE;
    }
    if (!freerdp_settings_set_bool(instance->context->settings, FreeRDP_CertificateCallbackPreferPEM, TRUE)) {
        return FALSE;
    }
    if (freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0) != CHANNEL_RC_OK) {
        return FALSE;
    }
    PubSub_SubscribeChannelConnected(instance->context->pubSub, bridge_channel_connected);
    PubSub_SubscribeChannelDisconnected(instance->context->pubSub, bridge_channel_disconnected);
    // The client side leaves this callback unset; it only fires when the server runs
    // auto-detection, which needs FreeRDP_NetworkAutoDetect.
    rdpAutoDetect *autodetect = autodetect_get(instance->context);
    if (autodetect != NULL) {
        autodetect->NetworkCharacteristicsResult = bridge_network_characteristics_result;
    }
    return TRUE;
}

static DWORD bridge_verify_certificate_ex(
    freerdp *instance,
    const char *host,
    UINT16 port,
    const char *common_name,
    const char *subject,
    const char *issuer,
    const char *fingerprint,
    DWORD flags) {
    (void)common_name;
    (void)subject;
    (void)issuer;
    (void)flags;

    RDPBridgeSession *session = session_from_context(instance->context);
    if ((session == NULL) || (session->callbacks.certificateTrust == NULL)) {
        return 1;
    }

    bridge_logf(session, "RDP cert verify (new) host=%s:%u fp=%s", host ? host : "", port,
                fingerprint ? fingerprint : "");
    const BOOL trusted = session->callbacks.certificateTrust(
        fingerprint != NULL ? fingerprint : "",
        host != NULL ? host : "",
        port,
        session->callbacks.context);
    if (!trusted) {
        session->certificate_rejected = TRUE;
        return 0;
    }
    return 1;
}

// Called when the server's certificate DIFFERS from the one stored in
// FreeRDP's known_hosts (~/.config/freerdp/server/<host>_<port>.pem) — i.e. the
// cert was re-issued / changed (common for AD-joined hosts reached via a VPN
// alias). Without registering this, FreeRDP falls back to its default CLI
// handler which reads stdin and, in a windowed app with no TTY, rejects ->
// ERRCONNECT_TLS_CONNECT_FAILED. Route it to the SAME app trust callback as the
// new-cert path so the app's "certificate changed — trust?" prompt (TOFU /
// fingerprint update) decides, instead of a silent reject.
static DWORD bridge_verify_changed_certificate_ex(
    freerdp *instance,
    const char *host,
    UINT16 port,
    const char *common_name,
    const char *subject,
    const char *issuer,
    const char *new_fingerprint,
    const char *old_subject,
    const char *old_issuer,
    const char *old_fingerprint,
    DWORD flags) {
    (void)common_name;
    (void)subject;
    (void)issuer;
    (void)old_subject;
    (void)old_issuer;
    (void)old_fingerprint;
    (void)flags;

    RDPBridgeSession *session = session_from_context(instance->context);
    // Fail CLOSED for a CHANGED certificate: a known_hosts mismatch is a strong
    // MITM/host-alias signal, so without an explicit trust decision (no session
    // or no trust callback) reject rather than accept-and-store. (The new-cert
    // path may TOFU-accept on first contact; a *changed* cert must not.)
    if (session == NULL) {
        return 0;
    }
    if (session->callbacks.certificateTrust == NULL) {
        session->certificate_rejected = TRUE;
        return 0;
    }

    bridge_logf(session, "RDP cert verify (changed) host=%s:%u newfp=%s oldfp=%s", host ? host : "",
                port, new_fingerprint ? new_fingerprint : "", old_fingerprint ? old_fingerprint : "");
    const BOOL trusted = session->callbacks.certificateTrust(
        new_fingerprint != NULL ? new_fingerprint : "",
        host != NULL ? host : "",
        port,
        session->callbacks.context);
    if (!trusted) {
        session->certificate_rejected = TRUE;
        return 0;
    }
    return 1;
}

static BOOL bridge_pointer_to_bgra(const rdpPointer *pointer, const gdiPalette *palette, BYTE *bgra) {
    return freerdp_image_copy_from_pointer_data(
        bgra, PIXEL_FORMAT_BGRA32, 0, 0, 0, pointer->width, pointer->height,
        pointer->xorMaskData, pointer->lengthXorMask, pointer->andMaskData, pointer->lengthAndMask,
        pointer->xorBpp, palette);
}

static void bridge_report_pointer(RDPBridgeSession *session, RDPBridgePointerKind kind, const RDPBridgePointer *pointer) {
    if ((session == NULL) || (session->callbacks.pointer == NULL)) {
        return;
    }
    if ((kind == RDPBridgePointerKindImage) && (pointer != NULL) && (pointer->bgra != NULL)) {
        session->callbacks.pointer(
            kind, pointer->bgra, pointer->pointer.width, pointer->pointer.height, pointer->pointer.width * 4,
            pointer->pointer.xPos, pointer->pointer.yPos, session->callbacks.context);
        return;
    }
    // A pointer without pixels (0x0) shows nothing.
    if (kind == RDPBridgePointerKindImage) {
        kind = RDPBridgePointerKindHidden;
    }
    session->callbacks.pointer(kind, NULL, 0, 0, 0, 0, 0, session->callbacks.context);
}

static BOOL bridge_pointer_new(rdpContext *context, rdpPointer *pointer) {
    RDPBridgePointer *bridge_pointer = (RDPBridgePointer *)pointer;
    if ((context == NULL) || (bridge_pointer == NULL)) {
        return FALSE;
    }
    bridge_pointer->bgra = NULL;
    if ((pointer->width == 0) || (pointer->height == 0)) {
        return TRUE;
    }
    BYTE *bgra = (BYTE *)calloc((size_t)pointer->width * pointer->height, 4);
    if (bgra == NULL) {
        return FALSE;
    }
    const gdiPalette *palette = (context->gdi != NULL) ? &context->gdi->palette : NULL;
    if (!bridge_pointer_to_bgra(pointer, palette, bgra)) {
        free(bgra);
        return FALSE;
    }
    bridge_pointer->bgra = bgra;
    return TRUE;
}

static void bridge_pointer_free(rdpContext *context, rdpPointer *pointer) {
    (void)context;
    RDPBridgePointer *bridge_pointer = (RDPBridgePointer *)pointer;
    if (bridge_pointer != NULL) {
        free(bridge_pointer->bgra);
        bridge_pointer->bgra = NULL;
    }
}

static BOOL bridge_pointer_set(rdpContext *context, rdpPointer *pointer) {
    bridge_report_pointer(session_from_context(context), RDPBridgePointerKindImage, (const RDPBridgePointer *)pointer);
    return TRUE;
}

static BOOL bridge_pointer_set_null(rdpContext *context) {
    bridge_report_pointer(session_from_context(context), RDPBridgePointerKindHidden, NULL);
    return TRUE;
}

static BOOL bridge_pointer_set_default(rdpContext *context) {
    bridge_report_pointer(session_from_context(context), RDPBridgePointerKindDefault, NULL);
    return TRUE;
}

static BOOL bridge_pointer_set_position(rdpContext *context, UINT32 x, UINT32 y) {
    // Server-initiated pointer warps are ignored: the local mouse is never moved.
    (void)context;
    (void)x;
    (void)y;
    return TRUE;
}

static BOOL bridge_post_connect(freerdp *instance) {
    if ((instance == NULL) || (instance->context == NULL)) {
        return FALSE;
    }
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) {
        return FALSE;
    }
    instance->context->update->BeginPaint = bridge_begin_paint;
    instance->context->update->EndPaint = bridge_end_paint;
    instance->context->update->DesktopResize = bridge_desktop_resize;
    rdpPointer pointer = { 0 };
    pointer.size = sizeof(RDPBridgePointer);
    pointer.New = bridge_pointer_new;
    pointer.Free = bridge_pointer_free;
    pointer.Set = bridge_pointer_set;
    pointer.SetNull = bridge_pointer_set_null;
    pointer.SetDefault = bridge_pointer_set_default;
    pointer.SetPosition = bridge_pointer_set_position;
    graphics_register_pointer(instance->context->graphics, &pointer);
    // Sync the server keyboard toggle state to NumLock-ON so the numeric keypad sends DIGITS, not
    // navigation. A fresh session starts NumLock OFF and macOS does not expose the local NumLock state,
    // so the keypad scancodes (0x47-0x53) would otherwise register as Home/End/arrows/Insert/Delete
    // instead of 0-9. A connect-time synchronize is the robust fix. (CNDF numpad fix.)
    if (instance->context->input != NULL) {
        freerdp_input_send_synchronize_event(instance->context->input, KBD_SYNC_NUM_LOCK);
    }
    return TRUE;
}

static void bridge_post_disconnect(freerdp *instance) {
    if ((instance != NULL) && (instance->context != NULL) && (instance->context->gdi != NULL)) {
        gdi_free(instance);
    }
}

static BOOL set_string(rdpSettings *settings, FreeRDP_Settings_Keys_String key, const char *value) {
    if (value == NULL) {
        return TRUE;
    }
    return freerdp_settings_set_string(settings, key, value);
}

static void bridge_apply_log_filter(const char *name, size_t name_length, const char *level, size_t level_length) {
    if ((name == NULL) || (level == NULL) || (name_length == 0) || (level_length == 0)) {
        return;
    }

    char *filter_name = (char *)calloc(name_length + 1, 1);
    char *filter_level = (char *)calloc(level_length + 1, 1);
    if ((filter_name == NULL) || (filter_level == NULL)) {
        free(filter_name);
        free(filter_level);
        return;
    }

    memcpy(filter_name, name, name_length);
    memcpy(filter_level, level, level_length);
    WLog_SetStringLogLevel(WLog_Get(filter_name), filter_level);
    free(filter_name);
    free(filter_level);
}

static void bridge_apply_log_options(const RDPBridgeConnectionOptions *options) {
    if ((options == NULL) || (options->logLevel == NULL) || (strlen(options->logLevel) == 0)) {
        WLog_SetStringLogLevel(WLog_GetRoot(), "INFO");
    } else {
        WLog_SetStringLogLevel(WLog_GetRoot(), options->logLevel);
    }

    if ((options == NULL) || (options->logFilters == NULL) || (strlen(options->logFilters) == 0)) {
        return;
    }

    const char *cursor = options->logFilters;
    while (*cursor != '\0') {
        const char *entry_end = strchr(cursor, '\n');
        if (entry_end == NULL) {
            entry_end = cursor + strlen(cursor);
        }
        const char *separator = memchr(cursor, '=', (size_t)(entry_end - cursor));
        if (separator != NULL) {
            bridge_apply_log_filter(
                cursor,
                (size_t)(separator - cursor),
                separator + 1,
                (size_t)(entry_end - separator - 1));
        }
        cursor = *entry_end == '\0' ? entry_end : entry_end + 1;
    }
}

static BOOL bridge_add_redirected_folder(
    rdpSettings *settings,
    const char *path,
    const char *name) {
    if ((settings == NULL) || (path == NULL) || (strlen(path) == 0)) {
        return TRUE;
    }
    struct stat path_stat = { 0 };
    if ((stat(path, &path_stat) != 0) || !S_ISDIR(path_stat.st_mode)) {
        return FALSE;
    }

    const char *share_name = ((name != NULL) && (strlen(name) > 0)) ? name : "RemoteShare";
    const char *args[] = { share_name, path };
    RDPDR_DEVICE *device = freerdp_device_new(RDPDR_DTYP_FILESYSTEM, 2, args);
    if (device == NULL) {
        return FALSE;
    }
    if (!freerdp_device_collection_add(settings, device)) {
        freerdp_device_free(device);
        return FALSE;
    }
    return TRUE;
}

static BOOL configure_instance(RDPBridgeSession *session, const RDPBridgeConnectionOptions *options) {
    freerdp *instance = session->instance;
    rdpSettings *settings = instance->context->settings;
    instance->VerifyCertificateEx = bridge_verify_certificate_ex;
    instance->VerifyChangedCertificateEx = bridge_verify_changed_certificate_ex;
    bridge_apply_log_options(options);

    if (!set_string(settings, FreeRDP_ServerHostname, options->host)) {
        return FALSE;
    }
    if (!freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, options->port)) {
        return FALSE;
    }
    if (!set_string(settings, FreeRDP_Username, options->username)) {
        return FALSE;
    }
    if (!set_string(settings, FreeRDP_Password, options->password)) {
        return FALSE;
    }
    if (!set_string(settings, FreeRDP_Domain, options->domain)) {
        return FALSE;
    }

    session->desktop_width = options->desktopWidth > 0 ? options->desktopWidth : session->desktop_width;
    session->desktop_height = options->desktopHeight > 0 ? options->desktopHeight : session->desktop_height;
    session->desktop_width = session->desktop_width == 0 ? 1440 : session->desktop_width;
    session->desktop_height = session->desktop_height == 0 ? 900 : session->desktop_height;
    session->desktop_scale = options->desktopScale >= 1.0 ? options->desktopScale : 1.0;
    UINT32 color_depth = options->colorDepth;
    if ((color_depth != 16) && (color_depth != 24) && (color_depth != 32)) {
        color_depth = 32;
    }
    UINT32 desktop_scale_factor = (UINT32)(session->desktop_scale * 100.0);
    if (desktop_scale_factor < 100) {
        desktop_scale_factor = 100;
    }
    const BOOL has_redirected_folder =
        (options->redirectedFolderPath != NULL) && (strlen(options->redirectedFolderPath) > 0);
    const BOOL enable_device_redirection = options->enableDriveRedirection || has_redirected_folder ||
                                           (options->audioPlaybackMode == RDPBridgeAudioPlaybackLocal);
    const BOOL audio_playback = options->audioPlaybackMode == RDPBridgeAudioPlaybackLocal;
    const BOOL remote_console_audio = options->audioPlaybackMode == RDPBridgeAudioPlaybackRemote;

    if (!bridge_add_redirected_folder(settings, options->redirectedFolderPath, options->redirectedFolderName)) {
        return FALSE;
    }

    return freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, session->desktop_width) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, session->desktop_height) &&
           freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, color_depth) &&
           freerdp_settings_set_bool(settings, FreeRDP_Authentication, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, options->enableClipboard) &&
           freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, enable_device_redirection) &&
           freerdp_settings_set_bool(settings, FreeRDP_RedirectDrives, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RedirectHomeDrive, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, audio_playback) &&
           freerdp_settings_set_bool(settings, FreeRDP_RemoteConsoleAudio, remote_console_audio) &&
           freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RedirectSmartCards, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RedirectPrinters, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RedirectSerialPorts, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RedirectParallelPorts, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_SupportDynamicChannels, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_DesktopResize, TRUE) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, desktop_scale_factor) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, 100) &&
           freerdp_settings_set_bool(settings, FreeRDP_AsyncChannels, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_AsyncUpdate, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_FastPathInput, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_FastPathOutput, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxH264, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_SupportHeartbeatPdu, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_SupportMultitransport, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, options->networkAutoDetect);
}

static RDPBridgeFailureKind bridge_failure_kind_for_error(RDPBridgeSession *session, UINT32 code) {
    if ((session != NULL) && session->certificate_rejected) {
        return RDPBridgeFailureCertificate;
    }
    switch (code) {
        case FREERDP_ERROR_DNS_ERROR:
        case FREERDP_ERROR_DNS_NAME_NOT_FOUND:
        case FREERDP_ERROR_CONNECT_FAILED:
        case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED:
        case FREERDP_ERROR_CONNECT_KDC_UNREACHABLE:
            return RDPBridgeFailureNetwork;
        case FREERDP_ERROR_TLS_CONNECT_FAILED:
        case FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED:
        case FREERDP_ERROR_MCS_CONNECT_INITIAL_ERROR:
            return RDPBridgeFailureTLS;
        case FREERDP_ERROR_AUTHENTICATION_FAILED:
        case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
        case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
        case FREERDP_ERROR_CONNECT_ACCESS_DENIED:
        case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS:
        case FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
        case FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION:
        case FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED:
        case FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED:
        case FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE:
        case FREERDP_ERROR_CONNECT_PASSWORD_CERTAINLY_EXPIRED:
            return RDPBridgeFailureAuthentication;
        case FREERDP_ERROR_PRE_CONNECT_FAILED:
        case FREERDP_ERROR_POST_CONNECT_FAILED:
            return RDPBridgeFailureConfiguration;
        default:
            return RDPBridgeFailureFreeRDP;
    }
}

static RDPBridgeDisconnectKind bridge_disconnect_kind_for_error(RDPBridgeSession *session, UINT32 code) {
    if ((session != NULL) && session->stop_requested) {
        return RDPBridgeDisconnectLocalRequest;
    }
    if ((session != NULL) && session->certificate_rejected) {
        return RDPBridgeDisconnectError;
    }
    switch (code) {
        case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED:
        case FREERDP_ERROR_CONNECT_ACTIVATION_TIMEOUT:
            return RDPBridgeDisconnectTimeout;
        case FREERDP_ERROR_SUCCESS:
            return RDPBridgeDisconnectServer;
        default:
            return RDPBridgeDisconnectError;
    }
}

static DWORD WINAPI rdp_event_loop(LPVOID arg) {
    RDPBridgeSession *session = (RDPBridgeSession *)arg;
    HANDLE events[64] = { 0 };

    if (!freerdp_connect(session->instance)) {
        UINT32 code = freerdp_get_last_error(session->instance->context);
        // TLS connect 단계 실패(인증서 거부/사용자 중단 아님)면 TLS 사다리의 다음
        // 단계로 인스턴스를 다시 만들어 단계마다 한 번 재시도한다: FreeRDP 기본값
        // → 3.26 의 이전 기본값(TLS 1.0+, SECLEVEL 1) → 레거시-호환(TLS 1.0~1.2 +
        // SECLEVEL 0). 3.26 에서 붙던 호스트가 그보다 약한 설정으로 붙지 않게
        // 하고, Entra 하드닝 Azure VM 과 레거시 Windows 호스트는 마지막 단계가 흡수.
        while ((code == FREERDP_ERROR_TLS_CONNECT_FAILED) &&
               !session->certificate_rejected && !session->stop_requested &&
               (session->tls_stage < RDPBridgeTLSStageLegacy) && session->retry_options_valid) {
            session->tls_stage++;
            if (session->tls_stage == RDPBridgeTLSStagePrevious) {
                bridge_logf(session, "FreeRDP TLS connect failed [0x%08x]; rebuilding with previous-default TLS (1.0+, SECLEVEL 1) and retrying.", code);
            } else {
                bridge_logf(session, "FreeRDP TLS connect failed [0x%08x]; rebuilding with legacy-compatible TLS (1.0-1.2, SECLEVEL 0) and retrying.", code);
            }
            // Serialize the instance free/rebuild against a concurrent
            // bridge_disconnect abort (both touch session->instance).
            EnterCriticalSection(&session->instance_lock);
            freerdp_context_free(session->instance);
            freerdp_free(session->instance);
            session->instance = NULL;
            RDPBridgeStatus rebuild = bridge_build_instance(session, &session->retry_options, session->tls_stage);
            LeaveCriticalSection(&session->instance_lock);
            // If a disconnect raced in during the rebuild, don't start a new
            // connect — let the failure path run and the thread unwind.
            if ((rebuild != RDPBridgeStatusOK) || session->stop_requested) {
                break;
            }
            if (freerdp_connect(session->instance)) {
                goto connected;
            }
            code = freerdp_get_last_error(session->instance->context);
        }
        const char *description = freerdp_get_last_error_string(code);
        session->last_error_code = code;
        // A local disconnect that raced the connect (incl. the TLS-1.2 retry
        // bailed via bridge_pre_connect) is NOT a real failure — report it as a
        // local request with no failure callback so no spurious error surfaces.
        if (session->stop_requested) {
            bridge_log(session, "FreeRDP connect aborted by local disconnect request.");
            session->connected = false;
            bridge_disconnect_event(session, RDPBridgeDisconnectLocalRequest, code);
            return 1;
        }
        bridge_logf(session, "FreeRDP connect failed: %s [0x%08x].", description, code);
        bridge_failure(session, bridge_failure_kind_for_error(session, code), code, description);
        session->connected = false;
        bridge_disconnect_event(session, RDPBridgeDisconnectError, code);
        return 1;
    }

connected:
    session->connected = true;
    bridge_attach_cliprdr(session);
    bridge_log(session, "FreeRDP connected.");
    bridge_logf(session, "Output suppression server support=%s.",
        rdp_bridge_supports_output_suppression(session) ? "yes" : "no");
    bridge_logf(
        session,
        "FreeRDP runtime: version=%s revision=%s GFX_H264=%s.",
        freerdp_get_version_string(),
        freerdp_get_build_revision(),
        bridge_build_flag("WITH_GFX_H264"));
    bridge_logf(
        session,
        "Network auto-detect: %s.",
        freerdp_settings_get_bool(session->instance->context->settings, FreeRDP_NetworkAutoDetect) ? "requested" : "off");

    while (!session->stop_requested && !freerdp_shall_disconnect_context(session->instance->context)) {
        DWORD count = freerdp_get_event_handles(session->instance->context, events, 64);
        if (count == 0) {
            break;
        }

        DWORD status = WaitForMultipleObjects(count, events, FALSE, 50);
        if (status == WAIT_FAILED) {
            session->last_error_code = GetLastError();
            break;
        }

        if (!freerdp_check_event_handles(session->instance->context)) {
            session->last_error_code = freerdp_get_last_error(session->instance->context);
            break;
        }
    }

    UINT32 code = freerdp_get_last_error(session->instance->context);
    if (code == FREERDP_ERROR_SUCCESS) {
        const int ultimatum = freerdp_get_disconnect_ultimatum(session->instance->context);
        code = ultimatum > 0 ? (UINT32)ultimatum : session->last_error_code;
    }
    const RDPBridgeDisconnectKind disconnect_kind = bridge_disconnect_kind_for_error(session, code);
    if ((disconnect_kind == RDPBridgeDisconnectError) && !session->stop_requested) {
        bridge_failure(session, bridge_failure_kind_for_error(session, code), code, freerdp_get_last_error_string(code));
    }
    freerdp_disconnect(session->instance);
    session->connected = false;
    bridge_log_graphics_summary(session);
    if (session->netchar_result_count > 0) {
        bridge_logf(
            session,
            "Network auto-detect summary: results=%u last baseRTT=%ums averageRTT=%ums bandwidth=%ukbps (bandwidthPresent=%s; absent means this result carries no bandwidth, zero is not a measured zero-throughput link).",
            session->netchar_result_count,
            session->last_netchar.baseRTTMs,
            session->last_netchar.averageRTTMs,
            session->last_netchar.bandwidthKbps,
            session->last_netchar.hasBandwidth ? "yes" : "no");
    }
    bridge_log(session, "FreeRDP disconnected.");
    bridge_disconnect_event(session, disconnect_kind, code);
    return 0;
}

// OpenSSL/FreeRDP TLS protocol version values (== OpenSSL TLS1_VERSION /
// TLS1_2_VERSION). Defined locally to avoid pulling an OpenSSL header in.
#define RDP_BRIDGE_TLS1_0_VERSION 0x0301
#define RDP_BRIDGE_TLS1_2_VERSION 0x0303

static char *bridge_strdup_or_null(const char *value) {
    return (value != NULL) ? strdup(value) : NULL;
}

static void bridge_free_retry_options(RDPBridgeSession *session) {
    if ((session == NULL) || !session->retry_options_valid) {
        return;
    }
    free((void *)session->retry_options.host);
    free((void *)session->retry_options.username);
    free((void *)session->retry_options.password);
    free((void *)session->retry_options.domain);
    free((void *)session->retry_options.redirectedFolderPath);
    free((void *)session->retry_options.redirectedFolderName);
    free((void *)session->retry_options.logLevel);
    free((void *)session->retry_options.logFilters);
    memset(&session->retry_options, 0, sizeof(session->retry_options));
    session->retry_options_valid = false;
}

// Deep-copy the connection options (owning every string) so the TLS-1.2 retry
// can rebuild the FreeRDP instance even after the caller's options have gone.
// Returns false (and reclaims any partial copy) if any strdup fails, so the
// retry never runs with NULL host/credentials/redirect fields on OOM.
static bool bridge_store_retry_options(RDPBridgeSession *session, const RDPBridgeConnectionOptions *options) {
    bridge_free_retry_options(session);
    RDPBridgeConnectionOptions copy = *options; // scalars first
    copy.host = bridge_strdup_or_null(options->host);
    copy.username = bridge_strdup_or_null(options->username);
    copy.password = bridge_strdup_or_null(options->password);
    copy.domain = bridge_strdup_or_null(options->domain);
    copy.redirectedFolderPath = bridge_strdup_or_null(options->redirectedFolderPath);
    copy.redirectedFolderName = bridge_strdup_or_null(options->redirectedFolderName);
    copy.logLevel = bridge_strdup_or_null(options->logLevel);
    copy.logFilters = bridge_strdup_or_null(options->logFilters);
    session->retry_options = copy;
    session->retry_options_valid = true; // so bridge_free_retry_options can reclaim
    // A non-NULL source that produced a NULL copy means strdup failed → bail.
    const bool dup_failed =
        (options->host && !copy.host) ||
        (options->username && !copy.username) ||
        (options->password && !copy.password) ||
        (options->domain && !copy.domain) ||
        (options->redirectedFolderPath && !copy.redirectedFolderPath) ||
        (options->redirectedFolderName && !copy.redirectedFolderName) ||
        (options->logLevel && !copy.logLevel) ||
        (options->logFilters && !copy.logFilters);
    if (dup_failed) {
        bridge_free_retry_options(session);
        return false;
    }
    return true;
}

// Apply the TLS profile for `stage` (see RDPBridgeTLSStage) on top of the
// settings configure_instance produced. Later stages are only used after the
// earlier ones have already failed at the TLS stage:
//   - Default: FreeRDP's own defaults (3.27+: TLS >= 1.2, SECLEVEL 2).
//   - Previous: FreeRDP 3.26's defaults (TLS >= 1.0, SECLEVEL 1), so a host that
//     connected on the first attempt before 3.27 connects with the same policy.
//   - Legacy: TLS protocol window 1.0 .. 1.2 (capping the max at 1.2 absorbs
//     servers that reject TLS 1.3/SCHANNEL, e.g. an Entra-hardened Azure VM) and
//     OpenSSL security level 0, so a legacy self-signed RDP cert (SHA-1 /
//     RSA-1024) or a cipher OpenSSL 3 disables at SECLEVEL>=1 is accepted. This
//     is the same tradeoff mstsc makes for old servers.
// All-or-nothing: a partial apply would connect under a TLS policy that is
// none of the intended profiles, so any setter failure returns FALSE.
static BOOL bridge_apply_tls_stage(rdpSettings *settings, RDPBridgeTLSStage stage) {
    switch (stage) {
        case RDPBridgeTLSStageDefault:
            return TRUE;
        case RDPBridgeTLSStagePrevious:
            return freerdp_settings_set_uint16(settings, FreeRDP_TLSMinVersion, RDP_BRIDGE_TLS1_0_VERSION) &&
                   freerdp_settings_set_uint32(settings, FreeRDP_TlsSecLevel, 1);
        case RDPBridgeTLSStageLegacy:
            // Also widen the (TLS<=1.2) cipher list to the SECLEVEL-0 default so a
            // legacy server whose only mutually-acceptable suite OpenSSL 3 drops at
            // the default cipher string can still be selected. SSL_CTX_set_cipher_list
            // governs TLS 1.2 and below — exactly the window this stage uses.
            return freerdp_settings_set_uint16(settings, FreeRDP_TLSMinVersion, RDP_BRIDGE_TLS1_0_VERSION) &&
                   freerdp_settings_set_uint16(settings, FreeRDP_TLSMaxVersion, RDP_BRIDGE_TLS1_2_VERSION) &&
                   freerdp_settings_set_uint32(settings, FreeRDP_TlsSecLevel, 0) &&
                   freerdp_settings_set_string(settings, FreeRDP_AllowedTlsCiphers, "DEFAULT@SECLEVEL=0");
        default:
            return FALSE;
    }
}

// Build (or rebuild) the FreeRDP instance from `options` with the TLS profile
// for `tls_stage`. On any failure the partial instance is freed and
// session->instance is NULL.
static RDPBridgeStatus bridge_build_instance(RDPBridgeSession *session,
                                             const RDPBridgeConnectionOptions *options,
                                             RDPBridgeTLSStage tls_stage) {
    session->instance = freerdp_new();
    if (session->instance == NULL) {
        return RDPBridgeStatusInternalError;
    }
    session->instance->ContextSize = sizeof(RDPBridgeContext);
    session->instance->PreConnect = bridge_pre_connect;
    session->instance->PostConnect = bridge_post_connect;
    session->instance->PostDisconnect = bridge_post_disconnect;
    session->instance->LoadChannels = bridge_load_channels;
    session->last_error_code = FREERDP_ERROR_SUCCESS;
    session->certificate_rejected = FALSE;
    if (!freerdp_context_new(session->instance)) {
        freerdp_free(session->instance);
        session->instance = NULL;
        return RDPBridgeStatusInternalError;
    }
    ((RDPBridgeContext *)session->instance->context)->session = session;
    if (!configure_instance(session, options)) {
        freerdp_context_free(session->instance);
        freerdp_free(session->instance);
        session->instance = NULL;
        return RDPBridgeStatusInvalidArgument;
    }
    if (!bridge_apply_tls_stage(session->instance->context->settings, tls_stage)) {
        bridge_log(session, "RDP TLS fallback: failed to apply TLS settings for retry stage; aborting retry.");
        freerdp_context_free(session->instance);
        freerdp_free(session->instance);
        session->instance = NULL;
        return RDPBridgeStatusInternalError;
    }
    if (tls_stage == RDPBridgeTLSStagePrevious) {
        bridge_log(session, "RDP TLS fallback: retrying with TLS 1.0+, OpenSSL security level 1 (FreeRDP 3.26 defaults).");
    } else if (tls_stage == RDPBridgeTLSStageLegacy) {
        bridge_log(session, "RDP TLS fallback: retrying with TLS 1.0-1.2, OpenSSL security level 0, cipher list DEFAULT@SECLEVEL=0 (legacy-compatible).");
    }
    return RDPBridgeStatusOK;
}
#endif

#if defined(RDP_FREERDP_REAL)
static BOOL CALLBACK bridge_format_freerdp_version(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once;
    (void)context;
    snprintf((char *)parameter, 64, "%s (%s)", freerdp_get_version_string(), freerdp_get_build_revision());
    return TRUE;
}
#endif

bool rdp_bridge_tls_settings_for_stage(RDPBridgeTLSStage stage, RDPBridgeTLSSettings *out) {
    if (out == NULL) {
        return false;
    }
    memset(out, 0, sizeof(*out));
#if defined(RDP_FREERDP_REAL)
    rdpSettings *settings = freerdp_settings_new(0);
    if (settings == NULL) {
        return false;
    }
    const BOOL ok = bridge_apply_tls_stage(settings, stage);
    if (ok) {
        out->minVersion = freerdp_settings_get_uint16(settings, FreeRDP_TLSMinVersion);
        out->maxVersion = freerdp_settings_get_uint16(settings, FreeRDP_TLSMaxVersion);
        out->secLevel = freerdp_settings_get_uint32(settings, FreeRDP_TlsSecLevel);
        const char *ciphers = freerdp_settings_get_string(settings, FreeRDP_AllowedTlsCiphers);
        if (ciphers != NULL) {
            snprintf(out->allowedCiphers, sizeof(out->allowedCiphers), "%s", ciphers);
        }
    }
    freerdp_settings_free(settings);
    return ok;
#else
    (void)stage;
    return false;
#endif
}

bool rdp_bridge_pointer_to_bgra(
    uint32_t width,
    uint32_t height,
    uint32_t xorBpp,
    const uint8_t *xorMask,
    uint32_t xorMaskLength,
    const uint8_t *andMask,
    uint32_t andMaskLength,
    uint8_t *bgra) {
    if ((bgra == NULL) || (width == 0) || (height == 0) || (xorBpp == 8)) {
        return false;
    }
#if defined(RDP_FREERDP_REAL)
    rdpPointer pointer = { 0 };
    pointer.width = width;
    pointer.height = height;
    pointer.xorBpp = xorBpp;
    pointer.xorMaskData = (BYTE *)xorMask;
    pointer.lengthXorMask = xorMaskLength;
    pointer.andMaskData = (BYTE *)andMask;
    pointer.lengthAndMask = andMaskLength;
    return bridge_pointer_to_bgra(&pointer, NULL, bgra);
#else
    (void)xorMask;
    (void)xorMaskLength;
    (void)andMask;
    (void)andMaskLength;
    return false;
#endif
}

const char *rdp_bridge_freerdp_version(void) {
#if defined(RDP_FREERDP_REAL)
    static char version[64];
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    if (InitOnceExecuteOnce(&once, bridge_format_freerdp_version, version, NULL)) {
        return version;
    }
    return freerdp_get_version_string();
#else
    return "unavailable";
#endif
}

RDPBridgeStatus rdp_bridge_connect(RDPBridgeSession *session, const RDPBridgeConnectionOptions *options) {
    if ((session == NULL) || (options == NULL) || (options->host == NULL) || (strlen(options->host) == 0)) {
        return RDPBridgeStatusInvalidArgument;
    }

#if defined(RDP_FREERDP_REAL)
    // Reject while a session is still active. Check the worker thread too: a
    // failed TLS-1.2 retry rebuild leaves instance == NULL while the thread is
    // still unwinding, until bridge_disconnect reaps it.
    if ((session->instance != NULL) || (session->thread != NULL)) {
        return RDPBridgeStatusInvalidArgument;
    }

    // Stash a deep copy of the options so the event loop can rebuild the
    // instance and retry with TLS 1.2 if the first connect fails at TLS connect.
    session->tls_stage = RDPBridgeTLSStageDefault;
    if (!bridge_store_retry_options(session, options)) {
        return RDPBridgeStatusInternalError;
    }

    RDPBridgeStatus build = bridge_build_instance(session, options, RDPBridgeTLSStageDefault);
    if (build != RDPBridgeStatusOK) {
        bridge_free_retry_options(session);
        return build;
    }

    session->stop_requested = false;
    bridge_reset_graphics_diagnostics(session);
    session->thread = CreateThread(NULL, 0, rdp_event_loop, session, 0, NULL);
    if (session->thread == NULL) {
        freerdp_context_free(session->instance);
        freerdp_free(session->instance);
        session->instance = NULL;
        bridge_free_retry_options(session);
        return RDPBridgeStatusInternalError;
    }
    return RDPBridgeStatusOK;
#elif defined(RDP_FREERDP_STUB)
    session->connected = true;
    bridge_log(session, "FreeRDP stub backend connected. Link real FreeRDP in FreeRDPBridge.c.");
    return RDPBridgeStatusOK;
#else
    return RDPBridgeStatusBackendUnavailable;
#endif
}

RDPBridgeStatus rdp_bridge_disconnect(RDPBridgeSession *session) {
#if defined(RDP_FREERDP_REAL)
    return bridge_disconnect(session, 5000);
#else
    if (session == NULL) {
        return RDPBridgeStatusInvalidArgument;
    }
    session->connected = false;
    return RDPBridgeStatusOK;
#endif
}

#if defined(RDP_FREERDP_REAL)
static RDPBridgeStatus bridge_disconnect(RDPBridgeSession *session, DWORD wait_timeout) {
    if (session == NULL) {
        return RDPBridgeStatusInvalidArgument;
    }

    session->stop_requested = true;
    // Lock around the instance deref so it can't race the retry path's
    // free/rebuild of session->instance in the worker thread.
    EnterCriticalSection(&session->instance_lock);
    if ((session->instance != NULL) && (session->instance->context != NULL)) {
        freerdp_abort_connect_context(session->instance->context);
    }
    LeaveCriticalSection(&session->instance_lock);
    if (session->thread != NULL) {
        DWORD wait_status = WaitForSingleObject(session->thread, wait_timeout);
        if (wait_status == WAIT_TIMEOUT) {
            bridge_log(session, "FreeRDP disconnect timed out while waiting for the event loop thread.");
            return RDPBridgeStatusInternalError;
        }
        if (wait_status != WAIT_OBJECT_0) {
            bridge_log(session, "FreeRDP disconnect failed while waiting for the event loop thread.");
            return RDPBridgeStatusInternalError;
        }
        CloseHandle(session->thread);
        session->thread = NULL;
    }
    if (session->instance != NULL) {
        freerdp_context_free(session->instance);
        freerdp_free(session->instance);
        session->instance = NULL;
    }
    free(session->local_text);
    session->local_text = NULL;
    session->local_text_length = 0;
    bridge_clear_local_files(session);
    bridge_free_retry_options(session);
    session->disp = NULL;
    session->cliprdr = NULL;
    session->connected = false;
    return RDPBridgeStatusOK;
}
#endif

bool rdp_bridge_is_connected(const RDPBridgeSession *session) {
    return (session != NULL) && session->connected;
}

RDPBridgeStatus rdp_bridge_send_local_text(RDPBridgeSession *session, const uint8_t *utf8, size_t length) {
    if ((session == NULL) || ((utf8 == NULL) && (length > 0))) {
        return RDPBridgeStatusInvalidArgument;
    }
    if (!session->connected) {
        return RDPBridgeStatusNotConnected;
    }

#if defined(RDP_FREERDP_REAL)
    if (session->cliprdr == NULL) {
        return RDPBridgeStatusNotConnected;
    }
    bridge_clear_local_files(session);
    free(session->local_text);
    session->local_text = NULL;
    session->local_text_length = length;
    if (length > 0) {
        session->local_text = (char *)malloc(length + 1);
        if (session->local_text == NULL) {
            return RDPBridgeStatusInternalError;
        }
        memcpy(session->local_text, utf8, length);
        session->local_text[length] = '\0';
    }

    if (bridge_send_client_format_list(session) != CHANNEL_RC_OK) {
        return RDPBridgeStatusInternalError;
    }
    return RDPBridgeStatusOK;
#elif defined(RDP_FREERDP_STUB)
    if (session->callbacks.remoteText != NULL) {
        session->callbacks.remoteText(utf8, length, session->callbacks.context);
    }
    return RDPBridgeStatusOK;
#else
    return RDPBridgeStatusBackendUnavailable;
#endif
}

RDPBridgeStatus rdp_bridge_send_local_file_list(RDPBridgeSession *session, const uint8_t *payload, size_t length) {
    if ((session == NULL) || ((payload == NULL) && (length > 0))) {
        return RDPBridgeStatusInvalidArgument;
    }
    if (!session->connected) {
        return RDPBridgeStatusNotConnected;
    }

#ifdef RDP_FREERDP_STUB
    if (session->callbacks.remoteFileList != NULL) {
        session->callbacks.remoteFileList(payload, length, session->callbacks.context);
    }
    return RDPBridgeStatusOK;
#else
    return RDPBridgeStatusBackendUnavailable;
#endif
}

RDPBridgeStatus rdp_bridge_send_local_files(
    RDPBridgeSession *session,
    const RDPBridgeLocalFile *files,
    size_t count) {
    if ((session == NULL) || ((files == NULL) && (count > 0))) {
        return RDPBridgeStatusInvalidArgument;
    }
    if (!session->connected) {
        return RDPBridgeStatusNotConnected;
    }

#if defined(RDP_FREERDP_REAL)
    if (session->cliprdr == NULL) {
        return RDPBridgeStatusNotConnected;
    }
    free(session->local_text);
    session->local_text = NULL;
    session->local_text_length = 0;
    bridge_clear_local_files(session);
    if (count > 0) {
        session->local_files = (RDPBridgeLocalFile *)calloc(count, sizeof(RDPBridgeLocalFile));
        if (session->local_files == NULL) {
            return RDPBridgeStatusInternalError;
        }
        session->local_file_count = count;

        for (size_t index = 0; index < count; index++) {
            if ((files[index].path == NULL) || (files[index].fileName == NULL)) {
                bridge_clear_local_files(session);
                return RDPBridgeStatusInvalidArgument;
            }
            session->local_files[index].path = strdup(files[index].path);
            session->local_files[index].fileName = strdup(files[index].fileName);
            session->local_files[index].size = files[index].size;
            if ((session->local_files[index].path == NULL) || (session->local_files[index].fileName == NULL)) {
                bridge_clear_local_files(session);
                return RDPBridgeStatusInternalError;
            }
        }
    }

    if (bridge_send_client_format_list(session) != CHANNEL_RC_OK) {
        return RDPBridgeStatusInternalError;
    }
    return RDPBridgeStatusOK;
#elif defined(RDP_FREERDP_STUB)
    (void)files;
    (void)count;
    return RDPBridgeStatusOK;
#else
    return RDPBridgeStatusBackendUnavailable;
#endif
}

RDPBridgeStatus rdp_bridge_request_remote_file_contents(
    RDPBridgeSession *session,
    uint32_t stream_id,
    uint64_t offset,
    uint32_t length) {
    return rdp_bridge_request_remote_file_range(session, stream_id, 0, offset, length);
}

RDPBridgeStatus rdp_bridge_request_remote_file_range(
    RDPBridgeSession *session,
    uint32_t stream_id,
    uint32_t list_index,
    uint64_t offset,
    uint32_t length) {
    if ((session == NULL) || (length == 0)) {
        return RDPBridgeStatusInvalidArgument;
    }
    if (!session->connected) {
        return RDPBridgeStatusNotConnected;
    }

#if defined(RDP_FREERDP_REAL)
    if ((session->cliprdr == NULL) || (session->cliprdr->ClientFileContentsRequest == NULL)) {
        return RDPBridgeStatusNotConnected;
    }

    CLIPRDR_FILE_CONTENTS_REQUEST request = { 0 };
    request.common.msgType = CB_FILECONTENTS_REQUEST;
    request.streamId = stream_id;
    request.listIndex = list_index;
    request.dwFlags = FILECONTENTS_RANGE;
    request.nPositionLow = (UINT32)(offset & 0xFFFFFFFF);
    request.nPositionHigh = (UINT32)(offset >> 32);
    request.cbRequested = length;

    if (session->cliprdr->ClientFileContentsRequest(session->cliprdr, &request) != CHANNEL_RC_OK) {
        return RDPBridgeStatusInternalError;
    }
    return RDPBridgeStatusOK;
#else
    (void)stream_id;
    (void)list_index;
    (void)offset;
    (void)length;
    return RDPBridgeStatusBackendUnavailable;
#endif
}

RDPBridgeStatus rdp_bridge_update_desktop_size(RDPBridgeSession *session, uint32_t width, uint32_t height, double scale) {
    if ((session == NULL) || (width == 0) || (height == 0)) {
        return RDPBridgeStatusInvalidArgument;
    }
    if (!session->connected) {
        return RDPBridgeStatusNotConnected;
    }

#if defined(RDP_FREERDP_REAL)
    session->desktop_width = width;
    session->desktop_height = height;
    session->desktop_scale = scale;
    if (session->instance != NULL) {
        rdpSettings *settings = session->instance->context->settings;
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, width);
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, height);
    }

    if ((session->disp != NULL) && (session->disp->SendMonitorLayout != NULL)) {
        UINT32 scale_factor = (UINT32)(scale * 100.0);
        if (scale_factor < 100) {
            scale_factor = 100;
        }
        DISPLAY_CONTROL_MONITOR_LAYOUT monitor = { 0 };
        monitor.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
        monitor.Left = 0;
        monitor.Top = 0;
        monitor.Width = width;
        monitor.Height = height;
        monitor.PhysicalWidth = width;
        monitor.PhysicalHeight = height;
        monitor.Orientation = 0;
        monitor.DesktopScaleFactor = scale_factor;
        monitor.DeviceScaleFactor = 100;
        UINT status = session->disp->SendMonitorLayout(session->disp, 1, &monitor);
        if (status == CHANNEL_RC_OK) {
            bridge_logf(session, "Display resize sent: %ux%u scale=%u.", width, height, scale_factor);
        } else {
            bridge_logf(session, "Display resize failed: %ux%u scale=%u status=%u.", width, height, scale_factor, status);
            return RDPBridgeStatusInternalError;
        }
    } else {
        bridge_logf(session, "Display resize deferred without display channel: %ux%u scale=%.2f.", width, height, scale);
    }
    return RDPBridgeStatusOK;
#elif defined(RDP_FREERDP_STUB)
    bridge_log(session, "FreeRDP stub backend accepted desktop resize.");
    return RDPBridgeStatusOK;
#else
    return RDPBridgeStatusBackendUnavailable;
#endif
}

bool rdp_bridge_supports_output_suppression(RDPBridgeSession *session) {
#if defined(RDP_FREERDP_REAL)
    return session && session->connected && session->instance && session->instance->context &&
        freerdp_settings_get_bool(session->instance->context->settings, FreeRDP_SuppressOutput);
#else
    (void)session;
    return false;
#endif
}

RDPBridgeStatus rdp_bridge_set_output_suppressed(RDPBridgeSession *session, bool suppressed) {
    if (session == NULL) {
        return RDPBridgeStatusInvalidArgument;
    }
    if (!session->connected) {
        return RDPBridgeStatusNotConnected;
    }
#if defined(RDP_FREERDP_REAL)
    if ((session->instance == NULL) || (session->instance->context == NULL) || (session->instance->context->gdi == NULL)) {
        return RDPBridgeStatusNotConnected;
    }
    // FreeRDP mutates local GDI even when the server capability makes the PDU a no-op.
    if (suppressed && !rdp_bridge_supports_output_suppression(session)) {
        bridge_logf(session, "Output suppression unsupported; leaving local output enabled.");
        return RDPBridgeStatusBackendUnavailable;
    }
    if (session->instance->context->gdi->suppressOutput == suppressed) {
        return RDPBridgeStatusOK;
    }
    if (!gdi_send_suppress_output(session->instance->context->gdi, suppressed ? TRUE : FALSE)) {
        bridge_logf(session, "Output suppression %s failed.", suppressed ? "request" : "release");
        return RDPBridgeStatusInternalError;
    }
    // Resume sends AllowDisplayUpdates, but does not flush GFX invalid regions itself.
    // Request a full repaint so an otherwise idle desktop cannot remain stale.
    if (!suppressed && freerdp_settings_get_bool(session->instance->context->settings, FreeRDP_RefreshRect)) {
        rdpContext *context = session->instance->context;
        const UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
        const UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
        const RECTANGLE_16 rect = { 0, 0, (UINT16)(width - 1), (UINT16)(height - 1) };
        if (!context->update->RefreshRect(context, 1, &rect)) {
            return RDPBridgeStatusInternalError;
        }
    }
    bridge_logf(
        session,
        "Output suppression %s (server support=%s).",
        suppressed ? "requested" : "released",
        freerdp_settings_get_bool(session->instance->context->settings, FreeRDP_SuppressOutput) ? "yes" : "no");
#else
    (void)suppressed;
#endif
    return RDPBridgeStatusOK;
}

#if defined(RDP_FREERDP_REAL)
// Called inside the input API's existing session-lock transaction. Never hop to
// main here: Allow + RefreshRect must be queued before input on this thread.
static RDPBridgeStatus bridge_release_output_for_input(RDPBridgeSession *session) {
    if (!session->instance->context->gdi || !session->instance->context->gdi->suppressOutput) {
        return RDPBridgeStatusOK;
    }
    RDPBridgeStatus status = rdp_bridge_set_output_suppressed(session, false);
    // Allow may succeed even when RefreshRect fails. Report the actual wire state.
    if (!session->instance->context->gdi->suppressOutput && session->callbacks.outputResumedForInput) {
        session->callbacks.outputResumedForInput(session->callbacks.context);
    }
    return status;
}
#endif

RDPBridgeStatus rdp_bridge_send_pointer_move(RDPBridgeSession *session, uint32_t x, uint32_t y) {
    if (session == NULL) {
        return RDPBridgeStatusInvalidArgument;
    }
    if (!session->connected) {
        return RDPBridgeStatusNotConnected;
    }
#if defined(RDP_FREERDP_REAL)
    if ((session->instance == NULL) || (session->instance->context == NULL) || (session->instance->context->input == NULL)) {
        return RDPBridgeStatusNotConnected;
    }
    if (!freerdp_input_send_mouse_event(session->instance->context->input, PTR_FLAGS_MOVE, (UINT16)x, (UINT16)y)) {
        return RDPBridgeStatusInternalError;
    }
#else
    (void)x;
    (void)y;
#endif
    return RDPBridgeStatusOK;
}

RDPBridgeStatus rdp_bridge_send_pointer_button(
    RDPBridgeSession *session,
    uint32_t x,
    uint32_t y,
    RDPBridgePointerButton button,
    bool pressed) {
    if (session == NULL) {
        return RDPBridgeStatusInvalidArgument;
    }
    if (!session->connected) {
        return RDPBridgeStatusNotConnected;
    }
#if defined(RDP_FREERDP_REAL)
    if ((session->instance == NULL) || (session->instance->context == NULL) || (session->instance->context->input == NULL)) {
        return RDPBridgeStatusNotConnected;
    }
    RDPBridgeStatus status = bridge_release_output_for_input(session);
    if (status != RDPBridgeStatusOK) return status;
    UINT16 flags = pressed ? PTR_FLAGS_DOWN : 0;
    switch (button) {
        case RDPBridgePointerButtonLeft:
            flags |= PTR_FLAGS_BUTTON1;
            break;
        case RDPBridgePointerButtonRight:
            flags |= PTR_FLAGS_BUTTON2;
            break;
        case RDPBridgePointerButtonMiddle:
            flags |= PTR_FLAGS_BUTTON3;
            break;
    }
    if (!freerdp_input_send_mouse_event(session->instance->context->input, flags, (UINT16)x, (UINT16)y)) {
        return RDPBridgeStatusInternalError;
    }
#else
    (void)x;
    (void)y;
    (void)button;
    (void)pressed;
#endif
    return RDPBridgeStatusOK;
}

RDPBridgeStatus rdp_bridge_send_scroll_at(
    RDPBridgeSession *session,
    uint32_t x,
    uint32_t y,
    int32_t delta_x,
    int32_t delta_y) {
    if (session == NULL) {
        return RDPBridgeStatusInvalidArgument;
    }
    if (!session->connected) {
        return RDPBridgeStatusNotConnected;
    }
#if defined(RDP_FREERDP_REAL)
    if ((session->instance == NULL) || (session->instance->context == NULL) || (session->instance->context->input == NULL)) {
        return RDPBridgeStatusNotConnected;
    }
    if (delta_x != 0 || delta_y != 0) {
        RDPBridgeStatus status = bridge_release_output_for_input(session);
        if (status != RDPBridgeStatusOK) return status;
    }
    if (delta_y != 0) {
        UINT16 flags = PTR_FLAGS_WHEEL | ((uint32_t)(delta_y < 0 ? -(int64_t)delta_y : (int64_t)delta_y) & WheelRotationMask);
        if (delta_y < 0) {
            flags |= PTR_FLAGS_WHEEL_NEGATIVE;
        }
        if (!freerdp_input_send_mouse_event(session->instance->context->input, flags, (UINT16)x, (UINT16)y)) {
            return RDPBridgeStatusInternalError;
        }
    }
    if (delta_x != 0) {
        UINT16 flags = PTR_FLAGS_HWHEEL | ((uint32_t)(delta_x < 0 ? -(int64_t)delta_x : (int64_t)delta_x) & WheelRotationMask);
        if (delta_x < 0) {
            flags |= PTR_FLAGS_WHEEL_NEGATIVE;
        }
        if (!freerdp_input_send_mouse_event(session->instance->context->input, flags, (UINT16)x, (UINT16)y)) {
            return RDPBridgeStatusInternalError;
        }
    }
#else
    (void)x;
    (void)y;
    (void)delta_x;
    (void)delta_y;
#endif
    return RDPBridgeStatusOK;
}

RDPBridgeStatus rdp_bridge_send_scroll(RDPBridgeSession *session, int32_t delta_x, int32_t delta_y) {
    return rdp_bridge_send_scroll_at(session, 0, 0, delta_x, delta_y);
}

RDPBridgeStatus rdp_bridge_send_key_ex(
    RDPBridgeSession *session,
    uint16_t key_code,
    bool pressed,
    bool extended) {
    if (session == NULL) {
        return RDPBridgeStatusInvalidArgument;
    }
    if (!session->connected) {
        return RDPBridgeStatusNotConnected;
    }
#if defined(RDP_FREERDP_REAL)
    if ((session->instance == NULL) || (session->instance->context == NULL) || (session->instance->context->input == NULL)) {
        return RDPBridgeStatusNotConnected;
    }
    RDPBridgeStatus status = bridge_release_output_for_input(session);
    if (status != RDPBridgeStatusOK) return status;
    if (!freerdp_input_send_keyboard_event_ex(
            session->instance->context->input,
            pressed ? TRUE : FALSE,
            FALSE,
            (uint32_t)key_code | (extended ? 0x100u : 0))) {
        return RDPBridgeStatusInternalError;
    }
#else
    (void)key_code;
    (void)pressed;
    (void)extended;
#endif
    return RDPBridgeStatusOK;
}

RDPBridgeStatus rdp_bridge_send_key(RDPBridgeSession *session, uint16_t key_code, bool pressed) {
    return rdp_bridge_send_key_ex(session, key_code, pressed, false);
}

// Send a character as a Unicode keyboard event (NumLock-independent). Used for the
// numeric keypad digits/decimal so they type regardless of the host's NumLock state:
// the RDP keypad SCANCODES (0x47-0x53) are NumLock-dependent and some servers (e.g.
// xrdp) ignore the lock-sync, leaving the keypad in navigation mode. Unicode input
// carries the character directly, so '0'-'9' and the locale decimal separator always
// type. `code` is the UTF-16 code unit. (CNDF numpad fix.)
RDPBridgeStatus rdp_bridge_send_unicode(RDPBridgeSession *session, uint16_t code, bool pressed) {
    if (session == NULL) {
        return RDPBridgeStatusInvalidArgument;
    }
    if (!session->connected) {
        return RDPBridgeStatusNotConnected;
    }
#if defined(RDP_FREERDP_REAL)
    if ((session->instance == NULL) || (session->instance->context == NULL) || (session->instance->context->input == NULL)) {
        return RDPBridgeStatusNotConnected;
    }
    RDPBridgeStatus status = bridge_release_output_for_input(session);
    if (status != RDPBridgeStatusOK) return status;
    // Press = absence of KBD_FLAGS_RELEASE; release = KBD_FLAGS_RELEASE.
    UINT16 flags = pressed ? 0 : KBD_FLAGS_RELEASE;
    if (!freerdp_input_send_unicode_keyboard_event(
            session->instance->context->input,
            flags,
            code)) {
        return RDPBridgeStatusInternalError;
    }
#else
    (void)code;
    (void)pressed;
#endif
    return RDPBridgeStatusOK;
}

use std::ffi::{c_char, c_void};
pub const CNDF_IRON_ABI_VERSION: u32 = 0;
pub const CNDF_IRON_CERT_CHAIN_UNTRUSTED: u32 = 0x1;
pub const CNDF_IRON_CERT_NAME_MISMATCH: u32 = 0x2;
pub const CNDF_IRON_CERT_EXPIRED: u32 = 0x4;
pub const CNDF_IRON_CERT_OTHER: u32 = 0x8;
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CNDFIronStatus {
    CNDF_IRON_OK = 0,
    CNDF_IRON_INVALID_ARGUMENT = 1,
    CNDF_IRON_NOT_CONNECTED = 2,
    CNDF_IRON_BUSY = 3,
    CNDF_IRON_CLOSED = 4,
    CNDF_IRON_INTERNAL = 5,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CNDFIronFailureKind {
    CNDF_IRON_FAILURE_NETWORK = 0,
    CNDF_IRON_FAILURE_TLS = 1,
    CNDF_IRON_FAILURE_AUTHENTICATION = 2,
    CNDF_IRON_FAILURE_CERTIFICATE = 3,
    CNDF_IRON_FAILURE_CONFIGURATION = 4,
    CNDF_IRON_FAILURE_ENGINE = 5,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CNDFIronStage {
    CNDF_IRON_STAGE_UNKNOWN = 0,
    CNDF_IRON_STAGE_INITIAL = 1,
    CNDF_IRON_STAGE_NEGOTIATION = 2,
    CNDF_IRON_STAGE_AUTHENTICATION = 3,
    CNDF_IRON_STAGE_CHANNEL_SETUP = 4,
    CNDF_IRON_STAGE_LICENSING = 5,
    CNDF_IRON_STAGE_CAPABILITIES = 6,
    CNDF_IRON_STAGE_FINALIZATION = 7,
    CNDF_IRON_STAGE_ACTIVE = 8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CNDFIronDisconnectKind {
    CNDF_IRON_DISCONNECT_LOCAL_REQUEST = 0,
    CNDF_IRON_DISCONNECT_SERVER = 1,
    CNDF_IRON_DISCONNECT_TIMEOUT = 2,
    CNDF_IRON_DISCONNECT_ERROR = 3,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CNDFIronPointerKind {
    CNDF_IRON_POINTER_IMAGE = 0,
    CNDF_IRON_POINTER_HIDDEN = 1,
    CNDF_IRON_POINTER_DEFAULT = 2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CNDFIronLogLevel {
    CNDF_IRON_LOG_TRACE = 0,
    CNDF_IRON_LOG_DEBUG = 1,
    CNDF_IRON_LOG_INFO = 2,
    CNDF_IRON_LOG_WARN = 3,
    CNDF_IRON_LOG_ERROR = 4,
    CNDF_IRON_LOG_FATAL = 5,
    CNDF_IRON_LOG_OFF = 6,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct CNDFIronRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CNDFIronCertificateChain {
    pub der: *const *const u8,
    pub der_length: *const usize,
    pub count: usize,
    pub hostname: *const c_char,
    pub port: u16,
    pub problems: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CNDFIronCallbacks {
    pub log: CNDFIronLogCallback,
    pub certificate_trust: CNDFIronCertificateTrustCallback,
    pub connected: CNDFIronConnectedCallback,
    pub failure: CNDFIronFailureCallback,
    pub disconnect: CNDFIronDisconnectCallback,
    pub frame: CNDFIronFrameCallback,
    pub pointer: CNDFIronPointerCallback,
    pub context: *mut c_void,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CNDFIronConnectOptions {
    pub struct_size: u32,
    pub host: *const c_char,
    pub port: u16,
    pub username: *const c_char,
    pub domain: *const c_char,
    pub desktop_width: u32,
    pub desktop_height: u32,
    pub scale_percent: u32,
    pub color_depth: u32,
    pub graphics_pipeline: bool,
    pub log_level: CNDFIronLogLevel,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CNDFIronInputKind {
    CNDF_IRON_INPUT_KEY = 0,
    CNDF_IRON_INPUT_UNICODE = 1,
    CNDF_IRON_INPUT_POINTER_MOVE = 2,
    CNDF_IRON_INPUT_POINTER_BUTTON = 3,
    CNDF_IRON_INPUT_WHEEL = 4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CNDFIronPointerButton {
    CNDF_IRON_BUTTON_LEFT = 0,
    CNDF_IRON_BUTTON_RIGHT = 1,
    CNDF_IRON_BUTTON_MIDDLE = 2,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CNDFIronInputEvent {
    pub kind: CNDFIronInputKind,
    pub code: u16,
    pub extended: bool,
    pub pressed: bool,
    pub button: CNDFIronPointerButton,
    pub x: u32,
    pub y: u32,
    pub delta_x: i32,
    pub delta_y: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct CNDFIronStatistics {
    pub updates_received: u64,
    pub dirty_bytes_composed: u64,
    pub frames_delivered: u64,
    pub frame_bytes_delivered: u64,
    pub input_events_sent: u64,
    pub input_busy: u64,
}

pub type CNDFIronLogCallback = Option<
    extern "C" fn(
        generation: u64,
        level: CNDFIronLogLevel,
        utf8: *const u8,
        length: usize,
        context: *mut c_void,
    ),
>;
pub type CNDFIronCertificateTrustCallback = Option<
    extern "C" fn(
        generation: u64,
        chain: *const CNDFIronCertificateChain,
        context: *mut c_void,
    ) -> bool,
>;
pub type CNDFIronConnectedCallback = Option<extern "C" fn(generation: u64, context: *mut c_void)>;
pub type CNDFIronFailureCallback = Option<
    extern "C" fn(
        generation: u64,
        kind: CNDFIronFailureKind,
        code: u32,
        stage: CNDFIronStage,
        utf8: *const u8,
        length: usize,
        context: *mut c_void,
    ),
>;
pub type CNDFIronDisconnectCallback = Option<
    extern "C" fn(generation: u64, kind: CNDFIronDisconnectKind, code: u32, context: *mut c_void),
>;
pub type CNDFIronFrameCallback = Option<
    extern "C" fn(
        generation: u64,
        bgra: *const u8,
        width: u32,
        height: u32,
        stride: u32,
        dirty: CNDFIronRect,
        sequence: u64,
        context: *mut c_void,
    ),
>;
pub type CNDFIronPointerCallback = Option<
    extern "C" fn(
        generation: u64,
        kind: CNDFIronPointerKind,
        bgra: *const u8,
        width: u32,
        height: u32,
        stride: u32,
        hot_x: u32,
        hot_y: u32,
        context: *mut c_void,
    ),
>;

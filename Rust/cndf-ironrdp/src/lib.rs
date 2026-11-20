#![allow(non_camel_case_types)]

mod abi;
#[cfg(feature = "stub")]
mod stub;

pub use abi::*;
use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use zeroize::Zeroizing;
use CNDFIronStatus::*;

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

fn ffi<T>(fallback: T, operation: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(operation)).unwrap_or(fallback)
}

struct Callbacks {
    table: CNDFIronCallbacks,
    gate: Mutex<()>,
    closed: AtomicBool,
}

// The caller keeps context alive through destroy and handles callbacks on worker threads.
unsafe impl Send for Callbacks {}
unsafe impl Sync for Callbacks {}

impl Callbacks {
    fn invoke<T>(&self, operation: impl FnOnce(CNDFIronCallbacks) -> T) -> Option<T> {
        let _gate = lock(&self.gate);
        if self.closed.load(Ordering::Acquire) {
            return None;
        }
        Some(operation(self.table))
    }

    fn failure(
        &self,
        generation: u64,
        kind: CNDFIronFailureKind,
        code: u32,
        stage: CNDFIronStage,
        message: &str,
    ) {
        self.invoke(|table| {
            if let Some(callback) = table.failure {
                callback(
                    generation,
                    kind,
                    code,
                    stage,
                    message.as_ptr(),
                    message.len(),
                    table.context,
                );
            }
        });
    }
}

struct Connection {
    generation: u64,
    connected: AtomicBool,
    stop: AtomicBool,
    callbacks: Arc<Callbacks>,
    statistics: Arc<Mutex<CNDFIronStatistics>>,
}

impl Connection {
    fn worker(&self, operation: impl FnOnce()) {
        if catch_unwind(AssertUnwindSafe(operation)).is_err() {
            self.connected.store(false, Ordering::Release);
            self.stop.store(true, Ordering::Release);
            self.callbacks.failure(
                self.generation,
                CNDFIronFailureKind::CNDF_IRON_FAILURE_ENGINE,
                0x49520001,
                CNDFIronStage::CNDF_IRON_STAGE_UNKNOWN,
                "IronRDP worker panicked",
            );
        }
    }
}

#[cfg_attr(feature = "stub", allow(dead_code))]
struct Options {
    host: String,
    port: u16,
    username: String,
    domain: Option<String>,
    width: u32,
    height: u32,
    scale: u32,
    depth: u32,
    graphics: bool,
    log_level: CNDFIronLogLevel,
    password: Zeroizing<String>,
}

#[cfg_attr(feature = "stub", allow(dead_code))]
enum Command {
    Input(Vec<CNDFIronInputEvent>, Instant),
    Resize(u32, u32, u32),
    Redeliver,
}

struct Run {
    connection: Arc<Connection>,
    commands: SyncSender<Command>,
    threads: Vec<JoinHandle<()>>,
}

#[derive(Default)]
struct State {
    generation: u64,
    run: Option<Run>,
}

pub struct CNDFIronSession {
    callbacks: Arc<Callbacks>,
    state: Mutex<State>,
    statistics: Arc<Mutex<CNDFIronStatistics>>,
}

impl CNDFIronSession {
    fn send(&self, generation: u64, mut command: Command, timeout: Duration) -> CNDFIronStatus {
        let deadline = Instant::now() + timeout;
        let (connection, commands) = {
            let state = lock(&self.state);
            let Some(run) = state.run.as_ref() else {
                return CNDF_IRON_NOT_CONNECTED;
            };
            (Arc::clone(&run.connection), run.commands.clone())
        };
        loop {
            if self.callbacks.closed.load(Ordering::Acquire) {
                return CNDF_IRON_CLOSED;
            }
            if connection.generation != generation
                || connection.stop.load(Ordering::Acquire)
                || !connection.connected.load(Ordering::Acquire)
            {
                return CNDF_IRON_NOT_CONNECTED;
            }
            match commands.try_send(command) {
                Ok(()) => return CNDF_IRON_OK,
                Err(TrySendError::Disconnected(_)) => return CNDF_IRON_NOT_CONNECTED,
                Err(TrySendError::Full(pending)) => command = pending,
            }
            if Instant::now() >= deadline {
                if matches!(command, Command::Input(..)) {
                    lock(&self.statistics).input_busy += 1;
                }
                return CNDF_IRON_BUSY;
            }
            thread::sleep(Duration::from_millis(1));
        }
    }
}

#[no_mangle]
pub extern "C" fn cndf_iron_abi_version() -> u32 {
    ffi(0, || CNDF_IRON_ABI_VERSION)
}

#[no_mangle]
pub extern "C" fn cndf_iron_version() -> *const c_char {
    ffi(ptr::null(), || {
        concat!(
            "cndf-ironrdp ",
            env!("CARGO_PKG_VERSION"),
            " ironrdp=15b4a03ff552 patches=0\0"
        )
        .as_ptr()
        .cast()
    })
}

#[no_mangle]
pub unsafe extern "C" fn cndf_iron_session_create(
    callbacks: *const CNDFIronCallbacks,
) -> *mut CNDFIronSession {
    ffi(ptr::null_mut(), || {
        let Some(&table) = callbacks.as_ref() else {
            return ptr::null_mut();
        };
        Box::into_raw(Box::new(CNDFIronSession {
            callbacks: Arc::new(Callbacks {
                table,
                gate: Mutex::new(()),
                closed: AtomicBool::new(false),
            }),
            state: Mutex::default(),
            statistics: Arc::default(),
        }))
    })
}

unsafe fn text(pointer: *const c_char) -> Option<String> {
    (!pointer.is_null())
        .then(|| CStr::from_ptr(pointer).to_str().ok().map(str::to_owned))
        .flatten()
}

fn dimensions(width: u32, height: u32) -> bool {
    (1..=8192).contains(&width) && (1..=8192).contains(&height)
}

#[no_mangle]
pub unsafe extern "C" fn cndf_iron_connect(
    session: *mut CNDFIronSession,
    options: *const CNDFIronConnectOptions,
    password_utf8: *const u8,
    password_length: usize,
    out_generation: *mut u64,
) -> CNDFIronStatus {
    ffi(CNDF_IRON_INTERNAL, || {
        let Some(session) = session.as_ref() else {
            return CNDF_IRON_INVALID_ARGUMENT;
        };
        if options.is_null()
            || out_generation.is_null()
            || options.cast::<u32>().read() < std::mem::size_of::<CNDFIronConnectOptions>() as u32
            || (password_utf8.is_null() && password_length != 0)
            || password_length > isize::MAX as usize
        {
            return CNDF_IRON_INVALID_ARGUMENT;
        }
        let options = &*options;
        let (Some(host), Some(username)) = (text(options.host), text(options.username)) else {
            return CNDF_IRON_INVALID_ARGUMENT;
        };
        let domain = text(options.domain);
        if host.is_empty()
            || options.port == 0
            || (!options.domain.is_null() && domain.is_none())
            || !dimensions(options.desktop_width, options.desktop_height)
            || options.scale_percent == 0
            || !matches!(options.color_depth, 16 | 24 | 32)
        {
            return CNDF_IRON_INVALID_ARGUMENT;
        }
        let password = if password_length == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(password_utf8, password_length)
        };
        let Ok(password) = std::str::from_utf8(password) else {
            return CNDF_IRON_INVALID_ARGUMENT;
        };
        let options = Options {
            host,
            port: options.port,
            username,
            domain,
            width: options.desktop_width,
            height: options.desktop_height,
            scale: options.scale_percent,
            depth: options.color_depth,
            graphics: options.graphics_pipeline,
            log_level: options.log_level,
            password: Zeroizing::new(password.to_owned()),
        };
        let mut state = lock(&session.state);
        if session.callbacks.closed.load(Ordering::Acquire) {
            return CNDF_IRON_CLOSED;
        }
        if state
            .run
            .as_ref()
            .is_some_and(|run| run.threads.iter().any(|thread| !thread.is_finished()))
        {
            return CNDF_IRON_BUSY;
        }
        if let Some(run) = state.run.take() {
            for thread in run.threads {
                let _ = thread.join();
            }
        }
        let generation = state.generation + 1;
        let connection = Arc::new(Connection {
            generation,
            connected: AtomicBool::new(false),
            stop: AtomicBool::new(false),
            callbacks: Arc::clone(&session.callbacks),
            statistics: Arc::clone(&session.statistics),
        });
        let (commands, incoming) = mpsc::sync_channel(128);
        let (start, ready) = mpsc::channel();
        let Ok(threads) = start_workers(Arc::clone(&connection), options, incoming, ready) else {
            return CNDF_IRON_INTERNAL;
        };
        state.generation = generation;
        state.run = Some(Run {
            connection,
            commands,
            threads,
        });
        out_generation.write(generation);
        let _ = start.send(());
        CNDF_IRON_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn cndf_iron_send_input(
    session: *mut CNDFIronSession,
    generation: u64,
    events: *const CNDFIronInputEvent,
    count: usize,
    timeout_ms: u32,
) -> CNDFIronStatus {
    ffi(CNDF_IRON_INTERNAL, || {
        let Some(session) = session.as_ref() else {
            return CNDF_IRON_INVALID_ARGUMENT;
        };
        if count > isize::MAX as usize / std::mem::size_of::<CNDFIronInputEvent>()
            || (count != 0 && events.is_null())
        {
            return CNDF_IRON_INVALID_ARGUMENT;
        }
        let events = if count == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(events, count).to_vec()
        };
        let timeout = Duration::from_millis(timeout_ms.into());
        session.send(
            generation,
            Command::Input(events, Instant::now() + timeout),
            timeout,
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn cndf_iron_resize(
    session: *mut CNDFIronSession,
    generation: u64,
    width: u32,
    height: u32,
    scale_percent: u32,
) -> CNDFIronStatus {
    ffi(CNDF_IRON_INTERNAL, || {
        let Some(session) = session.as_ref() else {
            return CNDF_IRON_INVALID_ARGUMENT;
        };
        if !dimensions(width, height) || scale_percent == 0 {
            return CNDF_IRON_INVALID_ARGUMENT;
        }
        session.send(
            generation,
            Command::Resize(width, height, scale_percent),
            Duration::ZERO,
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn cndf_iron_redeliver_frame(
    session: *mut CNDFIronSession,
    generation: u64,
) -> CNDFIronStatus {
    ffi(CNDF_IRON_INTERNAL, || {
        session
            .as_ref()
            .map_or(CNDF_IRON_INVALID_ARGUMENT, |session| {
                session.send(generation, Command::Redeliver, Duration::ZERO)
            })
    })
}

#[no_mangle]
pub unsafe extern "C" fn cndf_iron_is_connected(
    session: *const CNDFIronSession,
    generation: u64,
) -> bool {
    ffi(false, || {
        session.as_ref().is_some_and(|session| {
            lock(&session.state).run.as_ref().is_some_and(|run| {
                run.connection.generation == generation
                    && run.connection.connected.load(Ordering::Acquire)
                    && !run.connection.stop.load(Ordering::Acquire)
            })
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn cndf_iron_get_statistics(
    session: *const CNDFIronSession,
    out: *mut CNDFIronStatistics,
) -> bool {
    ffi(false, || {
        let (Some(session), Some(out)) = (session.as_ref(), out.as_mut()) else {
            return false;
        };
        *out = *lock(&session.statistics);
        true
    })
}

#[no_mangle]
pub unsafe extern "C" fn cndf_iron_disconnect(session: *mut CNDFIronSession) -> CNDFIronStatus {
    ffi(CNDF_IRON_INTERNAL, || {
        let Some(session) = session.as_ref() else {
            return CNDF_IRON_INVALID_ARGUMENT;
        };
        if let Some(run) = lock(&session.state).run.as_ref() {
            run.connection.stop.store(true, Ordering::Release);
        }
        CNDF_IRON_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn cndf_iron_session_destroy(
    session: *mut CNDFIronSession,
    join_timeout_ms: u32,
) {
    ffi((), || {
        let Some(session_ref) = session.as_ref() else {
            return;
        };
        let deadline = Instant::now() + Duration::from_millis(join_timeout_ms.into());
        session_ref.callbacks.closed.store(true, Ordering::Release);
        cndf_iron_disconnect(session);
        // Swift resolves any outstanding certificate decision before calling destroy.
        drop(lock(&session_ref.callbacks.gate));
        let mut state = lock(&session_ref.state);
        if let Some(run) = state.run.as_ref() {
            while run.threads.iter().any(|thread| !thread.is_finished()) {
                if Instant::now() >= deadline {
                    return;
                }
                thread::sleep(Duration::from_millis(1));
            }
        }
        if let Some(run) = state.run.take() {
            for thread in run.threads {
                let _ = thread.join();
            }
        }
        drop(state);
        drop(Box::from_raw(session));
    });
}

#[cfg(feature = "stub")]
use stub::start_workers;

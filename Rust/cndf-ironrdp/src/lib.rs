#![allow(non_camel_case_types)]

mod abi;
#[cfg(all(feature = "engine", not(feature = "stub")))]
mod engine;
#[cfg(all(feature = "engine", not(feature = "stub")))]
mod errors;
#[cfg(all(feature = "engine", not(feature = "stub")))]
mod frame;
#[cfg(all(feature = "engine", not(feature = "stub")))]
mod input;
#[cfg(all(feature = "legacy-tls", not(feature = "stub")))]
mod legacy_tls;
#[cfg(all(feature = "engine", not(feature = "stub")))]
use engine::start_workers;

#[cfg(not(any(feature = "engine", feature = "stub")))]
compile_error!("Enable engine or stub");
#[cfg(feature = "stub")]
mod stub;

pub use abi::*;
use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, MutexGuard, Once};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use zeroize::Zeroizing;
use CNDFIronStatus::*;

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

thread_local! {
    static CNDF_PANIC_SCOPE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

fn catch_worker<T>(operation: impl FnOnce() -> T) -> std::thread::Result<T> {
    static INSTALL: Once = Once::new();
    INSTALL.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if !CNDF_PANIC_SCOPE
                .try_with(std::cell::Cell::get)
                .unwrap_or(false)
            {
                previous(info);
            }
        }));
    });
    CNDF_PANIC_SCOPE.with(|scope| {
        let old = scope.replace(true);
        let result = catch_unwind(AssertUnwindSafe(operation));
        scope.set(old);
        result
    })
}

fn ffi<T>(fallback: T, operation: impl FnOnce() -> T) -> T {
    catch_worker(operation).unwrap_or(fallback)
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
    #[cfg(not(feature = "stub"))]
    input: Mutex<Option<ironrdp_client::rdp::RdpInputSender>>,
    callbacks: Arc<Callbacks>,
    statistics: Arc<Mutex<CNDFIronStatistics>>,
}

impl Connection {
    fn worker(&self, operation: impl FnOnce()) {
        if catch_worker(operation).is_err() {
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
    tls_profile: u32,
    password: Zeroizing<String>,
}

#[cfg_attr(feature = "stub", allow(dead_code))]
enum Command {
    #[cfg(feature = "stub")]
    Input(Vec<CNDFIronInputEvent>),
    #[cfg(feature = "stub")]
    Resize(u32, u32),
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
    #[cfg(not(feature = "stub"))]
    fn send_input(
        &self,
        generation: u64,
        events: &[CNDFIronInputEvent],
        timeout: Duration,
    ) -> CNDFIronStatus {
        use tokio::sync::mpsc::error::TrySendError;
        let deadline = Instant::now() + timeout;
        let connection = {
            let state = lock(&self.state);
            let Some(run) = state.run.as_ref() else {
                return CNDF_IRON_NOT_CONNECTED;
            };
            Arc::clone(&run.connection)
        };
        let Some(mut input_event) = input::convert(events) else {
            return CNDF_IRON_INVALID_ARGUMENT;
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
            let Some(input) = lock(&connection.input).clone() else {
                return CNDF_IRON_NOT_CONNECTED;
            };
            match input.try_send(input_event) {
                Ok(()) => {
                    lock(&self.statistics).input_events_sent += events.len() as u64;
                    return CNDF_IRON_OK;
                }
                Err(TrySendError::Closed(_)) => return CNDF_IRON_NOT_CONNECTED,
                Err(TrySendError::Full(pending)) => input_event = pending,
            }
            if Instant::now() >= deadline {
                lock(&self.statistics).input_busy += 1;
                return CNDF_IRON_BUSY;
            }
            thread::sleep(Duration::from_millis(1));
        }
    }

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
                #[cfg(feature = "stub")]
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

/// Returns a static string with the crate version, upstream SHA and patch count.
#[no_mangle]
pub extern "C" fn cndf_iron_version() -> *const c_char {
    ffi(ptr::null(), || {
        #[cfg(feature = "stub")]
        let version = concat!(
            "cndf-ironrdp ",
            env!("CARGO_PKG_VERSION"),
            " ironrdp=15b4a03ff552 patches=0\0"
        );
        #[cfg(not(feature = "stub"))]
        let version = concat!(
            "cndf-ironrdp ",
            env!("CARGO_PKG_VERSION"),
            " ironrdp=15b4a03ff552 patches=4\0"
        );
        version.as_ptr().cast()
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

#[cfg(feature = "engine")]
fn dimensions(width: u32, height: u32) -> bool {
    ironrdp_pdu::desktop_framebuffer::desktop_pixel_count(width, height).is_ok()
}

#[cfg(not(feature = "engine"))]
fn dimensions(width: u32, height: u32) -> bool {
    // Stub-only builds have no IronRDP dependency and mirror the engine limits.
    (1..=8192).contains(&width) && (1..=8192).contains(&height)
}

const TLS_PROFILE_OFFSET: usize = std::mem::offset_of!(CNDFIronConnectOptions, tls_profile);

/// Starts an asynchronous connection. The password is read during this call and the bridge copy is zeroized.
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
            || options.cast::<u32>().read() < TLS_PROFILE_OFFSET as u32
            || (password_utf8.is_null() && password_length != 0)
            || password_length > isize::MAX as usize
        {
            return CNDF_IRON_INVALID_ARGUMENT;
        }
        if ptr::addr_of!((*options).log_level).cast::<u32>().read() > 6 {
            return CNDF_IRON_INVALID_ARGUMENT;
        }
        // Callers built before `tls_profile` existed get the modern profile.
        let tls_profile = if options.cast::<u32>().read() >= std::mem::size_of::<CNDFIronConnectOptions>() as u32 {
            ptr::addr_of!((*options).tls_profile).read()
        } else {
            CNDF_IRON_TLS_MODERN
        };
        if !matches!(tls_profile, CNDF_IRON_TLS_MODERN | CNDF_IRON_TLS_LEGACY) {
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
            tls_profile,
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
            #[cfg(not(feature = "stub"))]
            input: Mutex::default(),
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
        for index in 0..count {
            let event = events.add(index);
            if ptr::addr_of!((*event).kind).cast::<u32>().read() > 4
                || ptr::addr_of!((*event).button).cast::<u32>().read() > 2
            {
                return CNDF_IRON_INVALID_ARGUMENT;
            }
        }
        let events = if count == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(events, count)
        };
        let timeout = Duration::from_millis(timeout_ms.into());
        #[cfg(feature = "stub")]
        return session.send(generation, Command::Input(events.to_vec()), timeout);
        #[cfg(not(feature = "stub"))]
        return session.send_input(generation, events, timeout);
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
        #[cfg(feature = "stub")]
        return session.send(generation, Command::Resize(width, height), Duration::ZERO);
        #[cfg(not(feature = "stub"))]
        {
            use ironrdp_client::rdp::RdpInputEvent;
            use tokio::sync::mpsc::error::TrySendError;

            let state = lock(&session.state);
            let Some(run) = state.run.as_ref() else {
                return CNDF_IRON_NOT_CONNECTED;
            };
            if session.callbacks.closed.load(Ordering::Acquire) {
                return CNDF_IRON_CLOSED;
            }
            let connection = &run.connection;
            if connection.generation != generation
                || connection.stop.load(Ordering::Acquire)
                || !connection.connected.load(Ordering::Acquire)
            {
                return CNDF_IRON_NOT_CONNECTED;
            }
            let input = lock(&connection.input);
            let Some(input) = input.as_ref() else {
                return CNDF_IRON_NOT_CONNECTED;
            };
            match input.try_send(RdpInputEvent::Resize {
                width: width as u16,
                height: height as u16,
                scale_factor: scale_percent,
                physical_size: None,
            }) {
                Ok(()) => CNDF_IRON_OK,
                Err(TrySendError::Closed(_)) => CNDF_IRON_NOT_CONNECTED,
                Err(TrySendError::Full(_)) => CNDF_IRON_BUSY,
            }
        }
    })
}

/// Re-delivers the current framebuffer with a full dirty rectangle and no server round trip.
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

/// Requests orderly shutdown and returns immediately.
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

/// Closes the callback gate and waits up to the join deadline for worker exit.
/// If a worker outlives that deadline the closed session is retained. Finish pending
/// certificate callbacks before calling destroy, and keep the context alive until it returns.
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::c_void;
    use std::sync::atomic::AtomicUsize;

    #[derive(Default)]
    struct Probe {
        failures: AtomicUsize,
    }

    extern "C" fn failure(
        generation: u64,
        kind: CNDFIronFailureKind,
        code: u32,
        _: CNDFIronStage,
        _: *const u8,
        _: usize,
        context: *mut c_void,
    ) {
        if generation == 1
            && kind == CNDFIronFailureKind::CNDF_IRON_FAILURE_ENGINE
            && code == 0x49520001
        {
            let probe = unsafe { &*context.cast::<Probe>() };
            probe.failures.fetch_add(1, Ordering::Relaxed);
        }
    }

    #[test]
    fn isolates_worker_panic_and_closes_callback_gate_at_destroy() {
        let mut probe = Probe::default();
        let table = CNDFIronCallbacks {
            log: None,
            certificate_trust: None,
            connected: None,
            failure: Some(failure),
            disconnect: None,
            frame: None,
            pointer: None,
            context: (&mut probe as *mut Probe).cast(),
        };
        let session = unsafe { cndf_iron_session_create(&table) };
        let owner = unsafe { &*session };
        let release = Arc::new(AtomicBool::new(false));
        let connection = Arc::new(Connection {
            generation: 1,
            connected: AtomicBool::new(true),
            stop: AtomicBool::new(false),
            #[cfg(not(feature = "stub"))]
            input: Mutex::default(),
            callbacks: Arc::clone(&owner.callbacks),
            statistics: Arc::clone(&owner.statistics),
        });
        let worker = Arc::clone(&connection);
        let wait = Arc::clone(&release);
        let (done, observed) = mpsc::channel();
        let thread = thread::spawn(move || {
            worker.worker(|| panic!("synthetic private panic payload"));
            done.send(()).unwrap();
            while !wait.load(Ordering::Acquire) {
                thread::yield_now();
            }
            worker.worker(|| panic!("synthetic private panic payload after destroy"));
        });
        let (commands, _) = mpsc::sync_channel(128);
        lock(&owner.state).run = Some(Run {
            connection,
            commands,
            threads: vec![thread],
        });
        observed.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(probe.failures.load(Ordering::Relaxed), 1);
        assert!(!unsafe { cndf_iron_is_connected(session, 1) });
        unsafe { cndf_iron_session_destroy(session, 0) };
        release.store(true, Ordering::Release);
        // The first destroy intentionally retained this test handle because the worker was alive.
        unsafe { cndf_iron_session_destroy(session, 2000) };
        assert_eq!(probe.failures.load(Ordering::Relaxed), 1);
    }
}

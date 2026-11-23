use super::*;
use crate::errors::{self, Failure};
use crate::frame::Frame;
use ironrdp_client::config::{ClipboardType, Config, ConfigBuilder, Destination};
use ironrdp_client::output_channel::{output_channel, OutputEventReceiver};
use ironrdp_client::rdp::{AutoReconnectDecision, RdpClient, RdpOutputEvent};
use std::ffi::CString;
use tokio::sync::mpsc as async_channel;
use tracing::level_filters::LevelFilter;
use tracing_subscriber::{layer::SubscriberExt, Layer};

enum Output {
    Rdp(RdpOutputEvent),
    Failure(Failure),
    Redeliver,
}

pub(super) fn start_workers(
    connection: Arc<Connection>,
    options: Options,
    commands: Receiver<Command>,
    ready: Receiver<()>,
) -> std::io::Result<(Vec<JoinHandle<()>>, FlushLogs)> {
    let (output, updates) = async_channel::channel(128);
    let delivery = Arc::clone(&connection);
    let minimum = options.log_level;
    let repeats = Arc::<Mutex<Repeats>>::default();
    let flush_logs = log_flush(&connection, minimum, &repeats);
    let delivery_repeats = Arc::clone(&repeats);
    let deliver_thread = thread::Builder::new()
        .name(format!("cndf-iron-{}-deliver", connection.generation))
        .spawn(move || {
            delivery.worker(|| {
                deliver(&delivery, updates, minimum, &delivery_repeats, Instant::now)
            })
        })?;
    let (clip_jobs, clip) = if options.channels.clipboard {
        let (jobs, worker) = clipboard::ClipWork::spawn(Arc::clone(&connection))?;
        (Some(jobs), Some(worker))
    } else {
        (None, None)
    };
    let session_thread = thread::Builder::new()
        .name(format!("cndf-iron-{}-session", connection.generation))
        .spawn(move || {
            if catch_worker(|| {
                if ready.recv().is_ok() {
                    run(
                        &connection,
                        options,
                        commands,
                        &output,
                        clip_jobs.as_ref(),
                        &repeats,
                    );
                }
            })
            .is_err()
            {
                lock(&connection.clipboard).take();
                connection.stop.store(true, Ordering::Release);
                connection.connected.store(false, Ordering::Release);
                let _ = output.blocking_send(Output::Failure(errors::PANIC));
            }
        });
    match session_thread {
        Ok(session_thread) => Ok((
            [Some(session_thread), Some(deliver_thread), clip]
                .into_iter()
                .flatten()
                .collect(),
            flush_logs,
        )),
        Err(error) => {
            if let Some(clip) = clip {
                let _ = clip.join();
            }
            let _ = deliver_thread.join();
            Err(error)
        }
    }
}

const DISPLAY_LOG_TARGET: &str = "cndf_rdp_display";
pub(super) const TLS_LOG_TARGET: &str = "cndf_rdp_tls";
const DEVICE_SCALE_PERCENT: u32 = 100;

#[derive(Default)]
struct SafeLogMessage(String);

impl tracing::field::Visit for SafeLogMessage {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.0 = format!("{value:?}");
        }
    }
}

struct Logs {
    connection: Arc<Connection>,
    minimum: CNDFIronLogLevel,
    repeats: Arc<Mutex<Repeats>>,
}

/// How long one IronRDP log event name logs only its first occurrence.
const REPEAT_WINDOW: Duration = Duration::from_secs(1);
/// Event names tracked at once; more names inside one window count as `other`.
const REPEAT_NAMES: usize = 64;

/// A log line chosen by `Repeats`: an event name, or how often it repeated in one window.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Line {
    Name(&'static str),
    Repeated(&'static str, u64),
}

impl Line {
    fn emit(self, connection: &Connection, minimum: CNDFIronLogLevel, level: CNDFIronLogLevel) {
        match self {
            Self::Name(name) => log(connection, minimum, level, name),
            Self::Repeated(name, count) => log(
                connection,
                minimum,
                level,
                &format!("{name} repeated count={count}"),
            ),
        }
    }
}

/// One event name's current window: when its first line was logged, the repeats since, and the
/// highest level among them.
#[derive(Clone, Copy)]
struct Window {
    name: &'static str,
    started: Instant,
    repeats: u64,
    level: CNDFIronLogLevel,
}

impl Window {
    fn summary(&self) -> Option<(CNDFIronLogLevel, Line)> {
        (self.repeats != 0).then_some((self.level, Line::Repeated(self.name, self.repeats)))
    }
}

/// Server-triggered IronRDP log events reduced to one line per name per window plus a count.
///
/// INVARIANT: Fixed size, so an event flood adds no memory and at most two lines per window.
struct Repeats {
    windows: [Option<Window>; REPEAT_NAMES],
    other: Option<Window>,
}

impl Default for Repeats {
    fn default() -> Self {
        Self {
            windows: [None; REPEAT_NAMES],
            other: None,
        }
    }
}

fn louder(a: CNDFIronLogLevel, b: CNDFIronLogLevel) -> CNDFIronLogLevel {
    if (b as u32) > (a as u32) {
        b
    } else {
        a
    }
}

impl Repeats {
    /// Records one event and returns the lines to log for it.
    fn record(
        &mut self,
        name: &'static str,
        level: CNDFIronLogLevel,
        now: Instant,
    ) -> [Option<(CNDFIronLogLevel, Line)>; 2] {
        let fresh = Window {
            name,
            started: now,
            repeats: 0,
            level,
        };
        if let Some(window) = self.windows.iter_mut().flatten().find(|w| w.name == name) {
            if now.duration_since(window.started) < REPEAT_WINDOW {
                window.repeats += 1;
                window.level = louder(window.level, level);
                return [None, None];
            }
            let summary = window.summary();
            *window = fresh;
            return [summary, Some((level, Line::Name(name)))];
        }
        let free = self.windows.iter_mut().find(|slot| {
            slot.is_none_or(|w| now.duration_since(w.started) >= REPEAT_WINDOW)
        });
        if let Some(slot) = free {
            let summary = slot.and_then(|w| w.summary());
            *slot = Some(fresh);
            return [summary, Some((level, Line::Name(name)))];
        }
        let other = self.other.get_or_insert(Window {
            name: "other",
            ..fresh
        });
        other.repeats += 1;
        other.level = louder(other.level, level);
        if now.duration_since(other.started) < REPEAT_WINDOW {
            return [None, None];
        }
        let summary = other.summary();
        self.other = None;
        [summary, None]
    }

    /// Takes the repeats not logged yet, as at the end of a session.
    fn drain(&mut self) -> impl Iterator<Item = (CNDFIronLogLevel, Line)> {
        let windows = std::mem::take(self);
        windows
            .windows
            .into_iter()
            .chain([windows.other])
            .flatten()
            .filter_map(|w| w.summary())
    }
}

/// Logs a session's pending repeat counts when called. Called before each report that ends the
/// session's callbacks, because the host drops the session's log lines after it.
fn log_flush(
    connection: &Arc<Connection>,
    minimum: CNDFIronLogLevel,
    repeats: &Arc<Mutex<Repeats>>,
) -> FlushLogs {
    let connection = Arc::clone(connection);
    let repeats = Arc::clone(repeats);
    Arc::new(move || Logs::flush(&connection, minimum, &repeats))
}

impl Logs {
    /// Logs the repeats the session has not logged yet.
    fn flush(connection: &Connection, minimum: CNDFIronLogLevel, repeats: &Mutex<Repeats>) {
        let lines: Vec<_> = lock(repeats).drain().collect();
        for (level, line) in lines {
            line.emit(connection, minimum, level);
        }
    }
}

impl<S: tracing::Subscriber> Layer<S> for Logs {
    fn on_event(&self, event: &tracing::Event<'_>, _: tracing_subscriber::layer::Context<'_, S>) {
        let metadata = event.metadata();
        let own = matches!(
            metadata.target(),
            DISPLAY_LOG_TARGET | TLS_LOG_TARGET | crate::h264::H264_LOG_TARGET
        );
        if !own && !metadata.target().starts_with("ironrdp") {
            return;
        }
        let level = match *metadata.level() {
            tracing::Level::TRACE => CNDFIronLogLevel::CNDF_IRON_LOG_TRACE,
            tracing::Level::DEBUG => CNDFIronLogLevel::CNDF_IRON_LOG_DEBUG,
            tracing::Level::INFO => CNDFIronLogLevel::CNDF_IRON_LOG_INFO,
            tracing::Level::WARN => CNDFIronLogLevel::CNDF_IRON_LOG_WARN,
            tracing::Level::ERROR => CNDFIronLogLevel::CNDF_IRON_LOG_ERROR,
        };
        if own {
            // These targets contain only display geometry, scale factors, TLS parameters and
            // H.264 picture sizes and counts.
            let mut message = SafeLogMessage::default();
            event.record(&mut message);
            log(&self.connection, self.minimum, level, &message.0);
        } else {
            // Other IronRDP event fields may contain session data. A server can trigger these
            // without limit, so each name logs once per window and then only a count.
            let lines = lock(&self.repeats).record(metadata.name(), level, Instant::now());
            for (level, line) in lines.into_iter().flatten() {
                line.emit(&self.connection, self.minimum, level);
            }
        }
    }
}

impl Connection {
    pub(super) fn clip_log(&self, level: CNDFIronLogLevel, message: &str) {
        log(self, self.log_level, level, message);
    }
}

fn log(connection: &Connection, minimum: CNDFIronLogLevel, level: CNDFIronLogLevel, message: &str) {
    if (level as u32) < (minimum as u32) {
        return;
    }
    connection.callbacks.invoke(|table| {
        if let Some(callback) = table.log {
            callback(
                connection.generation,
                level,
                message.as_ptr(),
                message.len(),
                table.context,
            );
        }
    });
}

fn run(
    connection: &Arc<Connection>,
    options: Options,
    commands: Receiver<Command>,
    output: &async_channel::Sender<Output>,
    clip_jobs: Option<&clipboard::ClipJobs>,
    repeats: &Arc<Mutex<Repeats>>,
) {
    let rejected = Arc::new(AtomicBool::new(false));
    let trust_outcome = Arc::clone(&rejected);
    let trust_connection = Arc::clone(connection);
    let hostname = CString::new(options.host.as_str()).expect("validated C hostname");
    let port = options.port;
    let trust: ironrdp_tls::CertificateChainValidationCallback = Arc::new(move |der, _, reason| {
        let pointers: Vec<_> = der.iter().map(|certificate| certificate.as_ptr()).collect();
        let lengths: Vec<_> = der.iter().map(|certificate| certificate.len()).collect();
        let chain = CNDFIronCertificateChain {
            der: pointers.as_ptr(),
            der_length: lengths.as_ptr(),
            count: der.len(),
            hostname: hostname.as_ptr(),
            port,
            problems: match reason {
                "untrusted" => CNDF_IRON_CERT_CHAIN_UNTRUSTED,
                "name" => CNDF_IRON_CERT_NAME_MISMATCH,
                "validity" => CNDF_IRON_CERT_EXPIRED,
                _ => CNDF_IRON_CERT_OTHER,
            },
        };
        let accepted = !trust_connection.stop.load(Ordering::Acquire)
            && trust_connection
                .callbacks
                .invoke(|table| {
                    table.certificate_trust.is_some_and(|callback| {
                        callback(trust_connection.generation, &chain, table.context)
                    })
                })
                .unwrap_or(false);
        trust_outcome.store(!accepted, Ordering::Release);
        accepted
    });

    #[cfg(feature = "legacy-tls")]
    let legacy_trust = Arc::clone(&trust);
    // Client Info logs on with the password only on a TLS-only connection (patch 0033).
    let autologon = !options.username.is_empty() && !options.password.is_empty();
    let autologon_sent = Arc::new(AtomicBool::new(false));
    let desktop_scale = options.scale.clamp(100, 500);
    let mut builder = ConfigBuilder::new()
        .with_destination(Destination::from_parts(&options.host, options.port))
        // xrdp suppresses resize reactivation for client builds at or below 419.
        .with_client_build(420)
        .with_client_dir("")
        .with_platform(ironrdp_pdu::rdp::capability_sets::MajorPlatformType::OSX)
        .with_client_name(channels::client_name())
        // RDPDR carries a static Noop rdpsnd companion when local playback is off.
        .with_rdpdr(channels::rdpdr_enabled(
            options.channels.drive.is_some(),
            options.channels.audio,
        ))
        .with_printers(false)
        .with_ports(false)
        .with_audio_mode(channels::audio_mode(options.channels.audio))
        .with_audio_capture(false)
        .with_clipboard(if options.channels.clipboard {
            ClipboardType::Enable
        } else {
            ClipboardType::Disable
        })
        .with_username(options.username)
        .with_password(options.password.as_str())
        .with_autologon(autologon)
        .with_desktop_width(options.width as u16)
        .with_desktop_height(options.height as u16)
        .with_desktop_scale_factor(desktop_scale)
        .with_device_scale_factor(DEVICE_SCALE_PERCENT)
        // The pinned connector negotiates 16- or 32-bit color. Its 32-bit
        // path carries the 24 RGB bits requested by ABI callers at depth 24.
        .with_color_depth(if options.depth == 16 { 16 } else { 32 })
        .with_tls(true)
        .with_credssp(true)
        .with_server_pointer(true)
        .with_pointer_software_rendering(false)
        .with_graphics_pipeline(options.graphics)
        .with_h264_decoder(
            options
                .graphics
                .then(|| crate::h264::factory(Arc::clone(&connection.h264)))
                .flatten(),
        )
        .with_certificate_validation(ironrdp_tls::CertificateValidation::Strict)
        .with_certificate_chain_validation_callback(trust);
    builder = with_keyboard(builder, options.keyboard);
    drop(options.password);
    if let Some(domain) = options.domain {
        builder = builder.with_domain(domain);
    }
    let Ok(config) = builder.build() else {
        let _ = output.blocking_send(Output::Failure(errors::CONFIGURATION));
        return;
    };
    let audio_statistics = Arc::clone(&connection.statistics);
    let config = config
        .with_audio_wave_observer(Arc::new(move || {
            lock(&audio_statistics).audio_waves_received += 1;
        }))
        .with_tls_only_autologon(Arc::clone(&autologon_sent));
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build();
    let Ok(runtime) = runtime else {
        let _ = output.blocking_send(Output::Failure(errors::CONFIGURATION));
        return;
    };
    let minimum = options.log_level;
    let filter = match minimum {
        CNDFIronLogLevel::CNDF_IRON_LOG_TRACE => LevelFilter::TRACE,
        CNDFIronLogLevel::CNDF_IRON_LOG_DEBUG => LevelFilter::DEBUG,
        CNDFIronLogLevel::CNDF_IRON_LOG_INFO => LevelFilter::INFO,
        CNDFIronLogLevel::CNDF_IRON_LOG_WARN => LevelFilter::WARN,
        CNDFIronLogLevel::CNDF_IRON_LOG_ERROR => LevelFilter::ERROR,
        CNDFIronLogLevel::CNDF_IRON_LOG_FATAL | CNDFIronLogLevel::CNDF_IRON_LOG_OFF => {
            LevelFilter::OFF
        }
    };
    let subscriber = tracing_subscriber::registry().with(
        Logs {
            connection: Arc::clone(connection),
            minimum,
            repeats: Arc::clone(repeats),
        }
        .with_filter(filter),
    );
    tracing::subscriber::with_default(subscriber, || {
        log(
            connection,
            minimum,
            CNDFIronLogLevel::CNDF_IRON_LOG_INFO,
            "Starting IronRDP connection",
        );
        log(
            connection,
            minimum,
            CNDFIronLogLevel::CNDF_IRON_LOG_INFO,
            &format!(
                "GCC display requested: {}x{} DesktopScaleFactor={desktop_scale} DeviceScaleFactor={DEVICE_SCALE_PERCENT}.",
                options.width, options.height
            ),
        );
        runtime.block_on(async {
            let retry_config = cfg!(feature = "legacy-tls").then(|| config.clone());
            let retry = run_attempt(
                connection,
                config,
                &commands,
                output,
                &rejected,
                &autologon_sent,
                minimum,
                retry_config,
                false,
                clip_jobs,
                options.channels.drive.as_ref(),
            )
            .await;
            #[cfg(feature = "legacy-tls")]
            if let Some(config) = retry {
                let config =
                    config.with_tls_upgrader(Arc::new(crate::legacy_tls::LegacyTlsUpgrader {
                        callback: legacy_trust,
                    }));
                // run_attempt has dropped the original client and its transport.
                // The next client checks the same generation's stop flag before polling.
                run_attempt(
                    connection,
                    config,
                    &commands,
                    output,
                    &rejected,
                    &autologon_sent,
                    minimum,
                    None,
                    true,
                    clip_jobs,
                    options.channels.drive.as_ref(),
                )
                .await;
            }
            #[cfg(not(feature = "legacy-tls"))]
            debug_assert!(retry.is_none());
        });
    });
    Logs::flush(connection, minimum, repeats);
    connection.connected.store(false, Ordering::Release);
    *lock(&connection.input) = None;
    // DNS uses Tokio's blocking pool. Cancel the session without waiting for an
    // OS resolver that is already working on a request.
    runtime.shutdown_background();
}

fn with_keyboard(builder: ConfigBuilder, keyboard: Keyboard) -> ConfigBuilder {
    builder
        .with_keyboard_layout(keyboard.layout)
        .with_keyboard_type(ironrdp_pdu::gcc::KeyboardType(keyboard.kind))
        .with_keyboard_subtype(keyboard.subtype)
        .with_keyboard_functional_keys_count(keyboard.function_keys)
}

async fn run_attempt(
    connection: &Connection,
    config: Config,
    commands: &Receiver<Command>,
    output: &async_channel::Sender<Output>,
    rejected: &AtomicBool,
    autologon_sent: &AtomicBool,
    minimum: CNDFIronLogLevel,
    retry_config: Option<Config>,
    legacy: bool,
    clip_jobs: Option<&clipboard::ClipJobs>,
    drive: Option<&(String, String)>,
) -> Option<Config> {
    let (sender, receiver) = output_channel(128);
    let mut client = RdpClient::new(config, sender)
        .with_desktop_updates()
        .with_display_resize_fallback_reconnect(false);
    if let Some((path, name)) = drive {
        client = client.with_rdpdr_backend_factory(Box::new(channels::DriveFactory::new(
            path.clone(),
            name.clone(),
            Arc::clone(&connection.statistics),
        )));
    }
    let input = client.input_sender();
    if let Some(jobs) = clip_jobs {
        let channel = clipboard::Channel::new(input.clone(), jobs.clone());
        client = client.with_cliprdr_backend_factory(Box::new(channel.clone()));
        *lock(&connection.clipboard) = Some(channel);
    }
    *lock(&connection.input) = Some(input.clone());
    if connection.stop.load(Ordering::Acquire) {
        input.request_close();
    }

    let retry = {
        let bridge = forward(
            connection,
            &input,
            commands,
            receiver,
            output,
            rejected,
            autologon_sent,
            minimum,
            retry_config,
            legacy,
        );
        let client = client.run();
        tokio::pin!(bridge, client);
        tokio::select! {
            () = &mut client => bridge.await,
            retry = &mut bridge => retry,
        }
    };
    *lock(&connection.clipboard) = None;
    *lock(&connection.input) = None;
    retry
}

async fn forward(
    connection: &Connection,
    input: &ironrdp_client::rdp::RdpInputSender,
    commands: &Receiver<Command>,
    mut receiver: OutputEventReceiver,
    output: &async_channel::Sender<Output>,
    rejected: &AtomicBool,
    autologon_sent: &AtomicBool,
    minimum: CNDFIronLogLevel,
    mut retry_config: Option<Config>,
    legacy: bool,
) -> Option<Config> {
    let mut timer = tokio::time::interval(Duration::from_millis(4));
    let mut stopping = None;
    loop {
        tokio::select! {
            event = receiver.recv() => {
                let Some(event) = event else { break };
                let event = match event {
                    RdpOutputEvent::ConnectionFailure(error) => {
                        if connection.stop.load(Ordering::Acquire) { continue; }
                        let failure = errors::classify(&error, rejected.load(Ordering::Acquire));
                        if failure.1 == errors::TLS_PROTOCOL_VERSION && retry_config.is_some() {
                            return retry_config;
                        }
                        #[cfg(not(feature = "legacy-tls"))]
                        let failure = if failure.1 == errors::TLS_PROTOCOL_VERSION {
                            errors::LEGACY_TLS_UNAVAILABLE
                        } else {
                            failure
                        };
                        if legacy {
                            log(connection, minimum, CNDFIronLogLevel::CNDF_IRON_LOG_INFO,
                                "IronRDP legacy TLS connection failed.");
                        }
                        Output::Failure(failure)
                    }
                    RdpOutputEvent::Connected => {
                        // The modern handshake succeeded. Release its unused retry configuration.
                        retry_config = None;
                        Output::Rdp(RdpOutputEvent::Connected)
                    }
                    RdpOutputEvent::LogonError(info) => {
                        let failure = logon_failure(autologon_sent.load(Ordering::Acquire), &info);
                        log(connection, minimum, CNDFIronLogLevel::CNDF_IRON_LOG_INFO, &format!(
                            "Server logon notification type=0x{:08x} data=0x{:08x} credentials={}",
                            info.error_type.as_u32(),
                            info.error_data.to_u32(),
                            if failure.is_some() { "rejected" } else { "unchanged" },
                        ));
                        let Some(failure) = failure else { continue };
                        // The rejection ends the generation: one failure, no further events.
                        let _ = output.send(Output::Failure(failure)).await;
                        return None;
                    }
                    RdpOutputEvent::AutoReconnecting { response, .. } => {
                        let _ = response.send(AutoReconnectDecision::Stop);
                        continue;
                    }
                    RdpOutputEvent::DisplayResizeFallback(reason) => {
                        log(connection, minimum, CNDFIronLogLevel::CNDF_IRON_LOG_WARN, &format!("Display Control resize failed: {reason:?}"));
                        continue;
                    }
                    RdpOutputEvent::MonitorLayoutRejected => {
                        log(connection, minimum, CNDFIronLogLevel::CNDF_IRON_LOG_WARN, "Display Control rejected the monitor layout");
                        continue;
                    }
                    event => Output::Rdp(event),
                };
                if output.send(event).await.is_err() { break; }
            }
            _ = timer.tick() => {
                if connection.stop.load(Ordering::Acquire) {
                    if let Some(started) = stopping {
                        if Instant::now().duration_since(started) >= Duration::from_millis(250) {
                            input.request_close();
                        }
                    } else {
                        stopping = Some(Instant::now());
                        if connection.connected.load(Ordering::Acquire) {
                            input.request_graceful_close();
                        } else {
                            input.request_close();
                        }
                    }
                }
                for _ in 0..128 {
                    match commands.try_recv() {
                        Ok(Command::Redeliver) => {
                            if output.send(Output::Redeliver).await.is_err() { return None; }
                        }
                        #[cfg(feature = "stub")]
                        Ok(_) => unreachable!("stub command in real engine"),
                        Err(mpsc::TryRecvError::Empty) => break,
                        Err(mpsc::TryRecvError::Disconnected) => {
                            input.request_close();
                            return None;
                        }
                    }
                }
            }
        }
    }
    None
}

/// The failure a server Logon Error notification ends the session with: only an explicit
/// credential rejection of a Client Info logon (TLS-only autologon) is one.
fn logon_failure(
    autologon_sent: bool,
    info: &ironrdp_pdu::rdp::session_info::LogonErrorsInfo,
) -> Option<Failure> {
    (autologon_sent && errors::rejects_logon(info)).then_some(errors::LOGON_REJECTED)
}

/// Publishes only completed frames: a completed frame goes out before the next frame's first
/// tile is composed, merged at most with queued frame ends of its size within the batch window.
/// `now` is the clock, read once per received item.
fn deliver(
    connection: &Connection,
    mut updates: async_channel::Receiver<Output>,
    minimum: CNDFIronLogLevel,
    repeats: &Mutex<Repeats>,
    mut now: impl FnMut() -> Instant,
) {
    let mut frame = Frame::default();
    let mut pending = None;
    while let Some(update) = pending.take().or_else(|| updates.blocking_recv()) {
        let now = now();
        match update {
            Output::Rdp(RdpOutputEvent::DesktopUpdate(update)) => {
                if frame.changes_size(&update) {
                    frame.resize();
                }
                let bytes = match frame.compose(update, now) {
                    Ok(bytes) => bytes,
                    Err(error) => {
                        connection.stop.store(true, Ordering::Release);
                        Logs::flush(connection, minimum, repeats);
                        report_active_framebuffer_failure(connection, error);
                        return;
                    }
                };
                let mut statistics = lock(&connection.statistics);
                statistics.updates_received += 1;
                statistics.dirty_bytes_composed += bytes;
            }
            // A completed frame was published before this item; an unfinished one is dropped.
            other => match other {
                Output::Failure(failure) => {
                    Logs::flush(connection, minimum, repeats);
                    report_failure(connection, failure);
                }
                Output::Rdp(event) => {
                    if matches!(event, RdpOutputEvent::Terminated(_)) {
                        Logs::flush(connection, minimum, repeats);
                    }
                    deliver_event(connection, event, minimum);
                }
                Output::Redeliver => frame.redeliver(connection),
            },
        }
        pending = updates.try_recv().ok();
        let merges = matches!(
            &pending,
            Some(Output::Rdp(RdpOutputEvent::DesktopUpdate(next)))
                if next.ends_frame() && !frame.changes_size(next)
        );
        if frame.ready(merges, now) {
            frame.publish(connection, false);
        }
    }
    connection.connected.store(false, Ordering::Release);
}

fn report_failure(connection: &Connection, failure: Failure) {
    connection.connected.store(false, Ordering::Release);
    connection.end(|table| failure_callback(connection, table, failure));
}

fn failure_callback(
    connection: &Connection,
    table: CNDFIronCallbacks,
    Failure(kind, code, stage, message): Failure,
) {
    crate::failure_callback(table, connection.generation, kind, code, stage, message);
}

fn report_disconnect(connection: &Connection, kind: CNDFIronDisconnectKind, code: u32) {
    connection.connected.store(false, Ordering::Release);
    connection.end(|table| {
        disconnect_callback(connection, table, kind, code)
    });
}

fn disconnect_callback(
    connection: &Connection,
    table: CNDFIronCallbacks,
    kind: CNDFIronDisconnectKind,
    code: u32,
) {
    if let Some(callback) = table.disconnect {
        callback(connection.generation, kind, code, table.context);
    }
}

fn report_active_framebuffer_failure(
    connection: &Connection,
    error: ironrdp_pdu::desktop_framebuffer::DesktopFramebufferError,
) {
    report_active_failure(
        connection,
        errors::framebuffer_failure(error, CNDFIronStage::CNDF_IRON_STAGE_ACTIVE),
    );
}

fn report_active_failure(connection: &Connection, failure: Failure) {
    let code = failure.1;
    connection.connected.store(false, Ordering::Release);
    connection.end(|table| {
        failure_callback(connection, table, failure);
        disconnect_callback(
            connection,
            table,
            CNDFIronDisconnectKind::CNDF_IRON_DISCONNECT_ERROR,
            code,
        );
    });
}

fn deliver_event(connection: &Connection, event: RdpOutputEvent, minimum: CNDFIronLogLevel) {
    use CNDFIronDisconnectKind::*;
    use CNDFIronPointerKind::*;
    let generation = connection.generation;
    match event {
        RdpOutputEvent::Connected => {
            connection.connected.store(true, Ordering::Release);
            connection.callbacks.invoke(|table| {
                if let Some(callback) = table.connected {
                    callback(generation, table.context);
                }
            });
        }
        RdpOutputEvent::Terminated(result) => {
            if let Err(error) = &result {
                // Display gives the session context. Include the immediate PDU error, whose
                // description is static, without walking sources such as CredSSP or TLS.
                let mut message = format!("IronRDP session terminated: {error}");
                if let Some(pdu) = std::error::Error::source(error)
                    .and_then(|source| source.downcast_ref::<ironrdp_pdu::PduError>())
                {
                    use std::fmt::Write as _;
                    let _ = write!(message, ": {pdu}");
                }
                log(
                    connection,
                    minimum,
                    CNDFIronLogLevel::CNDF_IRON_LOG_ERROR,
                    &message,
                );
                if let Some(error) = errors::framebuffer_cause(error) {
                    report_active_framebuffer_failure(connection, error);
                    return;
                }
                if let Some(cause) = errors::channel_limit_cause(error) {
                    // The channel name is the client's own and the limit a constant.
                    log(
                        connection,
                        minimum,
                        CNDFIronLogLevel::CNDF_IRON_LOG_ERROR,
                        &format!(
                            "IronRDP channel message limit exceeded: channel={} limit={}",
                            cause.channel, cause.limit
                        ),
                    );
                    report_active_failure(connection, errors::CHANNEL_MESSAGE_LIMIT);
                    return;
                }
            }
            let kind = if connection.stop.load(Ordering::Acquire) {
                CNDF_IRON_DISCONNECT_LOCAL_REQUEST
            } else if result.is_ok() {
                CNDF_IRON_DISCONNECT_SERVER
            } else {
                CNDF_IRON_DISCONNECT_ERROR
            };
            report_disconnect(connection, kind, 0);
        }
        RdpOutputEvent::PointerDefault | RdpOutputEvent::PointerHidden => {
            let kind = if matches!(event, RdpOutputEvent::PointerHidden) {
                CNDF_IRON_POINTER_HIDDEN
            } else {
                CNDF_IRON_POINTER_DEFAULT
            };
            connection.callbacks.invoke(|table| {
                if let Some(callback) = table.pointer {
                    callback(generation, kind, ptr::null(), 0, 0, 0, 0, 0, table.context);
                }
            });
        }
        RdpOutputEvent::PointerBitmap(pointer) => {
            let (width, height) = (u32::from(pointer.width), u32::from(pointer.height));
            let mut pixels = pointer.bitmap_data.clone();
            for pixel in pixels.chunks_exact_mut(4) {
                pixel.swap(0, 2);
            }
            connection.callbacks.invoke(|table| {
                if let Some(callback) = table.pointer {
                    callback(
                        generation,
                        CNDF_IRON_POINTER_IMAGE,
                        pixels.as_ptr(),
                        width,
                        height,
                        width * 4,
                        pointer.hotspot_x.into(),
                        pointer.hotspot_y.into(),
                        table.context,
                    );
                }
            });
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp_session::{SessionError, SessionErrorExt as _};
    use std::ffi::c_void;

    extern "C" fn capture_log(
        _: u64,
        _: CNDFIronLogLevel,
        bytes: *const u8,
        len: usize,
        context: *mut c_void,
    ) {
        let message = unsafe { std::slice::from_raw_parts(bytes, len) };
        let messages = unsafe { &mut *context.cast::<Vec<String>>() };
        messages.push(String::from_utf8_lossy(message).into_owned());
    }

    #[test]
    fn keyboard_fields_reach_the_connector_config() {
        let config = with_keyboard(
            ConfigBuilder::new()
                .with_destination(Destination::from_parts("localhost", 3389))
                .with_client_build(420)
                .with_client_dir("")
                .with_platform(ironrdp_pdu::rdp::capability_sets::MajorPlatformType::OSX)
                .with_client_name("test")
                .with_username("user")
                .with_password("password"),
            Keyboard {
                layout: 0x412,
                kind: 8,
                subtype: 3,
                function_keys: 12,
            },
        )
        .build()
        .unwrap();
        let connector = config.connector();
        assert_eq!(connector.keyboard_layout, 0x412);
        assert_eq!(connector.keyboard_type, ironrdp_pdu::gcc::KeyboardType::KOREAN);
        assert_eq!(connector.keyboard_subtype, 3);
        assert_eq!(connector.keyboard_functional_keys_count, 12);
    }

    #[test]
    fn logs_termination_without_private_source_details() {
        let mut messages = Vec::<String>::new();
        let table = CNDFIronCallbacks {
            log: Some(capture_log),
            certificate_trust: None,
            connected: None,
            failure: None,
            disconnect: None,
            frame: None,
            pointer: None,
            remote_text: None,
            remote_file_list: None,
            remote_file_contents: None,
            context: (&mut messages as *mut Vec<String>).cast(),
        };
        let connection = Connection {
            generation: 1,
            connected: AtomicBool::new(true),
            stop: AtomicBool::new(false),
            input: Mutex::default(),
            clipboard: Mutex::default(),
            log_level: CNDFIronLogLevel::CNDF_IRON_LOG_OFF,
            callbacks: Arc::new(Callbacks {
                table,
                gate: Mutex::default(),
                closed: AtomicBool::new(false),
            }),
            statistics: Arc::new(Mutex::new(CNDFIronStatistics::default())),
            h264: Arc::default(),
        };
        let error = ironrdp_pdu::PduError::new(
            "graphics update",
            ironrdp_pdu::PduErrorKind::Other {
                description: "unknown surface",
            },
        )
        .with_source(std::io::Error::other("private source sentinel"));
        deliver_event(
            &connection,
            RdpOutputEvent::Terminated(Err(SessionError::pdu(error))),
            CNDFIronLogLevel::CNDF_IRON_LOG_INFO,
        );

        assert_eq!(messages.len(), 1);
        assert!(messages[0].contains("unknown surface"));
        assert!(!messages[0].contains("private source sentinel"));
    }

    fn logging_connection(messages: &mut Vec<String>) -> Arc<Connection> {
        let table = CNDFIronCallbacks {
            log: Some(capture_log),
            certificate_trust: None,
            connected: None,
            failure: None,
            disconnect: None,
            frame: None,
            pointer: None,
            remote_text: None,
            remote_file_list: None,
            remote_file_contents: None,
            context: (messages as *mut Vec<String>).cast(),
        };
        Arc::new(Connection {
            generation: 1,
            connected: AtomicBool::new(true),
            stop: AtomicBool::new(false),
            input: Mutex::default(),
            clipboard: Mutex::default(),
            log_level: CNDFIronLogLevel::CNDF_IRON_LOG_INFO,
            callbacks: Arc::new(Callbacks {
                table,
                gate: Mutex::default(),
                closed: AtomicBool::new(false),
            }),
            statistics: Arc::new(Mutex::new(CNDFIronStatistics::default())),
            h264: Arc::default(),
        })
    }

    #[test]
    fn server_triggered_warning_flood_logs_one_line_and_a_count() {
        let mut messages = Vec::<String>::new();
        let connection = logging_connection(&mut messages);
        let minimum = CNDFIronLogLevel::CNDF_IRON_LOG_INFO;
        let repeats = Arc::<Mutex<Repeats>>::default();
        let subscriber = tracing_subscriber::registry().with(
            Logs {
                connection: Arc::clone(&connection),
                minimum,
                repeats: Arc::clone(&repeats),
            }
            .with_filter(LevelFilter::INFO),
        );
        let started = Instant::now();
        tracing::subscriber::with_default(subscriber, || {
            for index in 0..100_000u32 {
                tracing::warn!(target: "ironrdp_session", index, "private server sentinel");
            }
            tracing::debug!(target: "ironrdp_session", "below the minimum");
        });
        assert!(started.elapsed() < REPEAT_WINDOW, "flood must fit in one window");
        Logs::flush(&connection, minimum, &repeats);

        assert_eq!(messages.len(), 2, "{:?}", &messages[..messages.len().min(3)]);
        let name = &messages[0];
        assert!(name.starts_with("event "), "{name}");
        assert_eq!(messages[1], format!("{name} repeated count=99999"));
        assert!(messages.iter().all(|m| !m.contains("private server sentinel")));
        Logs::flush(&connection, minimum, &repeats);
        assert_eq!(messages.len(), 2, "a flush logs each repeat once");
    }

    const WARN: CNDFIronLogLevel = CNDFIronLogLevel::CNDF_IRON_LOG_WARN;
    const ERROR: CNDFIronLogLevel = CNDFIronLogLevel::CNDF_IRON_LOG_ERROR;

    fn lines(lines: [Option<(CNDFIronLogLevel, Line)>; 2]) -> Vec<(CNDFIronLogLevel, Line)> {
        lines.into_iter().flatten().collect()
    }

    #[test]
    fn repeats_log_the_count_when_the_window_ends() {
        let mut repeats = Repeats::default();
        let start = Instant::now();
        let inside = start + REPEAT_WINDOW - Duration::from_millis(1);
        assert_eq!(lines(repeats.record("a", WARN, start)), [(WARN, Line::Name("a"))]);
        assert_eq!(lines(repeats.record("a", ERROR, inside)), []);
        assert_eq!(lines(repeats.record("a", WARN, inside)), []);
        let next = start + REPEAT_WINDOW;
        assert_eq!(
            lines(repeats.record("a", WARN, next)),
            [(ERROR, Line::Repeated("a", 2)), (WARN, Line::Name("a"))]
        );
        // A window without repeats ends without a count.
        assert_eq!(
            lines(repeats.record("a", WARN, next + REPEAT_WINDOW)),
            [(WARN, Line::Name("a"))]
        );
        assert_eq!(repeats.drain().count(), 0);
    }

    #[test]
    fn repeats_keep_sixty_four_names_and_count_the_rest_as_other() {
        let names: Vec<&'static str> = (0..=REPEAT_NAMES)
            .map(|index| &*format!("n{index}").leak())
            .collect();
        let mut repeats = Repeats::default();
        let start = Instant::now();
        for name in &names[..REPEAT_NAMES] {
            assert_eq!(lines(repeats.record(name, WARN, start)), [(WARN, Line::Name(name))]);
            assert_eq!(lines(repeats.record(name, WARN, start)), []);
        }
        let extra = names[REPEAT_NAMES];
        assert_eq!(lines(repeats.record(extra, WARN, start)), []);
        assert_eq!(lines(repeats.record(extra, ERROR, start)), []);
        let mut drained: Vec<_> = repeats.drain().collect();
        assert_eq!(drained.pop(), Some((ERROR, Line::Repeated("other", 2))));
        assert_eq!(drained.len(), REPEAT_NAMES);
        for (line, name) in drained.iter().zip(&names) {
            assert_eq!(*line, (WARN, Line::Repeated(name, 1)));
        }
    }

    #[test]
    fn repeats_reuse_an_ended_window_for_a_new_name() {
        let names: Vec<&'static str> = (0..=REPEAT_NAMES)
            .map(|index| &*format!("n{index}").leak())
            .collect();
        let mut repeats = Repeats::default();
        let start = Instant::now();
        for name in &names[..REPEAT_NAMES] {
            repeats.record(name, WARN, start);
        }
        repeats.record(names[0], WARN, start);
        let later = start + REPEAT_WINDOW;
        let extra = names[REPEAT_NAMES];
        assert_eq!(
            lines(repeats.record(extra, WARN, later)),
            [(WARN, Line::Repeated(names[0], 1)), (WARN, Line::Name(extra))]
        );
    }

    #[test]
    fn other_logs_its_count_at_most_once_per_window() {
        let names: Vec<&'static str> = (0..=REPEAT_NAMES)
            .map(|index| &*format!("n{index}").leak())
            .collect();
        let (named, extra) = (&names[..REPEAT_NAMES], names[REPEAT_NAMES]);
        let mut repeats = Repeats::default();
        let start = Instant::now();
        for name in named {
            repeats.record(name, WARN, start);
        }
        assert_eq!(lines(repeats.record(extra, WARN, start)), []);
        assert_eq!(lines(repeats.record(extra, WARN, start)), []);
        // Every name starts a new window, so the table stays full.
        let later = start + REPEAT_WINDOW;
        for name in named {
            assert_eq!(lines(repeats.record(name, WARN, later)), [(WARN, Line::Name(name))]);
        }
        assert_eq!(
            lines(repeats.record(extra, ERROR, later)),
            [(ERROR, Line::Repeated("other", 3))]
        );
        assert_eq!(lines(repeats.record(extra, WARN, later)), []);
        assert_eq!(repeats.drain().last(), Some((WARN, Line::Repeated("other", 1))));
    }

    /// What the host saw, dropping a generation's log lines after its failure or disconnect,
    /// as the Swift session does.
    #[derive(Default)]
    struct Host {
        logs: Vec<String>,
        failures: Vec<(CNDFIronFailureKind, u32, CNDFIronStage, String)>,
        disconnects: Vec<(CNDFIronDisconnectKind, u32)>,
        ended: bool,
        frames_before_end: usize,
        frames: Vec<Captured>,
    }

    /// A published frame as the host saw it during the callback.
    #[derive(Debug, PartialEq)]
    struct Captured {
        pixels: Vec<u32>,
        dirty: (u32, u32, u32, u32),
        sequence: u64,
    }

    extern "C" fn host_frame(
        _: u64,
        pixels: *const u8,
        width: u32,
        height: u32,
        stride: u32,
        dirty: CNDFIronRect,
        sequence: u64,
        context: *mut c_void,
    ) {
        let host = unsafe { &mut *context.cast::<Host>() };
        if !host.ended {
            host.frames_before_end += 1;
        }
        assert_eq!(stride, width * 4);
        let bytes = unsafe { std::slice::from_raw_parts(pixels, (stride * height) as usize) };
        host.frames.push(Captured {
            pixels: bytes
                .chunks_exact(4)
                .map(|bgra| u32::from_le_bytes(bgra.try_into().unwrap()))
                .collect(),
            dirty: (dirty.x, dirty.y, dirty.width, dirty.height),
            sequence,
        });
    }

    extern "C" fn host_log(
        _: u64,
        _: CNDFIronLogLevel,
        bytes: *const u8,
        len: usize,
        context: *mut c_void,
    ) {
        let host = unsafe { &mut *context.cast::<Host>() };
        if !host.ended {
            let message = unsafe { std::slice::from_raw_parts(bytes, len) };
            host.logs.push(String::from_utf8_lossy(message).into_owned());
        }
    }

    extern "C" fn host_failure(
        _: u64,
        kind: CNDFIronFailureKind,
        code: u32,
        stage: CNDFIronStage,
        bytes: *const u8,
        len: usize,
        context: *mut c_void,
    ) {
        let host = unsafe { &mut *context.cast::<Host>() };
        let message = unsafe { std::slice::from_raw_parts(bytes, len) };
        host.failures
            .push((kind, code, stage, String::from_utf8_lossy(message).into_owned()));
        host.ended = true;
    }

    extern "C" fn host_disconnect(
        _: u64,
        kind: CNDFIronDisconnectKind,
        code: u32,
        context: *mut c_void,
    ) {
        let host = unsafe { &mut *context.cast::<Host>() };
        host.disconnects.push((kind, code));
        host.ended = true;
    }

    fn host_table(host: &mut Host) -> CNDFIronCallbacks {
        CNDFIronCallbacks {
            log: Some(host_log),
            certificate_trust: None,
            connected: None,
            failure: Some(host_failure),
            disconnect: Some(host_disconnect),
            frame: None,
            pointer: None,
            remote_text: None,
            remote_file_list: None,
            remote_file_contents: None,
            context: (host as *mut Host).cast(),
        }
    }

    fn host_connection(callbacks: Arc<Callbacks>) -> Arc<Connection> {
        Arc::new(Connection {
            generation: 1,
            connected: AtomicBool::new(true),
            stop: AtomicBool::new(false),
            input: Mutex::default(),
            clipboard: Mutex::default(),
            log_level: CNDFIronLogLevel::CNDF_IRON_LOG_INFO,
            callbacks,
            statistics: Arc::new(Mutex::new(CNDFIronStatistics::default())),
            h264: Arc::default(),
        })
    }

    fn host_callbacks(host: &mut Host) -> Arc<Callbacks> {
        Arc::new(Callbacks {
            table: host_table(host),
            gate: Mutex::default(),
            closed: AtomicBool::new(false),
        })
    }

    fn framed_connection(host: &mut Host) -> Arc<Connection> {
        let mut table = host_table(host);
        table.frame = Some(host_frame);
        host_connection(Arc::new(Callbacks {
            table,
            gate: Mutex::default(),
            closed: AtomicBool::new(false),
        }))
    }

    fn tile(width: u16, x: u16, pixels: usize) -> Output {
        let update = ironrdp_client::rdp::DesktopUpdate::new(
            vec![0xff00_0000; pixels],
            std::num::NonZeroU16::new(width).unwrap(),
            std::num::NonZeroU16::new(1).unwrap(),
            ironrdp_pdu::geometry::InclusiveRectangle {
                left: x,
                right: x + pixels as u16 - 1,
                top: 0,
                bottom: 0,
            },
        )
        .unwrap();
        Output::Rdp(RdpOutputEvent::DesktopUpdate(update))
    }

    fn marked(output: Output) -> Output {
        let Output::Rdp(RdpOutputEvent::DesktopUpdate(update)) = output else {
            unreachable!()
        };
        Output::Rdp(RdpOutputEvent::DesktopUpdate(update.with_frame_end()))
    }

    /// A one-row tile of a `width` wide desktop holding `pixels` from column `x`.
    fn row(width: u16, x: u16, pixels: &[u32]) -> Output {
        let update = ironrdp_client::rdp::DesktopUpdate::new(
            pixels.to_vec(),
            std::num::NonZeroU16::new(width).unwrap(),
            std::num::NonZeroU16::new(1).unwrap(),
            ironrdp_pdu::geometry::InclusiveRectangle {
                left: x,
                right: x + pixels.len() as u16 - 1,
                top: 0,
                bottom: 0,
            },
        )
        .unwrap();
        Output::Rdp(RdpOutputEvent::DesktopUpdate(update))
    }

    /// Opaque test pixels told apart by `n`.
    fn px(n: &[u32]) -> Vec<u32> {
        n.iter().map(|n| 0xff00_0000 | n).collect()
    }

    fn pointer() -> Output {
        Output::Rdp(RdpOutputEvent::PointerDefault)
    }

    fn terminated() -> Output {
        Output::Rdp(RdpOutputEvent::Terminated(Ok(
            ironrdp_session::GracefulDisconnectReason::ServerInitiated,
        )))
    }

    fn fake_clock() -> Instant {
        static BASE: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
        *BASE.get_or_init(Instant::now)
    }

    /// Queues every item, each with the millisecond it is received at, closes the channel, and
    /// runs `deliver` to the end.
    fn run_queued(host: &mut Host, items: Vec<(u64, Output)>) -> Arc<Connection> {
        let connection = framed_connection(host);
        let repeats = Arc::<Mutex<Repeats>>::default();
        let (output, updates) = async_channel::channel(items.len() + 1);
        let mut times = Vec::new();
        for (ms, item) in items {
            times.push(ms);
            assert!(output.try_send(item).is_ok());
        }
        drop(output);
        let mut times = times.into_iter();
        let base = fake_clock();
        deliver(
            &connection,
            updates,
            CNDFIronLogLevel::CNDF_IRON_LOG_INFO,
            &repeats,
            || base + Duration::from_millis(times.next().unwrap()),
        );
        assert_eq!(times.next(), None, "the clock is read once per item");
        connection
    }

    fn frames(host: &Host) -> Vec<Vec<u32>> {
        host.frames.iter().map(|frame| frame.pixels.clone()).collect()
    }

    // Design frame-boundary, first falsification point: A ends, B's first tile is queued, a
    // pointer event follows, then B's last tile. int-17 published [B1, A2] (4278190083,
    // 4278190082) once the pointer event emptied the backlog.
    #[test]
    fn completed_frame_goes_out_before_the_next_frames_first_tile() {
        let mut host = Host::default();
        run_queued(
            &mut host,
            vec![
                (0, marked(row(2, 0, &px(&[1, 2])))),
                (1, row(2, 0, &px(&[3]))),
                (2, pointer()),
                (3, marked(row(2, 1, &px(&[4])))),
            ],
        );
        assert_eq!(
            host.frames,
            [
                Captured { pixels: px(&[1, 2]), dirty: (0, 0, 2, 1), sequence: 1 },
                Captured { pixels: px(&[3, 4]), dirty: (0, 0, 2, 1), sequence: 2 },
            ]
        );
    }

    // The same order with the queue running empty after B's first tile instead of a pointer.
    #[test]
    fn empty_queue_after_the_next_frames_first_tile_publishes_nothing_unfinished() {
        let mut host = Host::default();
        let connection = framed_connection(&mut host);
        let repeats = Arc::<Mutex<Repeats>>::default();
        let (output, updates) = async_channel::channel(4);
        output.try_send(marked(row(2, 0, &px(&[1, 2])))).unwrap();
        output.try_send(row(2, 0, &px(&[3]))).unwrap();
        let base = fake_clock();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                deliver(&connection, updates, CNDFIronLogLevel::CNDF_IRON_LOG_INFO, &repeats, || base)
            });
            while lock(&connection.statistics).updates_received != 2 {
                std::thread::yield_now();
            }
            // Let the delivery thread decide on the empty queue and block on it.
            std::thread::sleep(Duration::from_millis(50));
            assert_eq!(lock(&connection.statistics).frames_delivered, 1);
            output.blocking_send(marked(row(2, 1, &px(&[4])))).unwrap();
            drop(output);
        });
        assert_eq!(frames(&host), [px(&[1, 2]), px(&[3, 4])]);
    }

    // A frame's tiles spread past the batch window are still published only at its end.
    #[test]
    fn unfinished_frame_is_not_published_when_the_window_passes() {
        let mut host = Host::default();
        run_queued(
            &mut host,
            vec![
                (0, marked(row(3, 0, &px(&[1, 2, 3])))),
                (1, row(3, 0, &px(&[4]))),
                (20, row(3, 1, &px(&[5]))),
                (40, marked(row(3, 2, &px(&[6])))),
            ],
        );
        assert_eq!(frames(&host), [px(&[1, 2, 3]), px(&[4, 5, 6])]);
    }

    // Multi-region frames queued back to back are each published whole.
    #[test]
    fn queued_multi_region_frames_are_each_published() {
        let mut host = Host::default();
        run_queued(
            &mut host,
            vec![
                (0, marked(row(2, 0, &px(&[1, 2])))),
                (1, row(2, 0, &px(&[3]))),
                (2, marked(row(2, 1, &px(&[4])))),
                (3, row(2, 0, &px(&[5]))),
                (4, marked(row(2, 1, &px(&[6])))),
            ],
        );
        assert_eq!(frames(&host), [px(&[1, 2]), px(&[3, 4]), px(&[5, 6])]);
    }

    // A missing frame end delays the screen to the next frame end, not forever.
    #[test]
    fn a_frame_without_its_end_is_published_with_the_next_end() {
        let mut host = Host::default();
        run_queued(
            &mut host,
            vec![
                (0, marked(row(2, 0, &px(&[1, 2])))),
                (1, pointer()),
                (2, row(2, 0, &px(&[3]))),
                (3, pointer()),
                (30, row(2, 1, &px(&[4]))),
                (31, marked(row(2, 0, &px(&[5])))),
            ],
        );
        assert_eq!(frames(&host), [px(&[1, 2]), px(&[5, 4])]);
    }

    /// Single-update frames of one size queued at `ms` after a baseline frame.
    fn merged_at(ms: u64) -> Vec<Vec<u32>> {
        let mut host = Host::default();
        run_queued(
            &mut host,
            vec![
                (0, marked(row(2, 0, &px(&[1, 2])))),
                (ms, marked(row(2, 0, &px(&[3])))),
                (ms, marked(row(2, 1, &px(&[4])))),
            ],
        );
        frames(&host)
    }

    #[test]
    fn queued_frame_ends_merge_only_within_the_batch_window() {
        assert_eq!(merged_at(15), [px(&[3, 4])]);
        assert_eq!(merged_at(16), [px(&[3, 2]), px(&[3, 4])]);
        assert_eq!(merged_at(17), [px(&[3, 2]), px(&[3, 4])]);
    }

    // The window runs from the oldest unpublished change, not from the last publish.
    #[test]
    fn merge_window_starts_at_the_oldest_unpublished_change() {
        let mut host = Host::default();
        run_queued(
            &mut host,
            vec![
                (0, marked(row(2, 0, &px(&[1, 2])))),
                (0, pointer()),
                (30, marked(row(2, 0, &px(&[3])))),
                (31, marked(row(2, 1, &px(&[4])))),
                (32, marked(row(2, 0, &px(&[5])))),
            ],
        );
        assert_eq!(frames(&host), [px(&[1, 2]), px(&[5, 4])]);
    }

    // A steady backlog of frame ends is published once per window, and the rest once the
    // queue drains.
    #[test]
    fn steady_backlog_publishes_once_per_window() {
        let mut host = Host::default();
        let mut items = vec![(0, marked(row(2, 0, &px(&[1, 2]))))];
        for k in 1..=40u16 {
            items.push((k.into(), marked(row(2, k % 2, &px(&[10 + u32::from(k)])))));
        }
        run_queued(&mut host, items);
        assert_eq!(
            frames(&host),
            [px(&[26, 25]), px(&[42, 43]), px(&[50, 49])]
        );
    }

    // Finding m4-cpu shadow 194 vs 97: the first tile of a server frame arriving more than
    // 16 ms after the last publish was published alone, so each frame was published twice.
    #[test]
    fn multi_region_frame_publishes_once() {
        const TILES: u16 = 260;
        let mut host = Host::default();
        let connection = framed_connection(&mut host);
        let repeats = Arc::<Mutex<Repeats>>::default();
        let (output, updates) = async_channel::channel(usize::from(TILES) + 1);
        std::thread::scope(|scope| {
            scope.spawn(|| {
                deliver(&connection, updates, CNDFIronLogLevel::CNDF_IRON_LOG_INFO, &repeats, Instant::now)
            });
            output
                .blocking_send(marked(row(TILES, 0, &px(&vec![1; TILES.into()]))))
                .unwrap();
            while lock(&connection.statistics).frames_delivered != 1 {
                std::thread::yield_now();
            }
            std::thread::sleep(Duration::from_millis(20));
            for x in 0..TILES {
                let update = row(TILES, x, &px(&[2 + u32::from(x)]));
                let update = if x == TILES - 1 { marked(update) } else { update };
                output.blocking_send(update).unwrap();
            }
            drop(output);
        });
        assert_eq!(lock(&connection.statistics).frames_delivered, 2);
        assert_eq!(lock(&connection.statistics).updates_received, 261);
        let second: Vec<u32> = (0..u32::from(TILES)).map(|x| 2 + x).collect();
        assert_eq!(frames(&host), [px(&vec![1; TILES.into()]), px(&second)]);
    }

    // A tile is composed, and its update with its share of the budget dropped, before the
    // frame's end is even sent.
    #[test]
    fn tiles_are_composed_without_waiting_for_the_frame_end() {
        let mut host = Host::default();
        let connection = framed_connection(&mut host);
        let repeats = Arc::<Mutex<Repeats>>::default();
        let (output, updates) = async_channel::channel(4);
        std::thread::scope(|scope| {
            scope.spawn(|| {
                deliver(&connection, updates, CNDFIronLogLevel::CNDF_IRON_LOG_INFO, &repeats, Instant::now)
            });
            output.blocking_send(marked(row(2, 0, &px(&[1, 2])))).unwrap();
            output.blocking_send(row(2, 0, &px(&[3]))).unwrap();
            let deadline = Instant::now() + Duration::from_secs(5);
            while lock(&connection.statistics).dirty_bytes_composed != 12 {
                assert!(Instant::now() < deadline, "the first tile waits for the frame end");
                std::thread::yield_now();
            }
            output.blocking_send(marked(row(2, 1, &px(&[4])))).unwrap();
            drop(output);
        });
        assert_eq!(frames(&host), [px(&[1, 2]), px(&[3, 4])]);
    }

    #[test]
    fn completed_frame_goes_out_before_a_resize() {
        let mut host = Host::default();
        run_queued(
            &mut host,
            vec![
                (0, marked(row(2, 0, &px(&[1, 2])))),
                (1, marked(row(3, 0, &px(&[3, 4, 5])))),
            ],
        );
        assert_eq!(frames(&host), [px(&[1, 2]), px(&[3, 4, 5])]);
    }

    // An unfinished frame of the old size is dropped, a tile of the new size and its end
    // apply to nothing, and the new size's full update becomes the frame.
    #[test]
    fn resize_drops_an_unfinished_frame_and_waits_for_a_full_update() {
        for full in [false, true] {
            let mut host = Host::default();
            let mut items = vec![
                (0, marked(row(2, 0, &px(&[1, 2])))),
                (0, pointer()),
                (1, row(2, 0, &px(&[3]))),
                (2, marked(row(3, 1, &px(&[9])))),
                (3, pointer()),
                (4, marked(row(2, 1, &px(&[8])))),
            ];
            if full {
                items.push((5, marked(row(3, 0, &px(&[4, 5, 6])))));
            }
            run_queued(&mut host, items);
            let expected = if full {
                vec![px(&[1, 2]), px(&[4, 5, 6])]
            } else {
                vec![px(&[1, 2])]
            };
            assert_eq!(frames(&host), expected, "full={full}");
        }
    }

    #[test]
    fn redelivery_of_a_published_frame_is_immediate_and_full() {
        let mut host = Host::default();
        run_queued(
            &mut host,
            vec![
                (0, marked(row(2, 0, &px(&[1, 2])))),
                (0, pointer()),
                (1, marked(row(2, 1, &px(&[3])))),
                (2, Output::Redeliver),
            ],
        );
        assert_eq!(
            host.frames,
            [
                Captured { pixels: px(&[1, 2]), dirty: (0, 0, 2, 1), sequence: 1 },
                Captured { pixels: px(&[1, 3]), dirty: (1, 0, 1, 1), sequence: 2 },
                Captured { pixels: px(&[1, 3]), dirty: (0, 0, 2, 1), sequence: 3 },
            ]
        );
    }

    // Requests during an unfinished frame become one full publish at its end.
    #[test]
    fn redelivery_while_composing_waits_for_the_frame_end() {
        let mut host = Host::default();
        run_queued(
            &mut host,
            vec![
                (0, marked(row(3, 0, &px(&[1, 2, 3])))),
                (0, pointer()),
                (1, row(3, 0, &px(&[4]))),
                (2, Output::Redeliver),
                (3, Output::Redeliver),
                (4, marked(row(3, 1, &px(&[5])))),
                (5, pointer()),
                (6, marked(row(3, 2, &px(&[6])))),
            ],
        );
        assert_eq!(
            host.frames,
            [
                Captured { pixels: px(&[1, 2, 3]), dirty: (0, 0, 3, 1), sequence: 1 },
                Captured { pixels: px(&[4, 5, 3]), dirty: (0, 0, 3, 1), sequence: 2 },
                Captured { pixels: px(&[4, 5, 6]), dirty: (2, 0, 1, 1), sequence: 3 },
            ]
        );
    }

    /// An unfinished frame, with a redelivery pending, then `end`.
    fn ended_while_composing(end: Output) -> Host {
        let mut host = Host::default();
        run_queued(
            &mut host,
            vec![
                (0, marked(row(2, 0, &px(&[1, 2])))),
                (0, pointer()),
                (1, row(2, 0, &px(&[3]))),
                (2, Output::Redeliver),
                (3, end),
                (4, pointer()),
            ],
        );
        host
    }

    /// A completed frame, then `end`.
    fn ended_after_a_frame(end: Option<Output>) -> Host {
        let mut host = Host::default();
        let mut items = vec![(0, marked(row(2, 0, &px(&[1, 2]))))];
        items.extend(end.map(|end| (1, end)));
        run_queued(&mut host, items);
        host
    }

    #[test]
    fn session_end_publishes_only_a_completed_frame_and_before_the_end() {
        for (name, end) in [
            ("terminated", Some(terminated())),
            ("failure", Some(Output::Failure(errors::PANIC))),
            ("eof", None),
        ] {
            let host = ended_after_a_frame(end);
            assert_eq!(frames(&host), [px(&[1, 2])], "{name}");
            assert_eq!(host.frames_before_end, 1, "{name}");
        }
        for (name, end) in [
            ("terminated", terminated()),
            ("failure", Output::Failure(errors::PANIC)),
        ] {
            let host = ended_while_composing(end);
            assert_eq!(frames(&host), [px(&[1, 2])], "{name}");
            assert!(host.ended, "{name}");
        }
        // The channel closing ends an unfinished frame the same way.
        let mut host = Host::default();
        run_queued(
            &mut host,
            vec![
                (0, marked(row(2, 0, &px(&[1, 2])))),
                (0, pointer()),
                (1, row(2, 0, &px(&[3]))),
                (2, Output::Redeliver),
            ],
        );
        assert_eq!(frames(&host), [px(&[1, 2])]);
    }

    #[test]
    fn terminated_drops_an_unfinished_batch() {
        let mut host = Host::default();
        let connection = framed_connection(&mut host);
        let repeats = Arc::<Mutex<Repeats>>::default();
        let (output, updates) = async_channel::channel(4);
        output.try_send(tile(2, 0, 2)).unwrap();
        output.try_send(terminated()).unwrap();
        drop(output);
        deliver(&connection, updates, CNDFIronLogLevel::CNDF_IRON_LOG_INFO, &repeats, Instant::now);

        assert_eq!(host.frames_before_end, 0);
        assert_eq!(lock(&connection.statistics).frames_delivered, 0);
        assert_eq!(
            host.disconnects,
            [(CNDFIronDisconnectKind::CNDF_IRON_DISCONNECT_SERVER, 0)]
        );
    }

    // After destroy closed the callback gate nothing is published, a completed frame included.
    #[test]
    fn closed_gate_publishes_nothing() {
        let mut host = Host::default();
        let connection = framed_connection(&mut host);
        connection.callbacks.closed.store(true, Ordering::Release);
        let repeats = Arc::<Mutex<Repeats>>::default();
        let (output, updates) = async_channel::channel(4);
        output.try_send(marked(row(2, 0, &px(&[1, 2])))).unwrap();
        output.try_send(Output::Redeliver).unwrap();
        drop(output);
        deliver(&connection, updates, CNDFIronLogLevel::CNDF_IRON_LOG_INFO, &repeats, Instant::now);
        assert!(host.frames.is_empty());
        assert_eq!(lock(&connection.statistics).frames_delivered, 0);
    }

    #[derive(Debug)]
    struct LimitedChannel;

    ironrdp_core::impl_as_any!(LimitedChannel);

    impl ironrdp_svc::SvcProcessor for LimitedChannel {
        fn channel_name(&self) -> ironrdp_pdu::gcc::ChannelName {
            ironrdp_pdu::gcc::ChannelName::from_static(b"rdpsnd\0\0")
        }

        fn max_message_size(&self) -> Option<usize> {
            Some(8)
        }

        fn process(&mut self, _: &[u8]) -> ironrdp_pdu::PduResult<Vec<ironrdp_svc::SvcMessage>> {
            Ok(Vec::new())
        }
    }

    // Finding oversized-channel-unclassified-disconnect: the session ended with only a decode
    // error and disconnect(ERROR, 0), so the host showed no failure.
    #[test]
    fn channel_limit_termination_reports_a_classified_failure() {
        let mut host = Host::default();
        let connection = host_connection(host_callbacks(&mut host));
        // A real channel error: one 4660-byte FIRST fragment on a channel limited to 8 bytes.
        let mut channel = ironrdp_svc::StaticVirtualChannel::new(LimitedChannel);
        let mut chunk = 4660u32.to_le_bytes().to_vec();
        chunk.extend_from_slice(&1u32.to_le_bytes());
        chunk.extend_from_slice(&[0; 16]);
        let error = channel.process(&chunk).unwrap_err();

        deliver_event(
            &connection,
            RdpOutputEvent::Terminated(Err(SessionError::pdu(error))),
            CNDFIronLogLevel::CNDF_IRON_LOG_INFO,
        );

        assert_eq!(
            host.failures,
            [(
                CNDFIronFailureKind::CNDF_IRON_FAILURE_ENGINE,
                0x4952000E,
                CNDFIronStage::CNDF_IRON_STAGE_ACTIVE,
                errors::CHANNEL_MESSAGE_LIMIT.3.to_owned(),
            )]
        );
        assert_eq!(
            host.disconnects,
            [(CNDFIronDisconnectKind::CNDF_IRON_DISCONNECT_ERROR, 0x4952000E)]
        );
        assert!(
            host.logs
                .iter()
                .any(|line| line == "IronRDP channel message limit exceeded: channel=rdpsnd limit=8"),
            "{:?}",
            host.logs
        );
        // The declared length is server data and stays out of every line.
        assert!(host.logs.iter().all(|line| !line.contains("4660")));
        assert!(!errors::CHANNEL_MESSAGE_LIMIT.3.contains('\u{2014}'));
    }

    // An error without a channel limit cause keeps the unclassified disconnect.
    #[test]
    fn other_terminations_report_no_channel_limit_failure() {
        let mut host = Host::default();
        let connection = host_connection(host_callbacks(&mut host));
        let error = ironrdp_pdu::PduError::new(
            "graphics update",
            ironrdp_pdu::PduErrorKind::Other {
                description: "unknown surface",
            },
        );
        deliver_event(
            &connection,
            RdpOutputEvent::Terminated(Err(SessionError::pdu(error))),
            CNDFIronLogLevel::CNDF_IRON_LOG_INFO,
        );
        assert!(host.failures.is_empty());
        assert_eq!(
            host.disconnects,
            [(CNDFIronDisconnectKind::CNDF_IRON_DISCONNECT_ERROR, 0)]
        );
    }

    /// Records the same event three times in one window, so one summary of two is pending.
    fn pending_repeats() -> Arc<Mutex<Repeats>> {
        let repeats = Arc::<Mutex<Repeats>>::default();
        let now = Instant::now();
        for _ in 0..3 {
            let _ = lock(&repeats).record("fast_path", CNDFIronLogLevel::CNDF_IRON_LOG_WARN, now);
        }
        repeats
    }

    // Finding log-repeat-flush-dropped-on-teardown, server and error end: the host ends the
    // generation at the disconnect, so a summary logged after it was lost.
    #[test]
    fn server_end_logs_pending_repeats_before_the_disconnect() {
        let mut host = Host::default();
        let connection = host_connection(host_callbacks(&mut host));
        let repeats = pending_repeats();
        let (output, updates) = async_channel::channel(4);
        output
            .try_send(Output::Rdp(RdpOutputEvent::Terminated(Ok(
                ironrdp_session::GracefulDisconnectReason::ServerInitiated,
            ))))
            .unwrap();
        drop(output);
        deliver(&connection, updates, CNDFIronLogLevel::CNDF_IRON_LOG_INFO, &repeats, Instant::now);

        assert_eq!(host.logs, ["fast_path repeated count=2"]);
        assert_eq!(
            host.disconnects,
            [(CNDFIronDisconnectKind::CNDF_IRON_DISCONNECT_SERVER, 0)]
        );
        // The session thread's own flush at the end finds nothing left to log.
        Logs::flush(&connection, CNDFIronLogLevel::CNDF_IRON_LOG_INFO, &repeats);
        assert_eq!(host.logs.len(), 1);
    }

    #[test]
    fn failure_end_logs_pending_repeats_before_the_failure() {
        let mut host = Host::default();
        let connection = host_connection(host_callbacks(&mut host));
        let repeats = pending_repeats();
        let (output, updates) = async_channel::channel(4);
        output.try_send(Output::Failure(errors::PANIC)).unwrap();
        drop(output);
        deliver(&connection, updates, CNDFIronLogLevel::CNDF_IRON_LOG_INFO, &repeats, Instant::now);

        assert_eq!(host.logs, ["fast_path repeated count=2"]);
        assert_eq!(host.failures.len(), 1);
    }

    // Design iron-autologon-log: a generation whose decoders made 3 pictures on one hardware
    // session, and the summary its end logs.
    fn decoded(connection: &Connection) {
        connection.h264.session(Some(true));
        for _ in 0..3 {
            connection.h264.picture();
        }
    }

    const SUMMARY: &str = "H.264 summary pictures=3 failures=0 idr_waits=0 sessions=1 hardware=yes";

    fn summaries(host: &Host) -> Vec<&str> {
        host.logs
            .iter()
            .map(String::as_str)
            .filter(|line| line.starts_with("H.264 summary"))
            .collect()
    }

    // The host ends the generation at the failure or disconnect (Host drops later logs), so the
    // summary must come first.
    #[test]
    fn every_remote_end_logs_the_h264_summary_before_ending_the_generation() {
        type End = fn(&Arc<Connection>);
        let ends: [(&str, End); 6] = [
            ("server", |connection| {
                deliver_event(
                    connection,
                    RdpOutputEvent::Terminated(Ok(
                        ironrdp_session::GracefulDisconnectReason::ServerInitiated,
                    )),
                    CNDFIronLogLevel::CNDF_IRON_LOG_INFO,
                )
            }),
            ("failure", |connection| report_failure(connection, errors::PANIC)),
            ("logon rejected", |connection| {
                report_failure(connection, errors::LOGON_REJECTED)
            }),
            ("active failure", |connection| {
                report_active_failure(connection, errors::CHANNEL_MESSAGE_LIMIT)
            }),
            ("framebuffer", |connection| {
                report_active_framebuffer_failure(
                    connection,
                    ironrdp_pdu::desktop_framebuffer::DesktopFramebufferError::Allocation,
                )
            }),
            ("worker panic", |connection| {
                connection.worker(|| panic!("synthetic private panic payload"))
            }),
        ];
        for (name, end) in ends {
            let mut host = Host::default();
            let connection = host_connection(host_callbacks(&mut host));
            decoded(&connection);
            end(&connection);
            assert!(host.ended, "{name}");
            assert_eq!(summaries(&host), [SUMMARY], "{name}");
        }
    }

    #[test]
    fn a_generation_without_h264_logs_no_summary() {
        let mut host = Host::default();
        let connection = host_connection(host_callbacks(&mut host));
        report_failure(&connection, errors::PANIC);
        assert!(summaries(&host).is_empty());
    }

    fn session_with_run(host: &mut Host) -> (*mut CNDFIronSession, Arc<Connection>) {
        let table = host_table(host);
        let session = unsafe { cndf_iron_session_create(&table) };
        let owner = unsafe { &*session };
        let connection = host_connection(Arc::clone(&owner.callbacks));
        let (commands, _) = mpsc::sync_channel(1);
        lock(&owner.state).run = Some(Run {
            flush_logs: log_flush(&connection, CNDFIronLogLevel::CNDF_IRON_LOG_INFO, &Arc::default()),
            connection: Arc::clone(&connection),
            commands,
            threads: Vec::new(),
        });
        (session, connection)
    }

    #[test]
    fn destroy_logs_the_h264_summary_before_closing_the_gate() {
        let mut host = Host::default();
        let (session, connection) = session_with_run(&mut host);
        decoded(&connection);

        unsafe { cndf_iron_session_destroy(session, 1000) };

        assert_eq!(summaries(&host), [SUMMARY]);
        assert!(host.disconnects.is_empty());
        // A decode or a remote end after destroy reaches nothing.
        connection.h264.picture();
        report_disconnect(&connection, CNDFIronDisconnectKind::CNDF_IRON_DISCONNECT_SERVER, 0);
        assert!(host.disconnects.is_empty());
        assert_eq!(host.logs.len(), 1);
    }

    #[test]
    fn a_local_and_a_remote_end_racing_log_one_summary_first() {
        for _ in 0..200 {
            let mut host = Box::new(Host::default());
            let (session, connection) = session_with_run(&mut host);
            decoded(&connection);
            let remote = {
                let connection = Arc::clone(&connection);
                thread::spawn(move || {
                    report_disconnect(
                        &connection,
                        CNDFIronDisconnectKind::CNDF_IRON_DISCONNECT_SERVER,
                        0,
                    )
                })
            };
            unsafe { cndf_iron_session_destroy(session, 1000) };
            remote.join().unwrap();
            // Whichever end won, the summary went out once and before any disconnect.
            assert_eq!(summaries(&host), [SUMMARY]);
            assert!(host.disconnects.len() <= 1);
        }
    }

    // Design iron-autologon-log: only an explicit credential rejection of a Client Info logon
    // becomes an authentication failure.
    #[test]
    fn logon_errors_fail_the_session_only_after_a_client_info_logon() {
        use ironrdp_pdu::rdp::session_info::{
            LogonErrorNotificationData::*, LogonErrorNotificationDataErrorCode::*,
            LogonErrorNotificationType::*, LogonErrorsInfo,
        };
        let rejected = LogonErrorsInfo {
            error_type: NtStatus(0xC000006D),
            error_data: ErrorCode(FailedBadPassword),
        };
        assert_eq!(
            logon_failure(true, &rejected),
            Some(Failure(
                CNDFIronFailureKind::CNDF_IRON_FAILURE_AUTHENTICATION,
                0x4952000F,
                CNDFIronStage::CNDF_IRON_STAGE_AUTHENTICATION,
                "Server logon rejected the credentials",
            ))
        );
        assert_eq!(logon_failure(false, &rejected), None);
        let warning = LogonErrorsInfo {
            error_type: NtStatus(0xC000006D),
            error_data: ErrorCode(Warning),
        };
        let session = LogonErrorsInfo {
            error_type: SessionContinue,
            error_data: SessionId(0),
        };
        assert_eq!(logon_failure(true, &warning), None);
        assert_eq!(logon_failure(true, &session), None);
    }

    // Finding log-repeat-flush-dropped-on-teardown, local end: destroy closed the callback gate
    // before the session thread flushed, so the summary was dropped.
    #[test]
    fn destroy_logs_pending_repeats_before_closing_the_gate() {
        let mut host = Host::default();
        let table = host_table(&mut host);
        let session = unsafe { cndf_iron_session_create(&table) };
        let owner = unsafe { &*session };
        let connection = host_connection(Arc::clone(&owner.callbacks));
        let repeats = pending_repeats();
        let (commands, _) = mpsc::sync_channel(1);
        lock(&owner.state).run = Some(Run {
            flush_logs: log_flush(&connection, CNDFIronLogLevel::CNDF_IRON_LOG_INFO, &repeats),
            connection: Arc::clone(&connection),
            commands,
            threads: Vec::new(),
        });

        unsafe { cndf_iron_session_destroy(session, 1000) };

        assert_eq!(host.logs, ["fast_path repeated count=2"]);
        // After destroy the gate is closed and nothing more reaches the host.
        Logs::flush(&connection, CNDFIronLogLevel::CNDF_IRON_LOG_INFO, &pending_repeats());
        assert_eq!(host.logs.len(), 1);
    }
}

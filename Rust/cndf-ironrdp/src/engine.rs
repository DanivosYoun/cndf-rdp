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
) -> std::io::Result<Vec<JoinHandle<()>>> {
    let (output, updates) = async_channel::channel(128);
    let delivery = Arc::clone(&connection);
    let minimum = options.log_level;
    let deliver_thread = thread::Builder::new()
        .name(format!("cndf-iron-{}-deliver", connection.generation))
        .spawn(move || delivery.worker(|| deliver(&delivery, updates, minimum)))?;
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
                    run(&connection, options, commands, &output, clip_jobs.as_ref());
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
        Ok(session_thread) => Ok([Some(session_thread), Some(deliver_thread), clip]
            .into_iter()
            .flatten()
            .collect()),
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
}

impl<S: tracing::Subscriber> Layer<S> for Logs {
    fn on_event(&self, event: &tracing::Event<'_>, _: tracing_subscriber::layer::Context<'_, S>) {
        let metadata = event.metadata();
        let own = matches!(metadata.target(), DISPLAY_LOG_TARGET | TLS_LOG_TARGET);
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
            // These targets contain only display geometry, scale factors and TLS parameters.
            let mut message = SafeLogMessage::default();
            event.record(&mut message);
            log(&self.connection, self.minimum, level, &message.0);
        } else {
            // Other IronRDP event fields may contain session data.
            log(&self.connection, self.minimum, level, metadata.name());
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
    let config = config.with_audio_wave_observer(Arc::new(move || {
        lock(&audio_statistics).audio_waves_received += 1;
    }));
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

fn deliver(
    connection: &Connection,
    mut updates: async_channel::Receiver<Output>,
    minimum: CNDFIronLogLevel,
) {
    let mut frame = Frame::default();
    let mut batch = Instant::now();
    let mut pending = None;
    while let Some(update) = pending.take().or_else(|| updates.blocking_recv()) {
        match update {
            Output::Rdp(RdpOutputEvent::DesktopUpdate(update)) => {
                if frame.changes_size(&update) {
                    frame.publish(connection, false);
                    batch = Instant::now();
                }
                let bytes = match frame.compose(&update) {
                    Ok(bytes) => bytes,
                    Err(error) => {
                        connection.stop.store(true, Ordering::Release);
                        report_active_framebuffer_failure(connection, error);
                        return;
                    }
                };
                let mut statistics = lock(&connection.statistics);
                statistics.updates_received += 1;
                statistics.dirty_bytes_composed += bytes;
            }
            other => match other {
                Output::Failure(failure) => {
                    frame.publish(connection, false);
                    report_failure(connection, failure);
                }
                Output::Rdp(event) => {
                    if matches!(event, RdpOutputEvent::Terminated(_)) {
                        frame.publish(connection, false);
                    }
                    deliver_event(connection, event, minimum);
                }
                Output::Redeliver => frame.publish(connection, true),
            },
        }
        pending = updates.try_recv().ok();
        if pending.is_none() || batch.elapsed() >= Duration::from_millis(16) {
            frame.publish(connection, false);
            batch = Instant::now();
        }
    }
    connection.connected.store(false, Ordering::Release);
}

fn report_failure(connection: &Connection, Failure(kind, code, stage, message): Failure) {
    connection.connected.store(false, Ordering::Release);
    connection
        .callbacks
        .failure(connection.generation, kind, code, stage, message);
}

fn report_disconnect(connection: &Connection, kind: CNDFIronDisconnectKind, code: u32) {
    connection.connected.store(false, Ordering::Release);
    connection.callbacks.invoke(|table| {
        if let Some(callback) = table.disconnect {
            callback(connection.generation, kind, code, table.context);
        }
    });
}

fn report_active_framebuffer_failure(
    connection: &Connection,
    error: ironrdp_pdu::desktop_framebuffer::DesktopFramebufferError,
) {
    let failure = errors::framebuffer_failure(error, CNDFIronStage::CNDF_IRON_STAGE_ACTIVE);
    let code = failure.1;
    report_failure(connection, failure);
    report_disconnect(
        connection,
        CNDFIronDisconnectKind::CNDF_IRON_DISCONNECT_ERROR,
        code,
    );
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
}

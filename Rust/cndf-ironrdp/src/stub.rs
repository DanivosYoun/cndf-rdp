use super::*;
use std::ffi::CString;

enum Output {
    Connected,
    Rejected,
    Frame(u32, u32, u8, bool),
    Disconnected,
}

pub(super) fn start_workers(
    connection: Arc<Connection>,
    options: Options,
    commands: Receiver<Command>,
    ready: Receiver<()>,
) -> std::io::Result<Vec<JoinHandle<()>>> {
    let (output, updates) = mpsc::sync_channel(128);
    let delivery = Arc::clone(&connection);
    let deliver = thread::Builder::new()
        .name(format!("cndf-iron-{}-deliver", connection.generation))
        .spawn(move || delivery.worker(|| deliver(&delivery, updates)))?;
    let clip = if options.channels.clipboard {
        let (send, receive) = mpsc::channel();
        let clipboard = Arc::clone(&connection);
        let worker = thread::Builder::new()
            .name(format!("cndf-iron-{}-clip", connection.generation))
            .spawn(move || clipboard.worker(|| clipboard::run_stub(&clipboard, receive)))?;
        *lock(&connection.clipboard) = Some(send);
        Some(worker)
    } else {
        None
    };
    let session_connection = Arc::clone(&connection);
    let session = thread::Builder::new()
        .name(format!("cndf-iron-{}-session", connection.generation))
        .spawn(move || {
            let connection = session_connection;
            connection.worker(|| {
                if ready.recv().is_ok() {
                    run(&connection, options, commands, output);
                    lock(&connection.clipboard).take();
                }
            })
        });
    match session {
        Ok(session) => Ok([Some(session), Some(deliver), clip]
            .into_iter()
            .flatten()
            .collect()),
        Err(error) => {
            lock(&connection.clipboard).take();
            if let Some(clip) = clip {
                let _ = clip.join();
            }
            let _ = deliver.join();
            Err(error)
        }
    }
}

fn run(
    connection: &Connection,
    options: Options,
    commands: Receiver<Command>,
    output: SyncSender<Output>,
) {
    let Ok(hostname) = CString::new(options.host) else {
        return;
    };
    // A deterministic DER sequence for exercising the adapter's trust flow.
    let der = [0x30u8, 0x00];
    let pointers = [der.as_ptr()];
    let lengths = [der.len()];
    let chain = CNDFIronCertificateChain {
        der: pointers.as_ptr(),
        der_length: lengths.as_ptr(),
        count: 1,
        hostname: hostname.as_ptr(),
        port: options.port,
        problems: CNDF_IRON_CERT_CHAIN_UNTRUSTED,
    };
    let generation = connection.generation;
    let level = CNDFIronLogLevel::CNDF_IRON_LOG_INFO;
    if (options.log_level as u32) <= (level as u32) {
        connection.callbacks.invoke(|table| {
            if let Some(callback) = table.log {
                let message = b"Starting IronRDP stub";
                callback(
                    generation,
                    level,
                    message.as_ptr(),
                    message.len(),
                    table.context,
                );
            }
        });
    }

    let accepted = connection
        .callbacks
        .invoke(|table| {
            table
                .certificate_trust
                .is_some_and(|callback| callback(generation, &chain, table.context))
        })
        .unwrap_or(false);
    if !accepted {
        let _ = output.send(Output::Rejected);
        return;
    }
    if connection.stop.load(Ordering::Acquire) {
        let _ = output.send(Output::Disconnected);
        return;
    }
    let (mut width, mut height) = (options.width, options.height);
    let mut marker = 0u8;
    let _ = output.send(Output::Connected);
    let _ = output.send(Output::Frame(width, height, marker, true));
    while !connection.stop.load(Ordering::Acquire) {
        match commands.recv_timeout(Duration::from_millis(5)) {
            Ok(Command::Input(events)) => {
                lock(&connection.statistics).input_events_sent += events.len() as u64;
                for event in events {
                    marker = marker.wrapping_add(1).wrapping_add(event.code as u8);
                }
                let _ = output.send(Output::Frame(width, height, marker, true));
            }
            Ok(Command::Resize(w, h)) => {
                (width, height) = (w, h);
                let _ = output.send(Output::Frame(width, height, marker, true));
            }
            Ok(Command::Redeliver) => {
                let _ = output.send(Output::Frame(width, height, marker, false));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    let _ = output.send(Output::Disconnected);
}

fn deliver(connection: &Connection, updates: Receiver<Output>) {
    let generation = connection.generation;
    let mut sequence = 0;
    let mut pixels = Vec::new();
    for update in updates {
        match update {
            Output::Connected => {
                connection.connected.store(true, Ordering::Release);
                connection.callbacks.invoke(|table| {
                    if let Some(callback) = table.connected {
                        callback(generation, table.context);
                    }
                });
                connection.callbacks.invoke(|table| {
                    if let Some(callback) = table.pointer {
                        callback(
                            generation,
                            CNDFIronPointerKind::CNDF_IRON_POINTER_DEFAULT,
                            ptr::null(),
                            0,
                            0,
                            0,
                            0,
                            0,
                            table.context,
                        );
                    }
                });
            }
            Output::Rejected => connection.callbacks.failure(
                generation,
                CNDFIronFailureKind::CNDF_IRON_FAILURE_CERTIFICATE,
                0x49520002,
                CNDFIronStage::CNDF_IRON_STAGE_NEGOTIATION,
                "Certificate rejected",
            ),
            Output::Frame(width, height, marker, redraw) => {
                if redraw {
                    pixels.resize((width * height * 4) as usize, 0);
                    for (index, pixel) in pixels.chunks_exact_mut(4).enumerate() {
                        let x = index % width as usize;
                        let y = index / width as usize;
                        pixel.copy_from_slice(&[x as u8, y as u8, marker, 255]);
                    }
                    let mut statistics = lock(&connection.statistics);
                    statistics.updates_received += 1;
                    statistics.dirty_bytes_composed += pixels.len() as u64;
                }
                sequence += 1;
                let dirty = CNDFIronRect {
                    x: 0,
                    y: 0,
                    width,
                    height,
                };
                connection.callbacks.invoke(|table| {
                    if let Some(callback) = table.frame {
                        {
                            let mut statistics = lock(&connection.statistics);
                            statistics.frames_delivered += 1;
                            statistics.frame_bytes_delivered += pixels.len() as u64;
                        }
                        callback(
                            generation,
                            pixels.as_ptr(),
                            width,
                            height,
                            width * 4,
                            dirty,
                            sequence,
                            table.context,
                        );
                    }
                });
            }
            Output::Disconnected => {
                connection.connected.store(false, Ordering::Release);
                connection.callbacks.invoke(|table| {
                    if let Some(callback) = table.disconnect {
                        callback(
                            generation,
                            CNDFIronDisconnectKind::CNDF_IRON_DISCONNECT_LOCAL_REQUEST,
                            0,
                            table.context,
                        );
                    }
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::c_void;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Probe {
        trust: AtomicUsize,
        frames: SyncSender<(u64, u64, [u8; 4])>,
        clipboard: SyncSender<(u64, Vec<u8>)>,
    }

    extern "C" fn trust(_: u64, _: *const CNDFIronCertificateChain, context: *mut c_void) -> bool {
        let probe = unsafe { &*context.cast::<Probe>() };
        probe.trust.fetch_add(1, Ordering::Relaxed);
        true
    }

    extern "C" fn frame(
        generation: u64,
        bgra: *const u8,
        _: u32,
        _: u32,
        _: u32,
        _: CNDFIronRect,
        sequence: u64,
        context: *mut c_void,
    ) {
        let probe = unsafe { &*context.cast::<Probe>() };
        let pixel = unsafe { bgra.cast::<[u8; 4]>().read() };
        let _ = probe.frames.try_send((generation, sequence, pixel));
    }

    extern "C" fn remote_text(generation: u64, bytes: *const u8, len: usize, context: *mut c_void) {
        let probe = unsafe { &*context.cast::<Probe>() };
        let bytes = unsafe { std::slice::from_raw_parts(bytes, len) };
        let _ = probe.clipboard.try_send((generation, bytes.to_vec()));
    }

    extern "C" fn remote_file_list(
        generation: u64,
        files: *const CNDFIronRemoteFile,
        len: usize,
        context: *mut c_void,
    ) {
        if len == 1 {
            let file = unsafe { &*files };
            remote_text(generation, file.name_utf8, file.name_length, context);
        }
    }

    extern "C" fn remote_file_contents(
        generation: u64,
        stream: u32,
        ok: bool,
        bytes: *const u8,
        len: usize,
        context: *mut c_void,
    ) {
        if ok {
            remote_text(generation, bytes, len, context);
        } else if bytes.is_null() && len == 0 {
            let probe = unsafe { &*context.cast::<Probe>() };
            let _ = probe
                .clipboard
                .try_send((generation, stream.to_le_bytes().to_vec()));
        }
    }

    #[test]
    fn stub_abi_delivers_frames_and_echoes_only_current_input() {
        let (send, receive) = mpsc::sync_channel(8);
        let (clip_send, clip_receive) = mpsc::sync_channel(8);
        let mut probe = Probe {
            trust: AtomicUsize::new(0),
            frames: send,
            clipboard: clip_send,
        };
        let callbacks = CNDFIronCallbacks {
            log: None,
            certificate_trust: Some(trust),
            connected: None,
            failure: None,
            disconnect: None,
            frame: Some(frame),
            pointer: None,
            remote_text: Some(remote_text),
            remote_file_list: Some(remote_file_list),
            remote_file_contents: Some(remote_file_contents),
            context: (&mut probe as *mut Probe).cast(),
        };
        let options = CNDFIronConnectOptions {
            struct_size: std::mem::size_of::<CNDFIronConnectOptions>() as u32,
            host: c"localhost".as_ptr(),
            port: 3389,
            username: c"stub".as_ptr(),
            domain: ptr::null(),
            desktop_width: 16,
            desktop_height: 16,
            scale_percent: 100,
            color_depth: 32,
            graphics_pipeline: true,
            log_level: CNDFIronLogLevel::CNDF_IRON_LOG_OFF,
            clipboard: true,
            drive_path: ptr::null(),
            drive_name: ptr::null(),
            audio_mode: CNDFIronAudioMode::CNDF_IRON_AUDIO_OFF,
        };
        let (generation, sequence, pixel) = unsafe {
            let session = cndf_iron_session_create(&callbacks);
            let mut generation = 0;
            assert_eq!(
                cndf_iron_connect(session, &options, ptr::null(), 0, &mut generation),
                CNDF_IRON_OK
            );
            assert_eq!(
                receive.recv_timeout(Duration::from_secs(2)).unwrap(),
                (generation, 1, [0, 0, 0, 255])
            );
            let event = CNDFIronInputEvent {
                kind: CNDFIronInputKind::CNDF_IRON_INPUT_KEY,
                code: 3,
                extended: false,
                pressed: true,
                button: CNDFIronPointerButton::CNDF_IRON_BUTTON_LEFT,
                x: 0,
                y: 0,
                delta_x: 0,
                delta_y: 0,
            };
            assert_eq!(
                cndf_iron_send_input(session, generation + 1, &event, 1, 0),
                CNDF_IRON_NOT_CONNECTED
            );
            assert_eq!(
                cndf_iron_send_input(session, generation, &event, 1, 1000),
                CNDF_IRON_OK
            );
            let result = receive.recv_timeout(Duration::from_secs(2)).unwrap();
            assert_eq!(result.0, generation);
            assert_eq!(cndf_iron_redeliver_frame(session, generation), CNDF_IRON_OK);
            assert_eq!(
                receive.recv_timeout(Duration::from_secs(2)).unwrap(),
                (generation, 3, result.2)
            );
            let text = "한글";
            assert_eq!(
                cndf_iron_clipboard_offer_text(session, generation + 1, text.as_ptr(), text.len()),
                CNDF_IRON_NOT_CONNECTED
            );
            assert_eq!(
                cndf_iron_clipboard_offer_text(session, generation, text.as_ptr(), text.len()),
                CNDF_IRON_OK
            );
            assert_eq!(
                clip_receive.recv_timeout(Duration::from_secs(2)).unwrap(),
                (generation, text.as_bytes().to_vec())
            );
            let path = std::env::temp_dir().join(format!("cndf-iron-stub-{}", std::process::id()));
            std::fs::write(&path, b"file").unwrap();
            let path_c = CString::new(path.to_str().unwrap()).unwrap();
            let name = c"root\\한글.txt";
            let file = CNDFIronLocalFile {
                path: path_c.as_ptr(),
                name: name.as_ptr(),
                size: 4,
            };
            assert_eq!(
                cndf_iron_clipboard_offer_files(session, generation, &file, 1),
                CNDF_IRON_OK
            );
            assert_eq!(
                clip_receive.recv_timeout(Duration::from_secs(2)).unwrap(),
                (generation, name.to_bytes().to_vec())
            );
            assert_eq!(
                cndf_iron_clipboard_request_file_range(session, generation, 3, 0, 0, 4),
                CNDF_IRON_OK
            );
            assert_eq!(
                clip_receive.recv_timeout(Duration::from_secs(2)).unwrap(),
                (generation, b"file".to_vec())
            );
            assert_eq!(
                cndf_iron_clipboard_request_file_range(session, generation, 4, 1, 0, 4),
                CNDF_IRON_OK
            );
            assert_eq!(
                clip_receive.recv_timeout(Duration::from_secs(2)).unwrap(),
                (generation, 4_u32.to_le_bytes().to_vec())
            );
            cndf_iron_session_destroy(session, 2000);
            std::fs::remove_file(path).unwrap();
            result
        };
        assert_eq!((generation, sequence, pixel), (1, 2, [0, 0, 4, 255]));
        assert_eq!(probe.trust.load(Ordering::Relaxed), 1);
        assert!(receive.recv_timeout(Duration::from_millis(30)).is_err());
        assert!(clip_receive
            .recv_timeout(Duration::from_millis(30))
            .is_err());
        assert_eq!(cndf_iron_capabilities(), 0xf);
    }
}

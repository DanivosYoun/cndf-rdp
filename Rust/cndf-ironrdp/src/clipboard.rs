use super::*;

use std::io::{Read, Seek, SeekFrom};

#[derive(Clone)]
pub(super) struct LocalFile {
    path: String,
    name: String,
    size: u64,
}

pub(super) enum ClipboardCommand {
    Text(String),
    Files(Vec<LocalFile>),
    Range {
        stream_id: u32,
        list_index: u32,
        offset: u64,
        length: u32,
    },
}

#[no_mangle]
pub extern "C" fn cndf_iron_capabilities() -> u32 {
    ffi(0, || {
        CNDF_IRON_CAP_CLIPBOARD
            | CNDF_IRON_CAP_DRIVE
            | CNDF_IRON_CAP_AUDIO_LOCAL
            | CNDF_IRON_CAP_AUDIO_REMOTE
    })
}

unsafe fn input_slice<'a, T>(data: *const T, count: usize) -> Option<&'a [T]> {
    if count == 0 {
        return Some(&[]);
    }
    if data.is_null() || count > isize::MAX as usize / std::mem::size_of::<T>() {
        return None;
    }
    Some(std::slice::from_raw_parts(data, count))
}

fn submit(session: &CNDFIronSession, generation: u64, command: ClipboardCommand) -> CNDFIronStatus {
    let state = lock(&session.state);
    let Some(run) = state.run.as_ref() else {
        return CNDF_IRON_NOT_CONNECTED;
    };
    let connection = &run.connection;
    if connection.generation != generation
        || connection.stop.load(Ordering::Acquire)
        || !connection.connected.load(Ordering::Acquire)
    {
        return CNDF_IRON_NOT_CONNECTED;
    }
    #[cfg(feature = "stub")]
    if let Some(sender) = lock(&connection.clipboard).as_ref() {
        return if sender.send(command).is_ok() {
            CNDF_IRON_OK
        } else {
            CNDF_IRON_NOT_CONNECTED
        };
    }
    #[cfg(not(feature = "stub"))]
    if let Some(channel) = lock(&connection.clipboard).as_ref() {
        return channel.submit(command);
    }
    CNDF_IRON_NOT_CONNECTED
}

/// Copies UTF-8 text into the clipboard command queue.
#[no_mangle]
pub unsafe extern "C" fn cndf_iron_clipboard_offer_text(
    session: *mut CNDFIronSession,
    generation: u64,
    utf8: *const u8,
    length: usize,
) -> CNDFIronStatus {
    ffi(CNDF_IRON_INTERNAL, || {
        let Some(session) = session.as_ref() else {
            return CNDF_IRON_INVALID_ARGUMENT;
        };
        let Some(text) =
            input_slice(utf8, length).and_then(|bytes| std::str::from_utf8(bytes).ok())
        else {
            return CNDF_IRON_INVALID_ARGUMENT;
        };
        submit(session, generation, ClipboardCommand::Text(text.to_owned()))
    })
}

/// Copies local file metadata into the clipboard command queue.
#[no_mangle]
pub unsafe extern "C" fn cndf_iron_clipboard_offer_files(
    session: *mut CNDFIronSession,
    generation: u64,
    files: *const CNDFIronLocalFile,
    count: usize,
) -> CNDFIronStatus {
    ffi(CNDF_IRON_INTERNAL, || {
        let Some(session) = session.as_ref() else {
            return CNDF_IRON_INVALID_ARGUMENT;
        };
        let Some(files) = input_slice(files, count) else {
            return CNDF_IRON_INVALID_ARGUMENT;
        };
        let mut owned = Vec::with_capacity(count);
        for file in files {
            let (Some(path), Some(name)) = (text(file.path), text(file.name)) else {
                return CNDF_IRON_INVALID_ARGUMENT;
            };
            if !std::path::Path::new(&path).is_absolute() || name.is_empty() {
                return CNDF_IRON_INVALID_ARGUMENT;
            }
            owned.push(LocalFile {
                path,
                name,
                size: file.size,
            });
        }
        submit(session, generation, ClipboardCommand::Files(owned))
    })
}

/// Queues a range request for an active, ready clipboard channel.
#[no_mangle]
pub unsafe extern "C" fn cndf_iron_clipboard_request_file_range(
    session: *mut CNDFIronSession,
    generation: u64,
    stream_id: u32,
    list_index: u32,
    offset: u64,
    length: u32,
) -> CNDFIronStatus {
    ffi(CNDF_IRON_INTERNAL, || {
        let Some(session) = session.as_ref() else {
            return CNDF_IRON_INVALID_ARGUMENT;
        };
        submit(
            session,
            generation,
            ClipboardCommand::Range {
                stream_id,
                list_index,
                offset,
                length,
            },
        )
    })
}

#[cfg(feature = "stub")]
pub(super) fn run_stub(connection: &Connection, commands: Receiver<ClipboardCommand>) {
    let mut files = Vec::new();
    while !connection.stop.load(Ordering::Acquire) {
        let command = match commands.recv_timeout(Duration::from_millis(5)) {
            Ok(command) => command,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        };
        match command {
            ClipboardCommand::Text(text) => {
                files.clear();
                notify_text(connection, &text);
            }
            ClipboardCommand::Files(offer) => {
                files = offer;
                notify_files(
                    connection,
                    files.iter().map(|file| (file.name.as_str(), file.size)),
                );
            }
            ClipboardCommand::Range {
                stream_id,
                list_index,
                offset,
                length,
            } => {
                let bytes = files
                    .get(list_index as usize)
                    .and_then(|file| read_range(file, offset, length));
                notify_range(connection, stream_id, bytes.as_deref());
            }
        }
    }
}

const MAX_FILE_RANGE_LENGTH: u32 = 64 * 1024 * 1024;

fn read_range(file: &LocalFile, offset: u64, length: u32) -> Option<Vec<u8>> {
    if length > MAX_FILE_RANGE_LENGTH || offset.checked_add(u64::from(length))? > file.size {
        return None;
    }
    let mut source = std::fs::File::open(&file.path).ok()?;
    source.seek(SeekFrom::Start(offset)).ok()?;
    let mut bytes = vec![0; length as usize];
    source.read_exact(&mut bytes).ok()?;
    Some(bytes)
}

fn notify_text(connection: &Connection, text: &str) {
    connection.callbacks.invoke(|table| {
        if let Some(callback) = table.remote_text {
            callback(
                connection.generation,
                text.as_ptr(),
                text.len(),
                table.context,
            );
        }
    });
}

fn notify_files<'a>(connection: &Connection, files: impl Iterator<Item = (&'a str, u64)>) {
    let descriptors: Vec<_> = files
        .map(|(name, size)| CNDFIronRemoteFile {
            name_utf8: name.as_ptr(),
            name_length: name.len(),
            size,
        })
        .collect();
    connection.callbacks.invoke(|table| {
        if let Some(callback) = table.remote_file_list {
            callback(
                connection.generation,
                descriptors.as_ptr(),
                descriptors.len(),
                table.context,
            );
        }
    });
}

fn notify_range(connection: &Connection, stream_id: u32, bytes: Option<&[u8]>) {
    connection.callbacks.invoke(|table| {
        if let Some(callback) = table.remote_file_contents {
            let (data, count) =
                bytes.map_or((ptr::null(), 0), |bytes| (bytes.as_ptr(), bytes.len()));
            callback(
                connection.generation,
                stream_id,
                bytes.is_some(),
                data,
                count,
                table.context,
            );
        }
    });
}

#[cfg(not(feature = "stub"))]
pub(super) use real::{Channel, ClipWork, Job};

#[cfg(not(feature = "stub"))]
mod real {
    use super::*;
    use ironrdp_client::rdp::RdpInputSender;
    use ironrdp_cliprdr::backend::{
        ClipboardMessage as Message, CliprdrBackend, CliprdrBackendFactory,
    };
    use ironrdp_cliprdr::pdu::{
        ClipboardFileAttributes, ClipboardFormat, ClipboardFormatId,
        ClipboardGeneralCapabilityFlags as Capabilities, FileContentsFlags, FileContentsRequest,
        FileContentsResponse, FileDescriptor, FormatDataRequest, FormatDataResponse, LockDataId,
    };
    use ironrdp_core::IntoOwned;
    use std::collections::{HashSet, VecDeque};

    fn read_file_contents_range(file: &LocalFile, offset: u64, length: u32) -> Option<Vec<u8>> {
        if length > MAX_FILE_RANGE_LENGTH {
            return None;
        }
        // Windows requests a full buffer even if fewer bytes remain in the file.
        let available = file.size.checked_sub(offset)?;
        let length = u64::from(length).min(available) as u32;
        read_range(file, offset, length)
    }

    pub(crate) type Job = Box<dyn FnOnce(&Connection) + Send>;

    pub(crate) struct ClipWork;
    impl ClipWork {
        pub(crate) fn spawn(
            connection: Arc<Connection>,
        ) -> std::io::Result<(mpsc::Sender<Job>, JoinHandle<()>)> {
            let (send, recv) = mpsc::channel::<Job>();
            let worker = thread::Builder::new()
                .name(format!("cndf-iron-{}-clip", connection.generation))
                .spawn(move || {
                    connection.worker(|| {
                        while !connection.stop.load(Ordering::Acquire) {
                            match recv.recv_timeout(Duration::from_millis(5)) {
                                Ok(job) => job(&connection),
                                Err(mpsc::RecvTimeoutError::Timeout) => {}
                                Err(mpsc::RecvTimeoutError::Disconnected) => break,
                            }
                        }
                    })
                })?;
            Ok((send, worker))
        }
    }

    #[derive(Default)]
    enum Offer {
        #[default]
        Empty,
        Text(String),
        Files(Vec<LocalFile>),
    }

    #[derive(Default)]
    struct State {
        ready: bool,
        dirty_offer: bool,
        negotiated: Option<Capabilities>,
        offer: Offer,
        advertised: Vec<Arc<LocalFile>>,
        deferred_paste: Option<(ClipboardFormatId, bool)>,
        pastes: VecDeque<bool>,
        requests: HashSet<u32>,
    }

    #[derive(Clone)]
    pub(crate) struct Channel {
        state: Arc<Mutex<State>>,
        input: RdpInputSender,
        work: mpsc::Sender<Job>,
        #[cfg(test)]
        messages: Option<mpsc::Sender<Message>>,
    }

    impl Channel {
        pub(crate) fn new(input: RdpInputSender, work: mpsc::Sender<Job>) -> Self {
            Self {
                state: Arc::default(),
                input,
                work,
                #[cfg(test)]
                messages: None,
            }
        }

        fn send(&self, message: Message) -> bool {
            #[cfg(test)]
            if let Some(messages) = &self.messages {
                return messages.send(message).is_ok();
            }
            self.input.send_clipboard(message).is_ok()
        }

        fn queue(&self, job: impl FnOnce(&Connection) + Send + 'static) {
            let _ = self.work.send(Box::new(job));
        }

        fn advertise(&self, state: &mut State) -> bool {
            state.advertised.clear();
            let Offer::Files(files) = &state.offer else {
                let formats = if matches!(state.offer, Offer::Text(_)) {
                    vec![ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)]
                } else {
                    Vec::new()
                };
                return self.send(Message::SendInitiateCopy(formats));
            };
            if !state
                .negotiated
                .is_some_and(|flags| flags.contains(Capabilities::STREAM_FILECLIP_ENABLED))
            {
                self.queue(|connection| {
                    connection.clip_log(
                        CNDFIronLogLevel::CNDF_IRON_LOG_WARN,
                        "Clipboard server did not negotiate file streaming",
                    )
                });
                return true;
            }
            let mut descriptors = Vec::with_capacity(files.len());
            for file in files {
                let (relative_path, name) = match file.name.rsplit_once('\\') {
                    Some((parent, name)) => (Some(parent.to_owned()), name),
                    None => (None, file.name.as_str()),
                };
                // Keep the I/O index aligned with the entries retained by initiate_file_copy.
                if name.is_empty()
                    || file.name.chars().count() > 259
                    || file.name.starts_with(['/', '\\'])
                    || file.name.as_bytes().get(1) == Some(&b':')
                {
                    continue;
                }
                let mut descriptor = FileDescriptor::new(name)
                    .with_attributes(ClipboardFileAttributes::NORMAL)
                    .with_file_size(file.size);
                descriptor.relative_path = relative_path;
                descriptors.push(descriptor);
                state.advertised.push(Arc::new(file.clone()));
            }
            let rejected = files.len() - descriptors.len();
            if rejected != 0 {
                self.queue(move |connection| {
                    connection.clip_log(
                        CNDFIronLogLevel::CNDF_IRON_LOG_WARN,
                        &format!("Clipboard file offer rejected descriptors count={rejected}"),
                    );
                });
            }
            if descriptors.is_empty() {
                return self.send(Message::SendInitiateCopy(Vec::new()));
            }
            self.send(Message::SendInitiateFileCopy(descriptors))
        }

        pub(crate) fn submit(&self, command: ClipboardCommand) -> CNDFIronStatus {
            let mut state = lock(&self.state);
            let sent = match command {
                ClipboardCommand::Text(text) => {
                    state.offer = Offer::Text(text);
                    state.dirty_offer = !state.ready;
                    !state.ready || self.advertise(&mut state)
                }
                ClipboardCommand::Files(files) => {
                    state.offer = Offer::Files(files);
                    state.dirty_offer = !state.ready;
                    !state.ready || self.advertise(&mut state)
                }
                ClipboardCommand::Range {
                    stream_id,
                    list_index,
                    offset,
                    length,
                } => {
                    if !state.ready {
                        return CNDF_IRON_NOT_CONNECTED;
                    }
                    let Ok(index) = i32::try_from(list_index) else {
                        self.queue(move |connection| notify_range(connection, stream_id, None));
                        return CNDF_IRON_OK;
                    };
                    if !self.send(Message::SendFileContentsRequest(FileContentsRequest {
                        stream_id,
                        index,
                        flags: FileContentsFlags::RANGE,
                        position: offset,
                        requested_size: length,
                        data_id: None,
                    })) {
                        return CNDF_IRON_NOT_CONNECTED;
                    }
                    state.requests.insert(stream_id);
                    true
                }
            };
            if sent {
                CNDF_IRON_OK
            } else {
                CNDF_IRON_NOT_CONNECTED
            }
        }

        fn paste(&self, state: &mut State, id: ClipboardFormatId, file: bool) {
            if self.send(Message::SendInitiatePaste(id)) {
                state.pastes.push_back(file);
            }
        }
    }

    impl CliprdrBackendFactory for Channel {
        fn build_cliprdr_backend(&self) -> Box<dyn CliprdrBackend> {
            Box::new(CndfCliprdrBackend(self.clone()))
        }
    }

    struct CndfCliprdrBackend(Channel);
    ironrdp_core::impl_as_any!(CndfCliprdrBackend);

    impl std::fmt::Debug for CndfCliprdrBackend {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("CndfCliprdrBackend")
        }
    }

    impl Drop for CndfCliprdrBackend {
        fn drop(&mut self) {
            let mut state = lock(&self.0.state);
            state.ready = false;
            for stream in state.requests.drain() {
                self.0
                    .queue(move |connection| notify_range(connection, stream, None));
            }
        }
    }

    fn choose_format(formats: &[ClipboardFormat]) -> Option<(ClipboardFormatId, bool)> {
        formats.iter().find_map(|format| {
            if format
                .name
                .as_ref()
                .is_some_and(|name| name.value() == "FileGroupDescriptorW")
            {
                Some((format.id, true))
            } else if format.id == ClipboardFormatId::CF_UNICODETEXT {
                Some((format.id, false))
            } else {
                None
            }
        })
    }

    fn remote_name(file: &FileDescriptor) -> String {
        match file.relative_path.as_deref() {
            Some(path) if !path.is_empty() => format!("{path}\\{}", file.name),
            _ => file.name.clone(),
        }
    }

    fn decode_text(data: &[u8]) -> Option<String> {
        let mut units = Vec::new();
        let mut chunks = data.chunks_exact(2);
        for chunk in &mut chunks {
            let unit = u16::from_le_bytes([chunk[0], chunk[1]]);
            if unit == 0 {
                return String::from_utf16(&units).ok();
            }
            units.push(unit);
        }
        if !chunks.remainder().is_empty() {
            return None;
        }
        String::from_utf16(&units).ok()
    }

    impl CliprdrBackend for CndfCliprdrBackend {
        fn temporary_directory(&self) -> &str {
            ""
        }

        fn client_capabilities(&self) -> Capabilities {
            Capabilities::USE_LONG_FORMAT_NAMES
                | Capabilities::STREAM_FILECLIP_ENABLED
                | Capabilities::FILECLIP_NO_FILE_PATHS
                | Capabilities::HUGE_FILE_SUPPORT_ENABLED
        }

        fn on_ready(&mut self) {
            let mut state = lock(&self.0.state);
            state.ready = true;
            // Offers can change while the initial format list is awaiting acknowledgment.
            if state.dirty_offer {
                self.0.advertise(&mut state);
            }
            if let Some((id, file)) = state.deferred_paste.take() {
                self.0.paste(&mut state, id, file);
            }
        }

        fn on_request_format_list(&mut self) {
            let mut state = lock(&self.0.state);
            state.dirty_offer = matches!(state.offer, Offer::Files(_));
            let formats = if matches!(state.offer, Offer::Text(_)) {
                vec![ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)]
            } else {
                Vec::new()
            };
            self.0.send(Message::SendInitiateCopy(formats));
        }

        fn on_process_negotiated_capabilities(&mut self, capabilities: Capabilities) {
            lock(&self.0.state).negotiated = Some(capabilities);
        }

        fn on_remote_copy(&mut self, formats: &[ClipboardFormat]) {
            let mut state = lock(&self.0.state);
            let choice = choose_format(formats);
            if !state.ready {
                state.deferred_paste = choice;
            } else if let Some((id, file)) = choice {
                self.0.paste(&mut state, id, file);
            }
        }

        fn on_format_data_request(&mut self, request: FormatDataRequest) {
            let state = lock(&self.0.state);
            let response = match &state.offer {
                Offer::Text(text) if request.format == ClipboardFormatId::CF_UNICODETEXT => {
                    FormatDataResponse::new_unicode_string(text)
                }
                _ => FormatDataResponse::new_error(),
            };
            self.0.send(Message::SendFormatData(response.into_owned()));
        }

        fn on_format_data_response(&mut self, response: FormatDataResponse<'_>) {
            let requested_file = lock(&self.0.state).pastes.pop_front();
            if response.is_error() {
                self.0.queue(|connection| {
                    connection.clip_log(
                        CNDFIronLogLevel::CNDF_IRON_LOG_WARN,
                        "Clipboard format data rejected reason=remote-failure",
                    );
                });
                return;
            }
            if requested_file != Some(false) {
                return;
            }
            let bytes = response.data().to_vec();
            self.0.queue(move |connection| match decode_text(&bytes) {
                Some(text) => notify_text(connection, &text),
                None => connection.clip_log(
                    CNDFIronLogLevel::CNDF_IRON_LOG_WARN,
                    "Discarded malformed clipboard UTF-16",
                ),
            });
        }

        fn on_remote_file_list(&mut self, files: &[FileDescriptor], _: Option<u32>) {
            lock(&self.0.state).pastes.pop_front();
            let files: Vec<_> = files
                .iter()
                .map(|file| (remote_name(file), file.file_size.unwrap_or(0)))
                .collect();
            self.0.queue(move |connection| {
                notify_files(
                    connection,
                    files.iter().map(|(name, size)| (name.as_str(), *size)),
                );
            });
        }

        fn on_file_contents_request(&mut self, request: FileContentsRequest) {
            let file = lock(&self.0.state)
                .advertised
                .get(request.index as usize)
                .cloned();
            let stream = request.stream_id;
            if let Some(file) = file
                .as_ref()
                .filter(|_| request.flags == FileContentsFlags::SIZE)
            {
                self.0.send(Message::SendFileContentsResponse(
                    FileContentsResponse::new_size_response(stream, file.size),
                ));
                return;
            }
            let input = self.0.input.clone();
            self.0.queue(move |connection| {
                let length = request.requested_size;
                let data = file.ok_or("missing-file").and_then(|file| {
                    read_file_contents_range(&file, request.position, length).ok_or("range-read")
                });
                let response = match data {
                    Ok(bytes) => FileContentsResponse::new_data_response(stream, bytes),
                    Err(reason) => {
                        connection.clip_log(
                            CNDFIronLogLevel::CNDF_IRON_LOG_WARN,
                            &format!("Clipboard RANGE failed reason={reason} length={length}"),
                        );
                        FileContentsResponse::new_error(stream)
                    }
                };
                let _ = input.send_clipboard(Message::SendFileContentsResponse(response));
            });
        }

        fn on_file_contents_response(&mut self, response: FileContentsResponse<'_>) {
            let stream = response.stream_id();
            if lock(&self.0.state).requests.remove(&stream) {
                let data = (!response.is_error()).then(|| response.data().to_vec());
                self.0
                    .queue(move |connection| notify_range(connection, stream, data.as_deref()));
            }
        }

        fn on_lock(&mut self, _: LockDataId) {}
        fn on_unlock(&mut self, _: LockDataId) {}
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use ironrdp_cliprdr::pdu::ClipboardFormatName;

        #[test]
        fn file_contents_range_returns_the_remaining_bytes_at_eof() {
            let path = std::env::temp_dir()
                .join(format!("cndf-iron-file-contents-{}", std::process::id()));
            let mut fixture = std::fs::File::create_new(&path).unwrap();
            std::io::Write::write_all(&mut fixture, b"CNDF").unwrap();
            drop(fixture);
            let file = LocalFile {
                path: path.to_str().unwrap().to_owned(),
                name: "fixture".into(),
                size: 4,
            };

            let short = read_file_contents_range(&file, 1, 256 * 1024);
            let at_eof = read_file_contents_range(&file, 4, 1);
            let past_eof = read_file_contents_range(&file, 5, 1);
            let over_limit = read_file_contents_range(&file, 1, 64 * 1024 * 1024 + 1);
            std::fs::remove_file(path).unwrap();

            assert_eq!(short.as_deref(), Some(&b"NDF"[..]));
            assert_eq!(at_eof.as_deref(), Some(&b""[..]));
            assert!(past_eof.is_none());
            assert!(over_limit.is_none());
        }

        #[test]
        fn real_capabilities_expose_all_channels() {
            assert_eq!(cndf_iron_capabilities(), 0xf);
        }

        #[test]
        fn clipboard_defers_offers_until_ready_and_gates_file_streaming() {
            let (input, _events) = RdpInputSender::channel(1);
            let (work, jobs) = mpsc::channel();
            let (messages, receive) = mpsc::channel();
            let mut channel = Channel::new(input, work);
            channel.messages = Some(messages);
            let mut backend = CndfCliprdrBackend(channel.clone());

            assert_eq!(backend.client_capabilities().bits(), 0x2e);
            assert_eq!(
                channel.submit(ClipboardCommand::Range {
                    stream_id: 1,
                    list_index: 0,
                    offset: 0,
                    length: 1
                }),
                CNDF_IRON_NOT_CONNECTED
            );
            backend.on_request_format_list();
            assert!(
                matches!(receive.try_recv().unwrap(), Message::SendInitiateCopy(formats) if formats.is_empty())
            );
            channel.submit(ClipboardCommand::Text("한글".into()));
            assert!(receive.try_recv().is_err());
            backend.on_remote_copy(&[ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)]);
            backend.on_ready();
            assert!(
                matches!(receive.try_recv().unwrap(), Message::SendInitiateCopy(formats)
                if formats.len() == 1 && formats[0].id == ClipboardFormatId::CF_UNICODETEXT)
            );
            assert!(matches!(
                receive.try_recv().unwrap(),
                Message::SendInitiatePaste(ClipboardFormatId::CF_UNICODETEXT)
            ));
            backend.on_format_data_request(FormatDataRequest {
                format: ClipboardFormatId::CF_UNICODETEXT,
            });
            assert!(
                matches!(receive.try_recv().unwrap(), Message::SendFormatData(response)
                if decode_text(response.data()).as_deref() == Some("한글"))
            );

            let file = LocalFile {
                path: "/unused".into(),
                name: "file.txt".into(),
                size: 7,
            };
            channel.submit(ClipboardCommand::Files(vec![file.clone()]));
            assert!(receive.try_recv().is_err());
            assert!(jobs.try_recv().is_ok());
            backend.on_process_negotiated_capabilities(Capabilities::STREAM_FILECLIP_ENABLED);
            channel.submit(ClipboardCommand::Files(vec![file]));
            assert!(
                matches!(receive.try_recv().unwrap(), Message::SendInitiateFileCopy(files)
                if files.len() == 1 && files[0].file_size == Some(7))
            );
        }

        #[test]
        fn rejected_ranges_leave_clipboard_ready_for_the_next_request() {
            use ironrdp_cliprdr::pdu::{ClipboardPdu, FormatListResponse};
            use ironrdp_cliprdr::CliprdrClient;
            use ironrdp_svc::SvcProcessor as _;

            type Responses = Vec<(u32, Option<Vec<u8>>)>;
            extern "C" fn record_range(
                _: u64,
                stream_id: u32,
                ok: bool,
                bytes: *const u8,
                length: usize,
                context: *mut std::ffi::c_void,
            ) {
                let data = ok.then(|| unsafe { std::slice::from_raw_parts(bytes, length).to_vec() });
                unsafe { &mut *context.cast::<Responses>() }.push((stream_id, data));
            }

            let mut responses = Responses::new();
            let table = CNDFIronCallbacks {
                remote_file_contents: Some(record_range),
                context: (&mut responses as *mut Responses).cast(),
                // Every other field is an optional callback.
                ..unsafe { std::mem::zeroed() }
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
                statistics: Arc::default(),
            };

            let (input, _events) = RdpInputSender::channel(1);
            let (work, jobs) = mpsc::channel();
            let (messages, receive) = mpsc::channel();
            let mut channel = Channel::new(input, work);
            channel.messages = Some(messages);
            let mut cliprdr = CliprdrClient::new(channel.build_cliprdr_backend());
            let ready = ClipboardPdu::FormatListResponse(FormatListResponse::Ok);
            cliprdr
                .process(&ironrdp_core::encode_vec(&ready).unwrap())
                .unwrap();

            for stream_id in 1..=3 {
                assert_eq!(
                    channel.submit(ClipboardCommand::Range {
                        stream_id,
                        list_index: 0,
                        offset: 0,
                        length: 1,
                    }),
                    CNDF_IRON_OK
                );
                let Message::SendFileContentsRequest(mut request) = receive.try_recv().unwrap() else {
                    panic!("expected file contents request");
                };
                if stream_id == 1 {
                    // The local caller can submit the request, but CLIPRDR rejects a negative index.
                    request.index = -1;
                    assert!(cliprdr
                        .request_file_contents_for_session(request)
                        .unwrap()
                        .is_none());
                } else {
                    assert!(cliprdr
                        .request_file_contents_for_session(request)
                        .unwrap()
                        .is_some());
                    let bytes = if stream_id == 2 { vec![1, 2] } else { vec![3] };
                    let response = ClipboardPdu::FileContentsResponse(
                        FileContentsResponse::new_data_response(stream_id, bytes),
                    );
                    cliprdr
                        .process(&ironrdp_core::encode_vec(&response).unwrap())
                        .unwrap();
                }
                assert!(cliprdr.is_ready());
                assert!(!lock(&channel.state).requests.contains(&stream_id));
                jobs.try_recv().unwrap()(&connection);
                assert!(jobs.try_recv().is_err());
            }
            assert_eq!(responses, [(1, None), (2, None), (3, Some(vec![3]))]);
            assert!(cliprdr.process(&[]).is_err());
        }

        #[test]
        fn clipboard_failures_log_only_reason_and_counts() {
            extern "C" fn record_log(
                _: u64,
                _: CNDFIronLogLevel,
                bytes: *const u8,
                length: usize,
                context: *mut std::ffi::c_void,
            ) {
                let bytes = unsafe { std::slice::from_raw_parts(bytes, length) };
                unsafe { &mut *context.cast::<Vec<String>>() }
                    .push(String::from_utf8_lossy(bytes).into_owned());
            }

            let mut logs = Vec::<String>::new();
            let connection = Connection {
                generation: 1,
                connected: AtomicBool::new(true),
                stop: AtomicBool::new(false),
                input: Mutex::default(),
                clipboard: Mutex::default(),
                log_level: CNDFIronLogLevel::CNDF_IRON_LOG_WARN,
                callbacks: Arc::new(Callbacks {
                    table: CNDFIronCallbacks {
                        log: Some(record_log),
                        context: (&mut logs as *mut Vec<String>).cast(),
                        ..unsafe { std::mem::zeroed() }
                    },
                    gate: Mutex::default(),
                    closed: AtomicBool::new(false),
                }),
                statistics: Arc::default(),
            };

            let (input, _events) = RdpInputSender::channel(1);
            let (work, jobs) = mpsc::channel();
            let channel = Channel::new(input, work);
            let mut backend = CndfCliprdrBackend(channel.clone());
            backend.on_process_negotiated_capabilities(Capabilities::STREAM_FILECLIP_ENABLED);
            backend.on_ready();
            channel.submit(ClipboardCommand::Files(vec![LocalFile {
                path: "/private/path".into(),
                name: "/private-name".into(),
                size: 4,
            }]));
            backend.on_remote_copy(&[ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)]);
            backend.on_format_data_response(FormatDataResponse::new_error());
            backend.on_file_contents_request(FileContentsRequest {
                stream_id: 1,
                index: 0,
                flags: FileContentsFlags::RANGE,
                position: 0,
                requested_size: 8,
                data_id: None,
            });

            while let Ok(job) = jobs.try_recv() {
                job(&connection);
            }
            assert_eq!(
                logs,
                [
                    "Clipboard file offer rejected descriptors count=1",
                    "Clipboard format data rejected reason=remote-failure",
                    "Clipboard RANGE failed reason=missing-file length=8",
                ]
            );
        }

        #[test]
        fn selects_first_matching_format() {
            let text = ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT);
            let files = ClipboardFormat::new(ClipboardFormatId::new(0xc001))
                .with_name(ClipboardFormatName::FILE_LIST);
            assert_eq!(
                choose_format(&[text.clone(), files.clone()]),
                Some((text.id, false))
            );
            assert_eq!(
                choose_format(&[files.clone(), text]),
                Some((files.id, true))
            );
        }

        #[test]
        fn decodes_text_until_first_nul_and_rejects_invalid_utf16() {
            assert_eq!(decode_text(&[65, 0, 0, 0, 0, 0xd8]).as_deref(), Some("A"));
            assert_eq!(decode_text(&[0, 0xd8]), None);
            assert_eq!(decode_text(&[65]), None);
        }

        #[test]
        fn joins_normalized_remote_components() {
            let file = FileDescriptor::new("문서.txt").with_relative_path(r"root\sub");
            assert_eq!(remote_name(&file), r"root\sub\문서.txt");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn reads_sparse_range_above_four_gib_and_caps_allocations() {
        let path = std::env::temp_dir().join(format!("cndf-iron-range-{}", std::process::id()));
        let mut sparse = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        let offset = 5_u64 << 30;
        sparse.seek(SeekFrom::Start(offset)).unwrap();
        sparse.write_all(b"CNDF").unwrap();
        drop(sparse);
        let file = LocalFile {
            path: path.to_str().unwrap().to_owned(),
            name: "test".into(),
            size: offset + 4,
        };
        let range = read_range(&file, offset, 4);
        let over_limit = read_range(&file, 0, 64 * 1024 * 1024 + 1);
        let past_eof = read_range(&file, offset, 5);
        std::fs::remove_file(path).unwrap();
        assert_eq!(range.as_deref(), Some(&b"CNDF"[..]));
        assert!(over_limit.is_none());
        assert!(past_eof.is_none());
    }
}

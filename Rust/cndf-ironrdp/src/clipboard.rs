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

/// The largest RANGE served, 64 times the 256 KiB Windows requests.
const MAX_FILE_RANGE_LENGTH: u32 = 16 * 1024 * 1024;

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
pub(super) use real::{Channel, ClipJobs, ClipWork};

#[cfg(not(feature = "stub"))]
mod real {
    use super::*;
    use ironrdp_client::rdp::RdpInputSender;
    use ironrdp_cliprdr::backend::{
        ClipboardMessage as Message, CliprdrBackend, CliprdrBackendFactory, RequestedFormat,
    };
    use ironrdp_cliprdr::pdu::{
        ClipboardFileAttributes, ClipboardFormat, ClipboardFormatId,
        ClipboardGeneralCapabilityFlags as Capabilities, FileContentsFlags, FileContentsRequest,
        FileContentsResponse, FileDescriptor, FormatDataRequest, FormatDataResponse, LockDataId,
        OwnedFormatDataResponse,
    };
    use ironrdp_cliprdr::CliprdrInstance;
    use ironrdp_core::IntoOwned;
    use std::collections::HashSet;
    use tokio::sync::oneshot;

    /// RANGE responses served at once, counted from acceptance until the session handles the frame.
    const MAX_RANGE_RESPONSES_IN_FLIGHT: usize = 16;
    /// RANGE bytes reserved over the same span: two of the largest requests.
    const MAX_RANGE_BYTES_IN_FLIGHT: u64 = 2 * MAX_FILE_RANGE_LENGTH as u64;

    fn pending(completion: &mut oneshot::Receiver<()>) -> bool {
        matches!(
            completion.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        )
    }

    /// The bytes a RANGE reads: the requested length clipped at end of file.
    ///
    /// `None` if the request is longer than served or starts past the end of the file.
    fn range_length(file: &LocalFile, offset: u64, length: u32) -> Option<u32> {
        if length > MAX_FILE_RANGE_LENGTH {
            return None;
        }
        // Windows requests a full buffer even if fewer bytes remain in the file.
        let available = file.size.checked_sub(offset)?;
        Some(u64::from(length).min(available) as u32)
    }

    pub(crate) type Job = Box<dyn FnOnce(&Connection) + Send>;

    /// Why a server request was answered with a failure, or server clipboard data was dropped.
    #[derive(Clone, Copy)]
    enum Refusal {
        Budget,
        MissingFile,
        InvalidRange,
        RemoteFailure,
        MalformedText,
        Superseded,
        Oversized,
    }

    const REFUSALS: [(Refusal, &str); 7] = [
        (Refusal::Budget, "Clipboard RANGE failed reason=budget"),
        (
            Refusal::MissingFile,
            "Clipboard RANGE failed reason=missing-file",
        ),
        (
            Refusal::InvalidRange,
            "Clipboard RANGE failed reason=invalid-range",
        ),
        (
            Refusal::RemoteFailure,
            "Clipboard format data rejected reason=remote-failure",
        ),
        (
            Refusal::MalformedText,
            "Clipboard format data rejected reason=malformed-utf16",
        ),
        (
            Refusal::Superseded,
            "Clipboard remote data dropped reason=superseded",
        ),
        (
            Refusal::Oversized,
            "Clipboard remote data dropped reason=oversized",
        ),
    ];

    /// Failures not yet logged: a count and the longest length per reason.
    ///
    /// INVARIANT: Fixed size, so a request or response flood adds no queued work or log record.
    #[derive(Default)]
    struct Refusals([(u64, u64); REFUSALS.len()]);

    impl Refusals {
        fn record(&mut self, refusal: Refusal, length: u64) {
            let (count, longest) = &mut self.0[refusal as usize];
            *count += 1;
            *longest = (*longest).max(length);
        }
    }

    /// The most bytes of server clipboard data held for the app: 8 Mi UTF-16 units of text.
    const MAX_REMOTE_CLIPBOARD_BYTES: usize = 16 * 1024 * 1024;

    /// Server clipboard data the clip worker has not handed to the app yet.
    enum Remote {
        /// UTF-16LE as received.
        Text(Vec<u8>),
        Files(Vec<(String, u64)>),
    }

    impl Remote {
        /// The bytes counted against `MAX_REMOTE_CLIPBOARD_BYTES`.
        fn bytes(&self) -> usize {
            match self {
                Self::Text(data) => data.len(),
                Self::Files(files) => files
                    .iter()
                    .map(|(name, _)| name.len() + std::mem::size_of::<(String, u64)>())
                    .sum(),
            }
        }
    }

    /// The clip worker's inputs: its job queue, the newest server clipboard data, and the failures
    /// it logs.
    #[derive(Clone)]
    pub(crate) struct ClipJobs {
        work: mpsc::Sender<Job>,
        /// INVARIANT: One slot, so a response flood holds at most `MAX_REMOTE_CLIPBOARD_BYTES`.
        remote: Arc<Mutex<Option<Remote>>>,
        refusals: Arc<Mutex<Refusals>>,
    }

    impl ClipJobs {
        fn new() -> (Self, mpsc::Receiver<Job>) {
            let (work, jobs) = mpsc::channel::<Job>();
            let inputs = Self {
                work,
                remote: Arc::default(),
                refusals: Arc::default(),
            };
            (inputs, jobs)
        }

        /// Replaces the data the clip worker has not delivered: a clipboard means only its newest
        /// value, so data over the limit drops the older value too.
        fn offer_remote(&self, remote: Remote) {
            let bytes = remote.bytes();
            let mut pending = lock(&self.remote);
            let mut refusals = lock(&self.refusals);
            if let Some(superseded) = pending.take() {
                refusals.record(Refusal::Superseded, superseded.bytes() as u64);
            }
            if bytes > MAX_REMOTE_CLIPBOARD_BYTES {
                refusals.record(Refusal::Oversized, bytes as u64);
            } else {
                *pending = Some(remote);
            }
        }

        /// The clip worker's work between jobs: delivers the newest server data, then logs.
        fn flush(&self, connection: &Connection) {
            let remote = lock(&self.remote).take();
            match remote {
                Some(Remote::Text(data)) => match decode_text(&data) {
                    Some(text) => notify_text(connection, &text),
                    None => lock(&self.refusals).record(Refusal::MalformedText, data.len() as u64),
                },
                Some(Remote::Files(files)) => notify_files(
                    connection,
                    files.iter().map(|(name, size)| (name.as_str(), *size)),
                ),
                None => {}
            }
            self.log_refusals(connection);
        }

        /// Logs the failures recorded since the previous call.
        fn log_refusals(&self, connection: &Connection) {
            let refusals = std::mem::take(&mut *lock(&self.refusals));
            for ((_, message), (count, longest)) in REFUSALS.iter().zip(refusals.0) {
                if count != 0 {
                    connection.clip_log(
                        CNDFIronLogLevel::CNDF_IRON_LOG_WARN,
                        &format!("{message} count={count} max_length={longest}"),
                    );
                }
            }
        }
    }

    pub(crate) struct ClipWork;
    impl ClipWork {
        pub(crate) fn spawn(
            connection: Arc<Connection>,
        ) -> std::io::Result<(ClipJobs, JoinHandle<()>)> {
            let (jobs, recv) = ClipJobs::new();
            let pending = jobs.clone();
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
                            pending.flush(&connection);
                        }
                    })
                })?;
            Ok((jobs, worker))
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
        requests: HashSet<u32>,
        /// RANGE responses accepted for the server and not yet handled by the session.
        range_responses: Vec<(oneshot::Receiver<()>, u64)>,
    }

    impl State {
        /// Reserves `bytes` for one RANGE response, or returns `None` if the budget is spent.
        fn reserve_range(&mut self, bytes: u64) -> Option<oneshot::Sender<()>> {
            self.range_responses
                .retain_mut(|(completion, _)| pending(completion));
            let reserved: u64 = self.range_responses.iter().map(|(_, bytes)| bytes).sum();
            if self.range_responses.len() >= MAX_RANGE_RESPONSES_IN_FLIGHT
                || reserved + bytes > MAX_RANGE_BYTES_IN_FLIGHT
            {
                return None;
            }
            let (completion, handled) = oneshot::channel();
            self.range_responses.push((handled, bytes));
            Some(completion)
        }
    }

    #[derive(Clone)]
    pub(crate) struct Channel {
        state: Arc<Mutex<State>>,
        input: RdpInputSender,
        jobs: ClipJobs,
        #[cfg(test)]
        messages: Option<mpsc::Sender<Message>>,
    }

    impl Channel {
        pub(crate) fn new(input: RdpInputSender, jobs: ClipJobs) -> Self {
            Self {
                state: Arc::default(),
                input,
                jobs,
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

        fn queue(&self, job: impl FnOnce(&Connection) + Send + 'static) -> bool {
            self.jobs.work.send(Box::new(job)).is_ok()
        }

        /// Answers a RANGE the session thread cannot serve, recording why for the clip worker's log.
        fn refuse(
            &self,
            stream: u32,
            refusal: Refusal,
            length: u32,
        ) -> FileContentsResponse<'static> {
            lock(&self.jobs.refusals).record(refusal, u64::from(length));
            FileContentsResponse::new_error(stream)
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
    }

    impl CliprdrBackendFactory for Channel {
        fn build_cliprdr_backend(&self) -> Box<dyn CliprdrBackend> {
            Box::new(CndfCliprdrBackend::new(self.clone()))
        }
    }

    struct CndfCliprdrBackend {
        channel: Channel,
        ready: bool,
        deferred_paste: Option<ClipboardFormatId>,
    }

    impl CndfCliprdrBackend {
        fn new(channel: Channel) -> Self {
            Self {
                channel,
                ready: false,
                deferred_paste: None,
            }
        }
    }

    ironrdp_core::impl_as_any!(CndfCliprdrBackend);

    impl std::fmt::Debug for CndfCliprdrBackend {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("CndfCliprdrBackend")
        }
    }

    impl Drop for CndfCliprdrBackend {
        fn drop(&mut self) {
            let mut state = lock(&self.channel.state);
            state.ready = false;
            for stream in state.requests.drain() {
                self.channel
                    .queue(move |connection| notify_range(connection, stream, None));
            }
        }
    }

    fn choose_format(formats: &[ClipboardFormat]) -> Option<ClipboardFormatId> {
        formats.iter().find_map(|format| {
            if format
                .name
                .as_ref()
                .is_some_and(|name| name.value() == "FileGroupDescriptorW")
                || format.id == ClipboardFormatId::CF_UNICODETEXT
            {
                Some(format.id)
            } else {
                None
            }
        })
    }

    /// A DIRECTORY entry ends with `\`, which a sanitized name cannot end with, so the session
    /// can tell it from a file without a field in the C ABI.
    fn remote_name(file: &FileDescriptor) -> String {
        let mut name = match file.relative_path.as_deref() {
            Some(path) if !path.is_empty() => format!("{path}\\{}", file.name),
            _ => file.name.clone(),
        };
        if file
            .attributes
            .is_some_and(|attributes| attributes.contains(ClipboardFileAttributes::DIRECTORY))
        {
            name.push('\\');
        }
        name
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
            self.paste_on_ready();
        }

        fn paste_on_ready(&mut self) -> Option<ClipboardFormatId> {
            self.ready = true;
            let choice = self.deferred_paste.take();
            let mut state = lock(&self.channel.state);
            state.ready = true;
            // Re-advertising the local offer takes priority over the deferred remote copy.
            if state.dirty_offer {
                self.channel.advertise(&mut state);
                return None;
            }
            choice
        }

        // CLIPRDR calls `initial_format_list` instead.
        fn on_request_format_list(&mut self) {}

        /// Returns the format list in the iteration of the server's Monitor Ready, so a repeated
        /// Monitor Ready queues nothing for the session.
        fn initial_format_list(&mut self) -> Option<Vec<ClipboardFormat>> {
            let mut state = lock(&self.channel.state);
            state.dirty_offer = matches!(state.offer, Offer::Files(_));
            Some(if matches!(state.offer, Offer::Text(_)) {
                vec![ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)]
            } else {
                Vec::new()
            })
        }

        fn on_process_negotiated_capabilities(&mut self, capabilities: Capabilities) {
            lock(&self.channel.state).negotiated = Some(capabilities);
        }

        // CLIPRDR calls `paste_on_remote_copy` instead.
        fn on_remote_copy(&mut self, _: &[ClipboardFormat]) {}

        /// Pastes in the iteration of the server's Format List, so a repeated copy queues nothing
        /// for the session. Before the channel is ready the choice waits for `paste_on_ready`.
        /// Any server Format List replaces the clipboard the RANGE requests in flight read, so they
        /// fail now, as in `Drop`; a late response finds no request and is not delivered.
        fn paste_on_remote_copy(
            &mut self,
            formats: &[ClipboardFormat],
        ) -> Option<ClipboardFormatId> {
            let mut state = lock(&self.channel.state);
            for stream in state.requests.drain() {
                self.channel
                    .queue(move |connection| notify_range(connection, stream, None));
            }
            drop(state);
            let choice = choose_format(formats);
            if !self.ready {
                self.deferred_paste = choice;
                return None;
            }
            choice
        }

        // CLIPRDR calls `respond_to_format_data_request` instead.
        fn on_format_data_request(&mut self, _: FormatDataRequest) {}

        /// Answers in the iteration that received the request, so a blocked write holds one copy of
        /// the text and responses keep the order of the requests.
        fn respond_to_format_data_request(
            &mut self,
            request: FormatDataRequest,
        ) -> Option<OwnedFormatDataResponse> {
            let state = lock(&self.channel.state);
            Some(
                match &state.offer {
                    Offer::Text(text) if request.format == ClipboardFormatId::CF_UNICODETEXT => {
                        FormatDataResponse::new_unicode_string(text)
                    }
                    _ => FormatDataResponse::new_error(),
                }
                .into_owned(),
            )
        }

        fn on_format_data_response(&mut self, response: FormatDataResponse<'_>) {
            self.on_format_data_answer(response, None);
        }

        fn on_format_data_answer(
            &mut self,
            response: FormatDataResponse<'_>,
            requested: Option<RequestedFormat>,
        ) {
            if response.is_error() {
                lock(&self.channel.jobs.refusals)
                    .record(Refusal::RemoteFailure, response.data().len() as u64);
                return;
            }
            if requested != Some(RequestedFormat::Other) {
                return;
            }
            self.channel
                .jobs
                .offer_remote(Remote::Text(response.data().to_vec()));
        }

        /// A response CLIPRDR dropped for its size answers the oldest paste, which then fails.
        fn on_format_data_response_oversized(&mut self, declared_length: usize) {
            lock(&self.channel.jobs.refusals).record(Refusal::Oversized, declared_length as u64);
        }

        fn on_remote_file_list(&mut self, files: &[FileDescriptor], _: Option<u32>) {
            let files = files
                .iter()
                .map(|file| (remote_name(file), file.file_size.unwrap_or(0)))
                .collect();
            self.channel.jobs.offer_remote(Remote::Files(files));
        }

        // CLIPRDR calls `respond_to_file_contents_request` instead.
        fn on_file_contents_request(&mut self, _: FileContentsRequest) {}

        /// Answers in the iteration that received the request unless a file read is needed. Only an
        /// accepted read is deferred, holding a RANGE reservation until the session handles its frame.
        fn respond_to_file_contents_request(
            &mut self,
            request: FileContentsRequest,
            instance: CliprdrInstance,
        ) -> Option<FileContentsResponse<'static>> {
            let stream = request.stream_id;
            let length = request.requested_size;
            let mut state = lock(&self.channel.state);
            let Some(file) = state.advertised.get(request.index as usize).cloned() else {
                return Some(self.channel.refuse(stream, Refusal::MissingFile, length));
            };
            if request.flags == FileContentsFlags::SIZE {
                return Some(FileContentsResponse::new_size_response(stream, file.size));
            }
            let Some(read) = range_length(&file, request.position, length) else {
                return Some(self.channel.refuse(stream, Refusal::InvalidRange, length));
            };
            let Some(completion) = state.reserve_range(u64::from(read)) else {
                return Some(self.channel.refuse(stream, Refusal::Budget, length));
            };
            drop(state);
            let input = self.channel.input.clone();
            let queued = self.channel.queue(move |connection| {
                // A stopping session takes no more reads; dropping the completion releases them.
                if connection.stop.load(Ordering::Acquire) {
                    return;
                }
                let response = match read_range(&file, request.position, read) {
                    Some(bytes) => FileContentsResponse::new_data_response(stream, bytes),
                    None => {
                        connection.clip_log(
                            CNDFIronLogLevel::CNDF_IRON_LOG_WARN,
                            &format!("Clipboard RANGE failed reason=range-read length={length}"),
                        );
                        FileContentsResponse::new_error(stream)
                    }
                };
                // The session drops or signals the completion once it has handled the frame, and
                // discards the response if the CLIPRDR channel that requested it is gone.
                let _ = input.send_clipboard_for_instance(
                    instance,
                    Message::SendFileContentsResponse(response),
                    completion,
                );
            });
            // The rejected job, and with it the reservation, is dropped already.
            (!queued).then(|| FileContentsResponse::new_error(stream))
        }

        fn on_file_contents_response(&mut self, response: FileContentsResponse<'_>) {
            let stream = response.stream_id();
            if lock(&self.channel.state).requests.remove(&stream) {
                let data = (!response.is_error()).then(|| response.data().to_vec());
                self.channel
                    .queue(move |connection| notify_range(connection, stream, data.as_deref()));
            }
        }

        fn on_lock(&mut self, _: LockDataId) {}
        fn on_unlock(&mut self, _: LockDataId) {}
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use ironrdp_client::rdp::RdpInputEvent;
        use ironrdp_cliprdr::pdu::{
            Capabilities as ChannelCapabilities, ClipboardFormatName, ClipboardPdu,
            ClipboardProtocolVersion, FormatList, FormatListResponse, PackedFileList,
        };
        use ironrdp_cliprdr::CliprdrClient;
        use ironrdp_svc::{SvcMessage, SvcProcessor as _};

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

            let read = |offset, length| {
                range_length(&file, offset, length).and_then(|read| read_range(&file, offset, read))
            };
            let short = read(1, 256 * 1024);
            let at_eof = read(4, 1);
            let past_eof = read(5, 1);
            let over_limit = read(1, 64 * 1024 * 1024 + 1);
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
            let (mut channel, jobs) = test_channel(input);
            let (messages, receive) = mpsc::channel();
            channel.messages = Some(messages);
            let mut backend = CndfCliprdrBackend::new(channel.clone());

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
            assert!(backend
                .initial_format_list()
                .is_some_and(|formats| formats.is_empty()));
            assert!(receive.try_recv().is_err());
            channel.submit(ClipboardCommand::Text("한글".into()));
            assert!(receive.try_recv().is_err());
            assert_eq!(
                backend.paste_on_remote_copy(&[ClipboardFormat::new(
                    ClipboardFormatId::CF_UNICODETEXT
                )]),
                None
            );
            assert_eq!(backend.paste_on_ready(), None);
            assert!(
                matches!(receive.try_recv().unwrap(), Message::SendInitiateCopy(formats)
                if formats.len() == 1 && formats[0].id == ClipboardFormatId::CF_UNICODETEXT)
            );
            let response = backend.respond_to_format_data_request(FormatDataRequest {
                format: ClipboardFormatId::CF_UNICODETEXT,
            });
            assert_eq!(
                response.map(|response| decode_text(response.data())),
                Some(Some("한글".into()))
            );
            assert!(receive.try_recv().is_err());

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
            let (mut channel, jobs) = test_channel(input);
            let (messages, receive) = mpsc::channel();
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
                let Message::SendFileContentsRequest(mut request) = receive.try_recv().unwrap()
                else {
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
            let (channel, jobs) = test_channel(input);
            let mut backend = CndfCliprdrBackend::new(channel.clone());
            backend.on_process_negotiated_capabilities(Capabilities::STREAM_FILECLIP_ENABLED);
            backend.on_ready();
            channel.submit(ClipboardCommand::Files(vec![LocalFile {
                path: "/private/path".into(),
                name: "/private-name".into(),
                size: 4,
            }]));
            backend
                .paste_on_remote_copy(&[ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)]);
            backend.on_format_data_response(FormatDataResponse::new_error());
            let missing =
                backend.respond_to_file_contents_request(range(1, 0, 8), other_instance());
            assert!(missing.is_some_and(|response| response.is_error()));

            while let Ok(job) = jobs.try_recv() {
                job(&connection);
            }
            channel.jobs.flush(&connection);
            assert_eq!(
                logs,
                [
                    "Clipboard file offer rejected descriptors count=1",
                    "Clipboard RANGE failed reason=missing-file count=1 max_length=8",
                    "Clipboard format data rejected reason=remote-failure count=1 max_length=0",
                ]
            );
        }

        fn test_channel(input: RdpInputSender) -> (Channel, mpsc::Receiver<Job>) {
            let (jobs, work) = ClipJobs::new();
            (Channel::new(input, jobs), work)
        }

        /// The instance of a CLIPRDR processor that is not the one under test.
        fn other_instance() -> CliprdrInstance {
            let (input, _events) = RdpInputSender::channel(1);
            CliprdrClient::new(test_channel(input).0.build_cliprdr_backend()).instance()
        }

        fn range_connection(logs: &mut Vec<String>) -> Connection {
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
            Connection {
                generation: 1,
                connected: AtomicBool::new(true),
                stop: AtomicBool::new(false),
                input: Mutex::default(),
                clipboard: Mutex::default(),
                log_level: CNDFIronLogLevel::CNDF_IRON_LOG_WARN,
                callbacks: Arc::new(Callbacks {
                    table: CNDFIronCallbacks {
                        log: Some(record_log),
                        context: (logs as *mut Vec<String>).cast(),
                        ..unsafe { std::mem::zeroed() }
                    },
                    gate: Mutex::default(),
                    closed: AtomicBool::new(false),
                }),
                statistics: Arc::default(),
            }
        }

        /// Removes the fixture even when an assertion fails.
        struct Fixture(std::path::PathBuf);

        impl Drop for Fixture {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }

        /// A sparse file, so reads cost no disk space.
        fn sparse_file(name: &str, size: u64) -> (Fixture, LocalFile) {
            let path =
                std::env::temp_dir().join(format!("cndf-iron-{name}-{}", std::process::id()));
            let _ = std::fs::remove_file(&path);
            let file = std::fs::File::create_new(&path).unwrap();
            let fixture = Fixture(path.clone());
            file.set_len(size).unwrap();
            let file = LocalFile {
                path: path.to_str().unwrap().to_owned(),
                name: name.into(),
                size,
            };
            (fixture, file)
        }

        /// A CLIPRDR client channel of a session offering local files, with the queues the session and
        /// the clip worker would consume.
        struct Offered {
            channel: Channel,
            cliprdr: CliprdrClient,
            jobs: mpsc::Receiver<Job>,
            ordered: tokio::sync::mpsc::UnboundedReceiver<RdpInputEvent>,
            _events: tokio::sync::mpsc::Receiver<RdpInputEvent>,
        }

        impl Offered {
            fn new(files: Vec<LocalFile>) -> Self {
                let (input, _events, ordered) = RdpInputSender::channel_with_ordered_queue(1);
                let (channel, jobs) = test_channel(input);
                let cliprdr = CliprdrClient::new(channel.build_cliprdr_backend());
                let mut offered = Self {
                    channel,
                    cliprdr,
                    jobs,
                    ordered,
                    _events,
                };
                offered.ready();
                offered.channel.submit(ClipboardCommand::Files(files));
                offered.hand_offer_to_cliprdr();
                offered
            }

            /// Negotiates file streaming and completes the CLIPRDR initialization.
            fn ready(&mut self) {
                let capabilities = ClipboardPdu::Capabilities(ChannelCapabilities::new(
                    ClipboardProtocolVersion::V2,
                    Capabilities::STREAM_FILECLIP_ENABLED | Capabilities::USE_LONG_FORMAT_NAMES,
                ));
                let ready = ClipboardPdu::FormatListResponse(FormatListResponse::Ok);
                for pdu in [capabilities, ready] {
                    assert!(self
                        .cliprdr
                        .process(&ironrdp_core::encode_vec(&pdu).unwrap())
                        .unwrap()
                        .is_empty());
                }
            }

            /// Does what the session does with the backend's file offer.
            fn hand_offer_to_cliprdr(&mut self) {
                while let Ok(event) = self.ordered.try_recv() {
                    if let RdpInputEvent::Clipboard(Message::SendInitiateFileCopy(files)) = event {
                        self.cliprdr.initiate_file_copy(files).unwrap();
                    }
                }
            }

            /// Delivers a server request and returns the answers in the output of that iteration.
            fn request(&mut self, request: FileContentsRequest) -> Vec<(u32, Option<usize>)> {
                let pdu = ClipboardPdu::FileContentsRequest(request);
                answers(
                    self.cliprdr
                        .process(&ironrdp_core::encode_vec(&pdu).unwrap())
                        .unwrap(),
                )
            }

            fn run_jobs(&self, connection: &Connection) -> usize {
                let mut count = 0;
                while let Ok(job) = self.jobs.try_recv() {
                    job(connection);
                    count += 1;
                }
                count
            }

            /// Takes the deferred responses the session has not written yet.
            fn hold(&mut self, held: &mut Held) {
                while let Ok(event) = self.ordered.try_recv() {
                    let RdpInputEvent::ClipboardForInstance(
                        instance,
                        Message::SendFileContentsResponse(response),
                        completion,
                    ) = event
                    else {
                        panic!("unexpected clipboard event {event:?}");
                    };
                    let data = (!response.is_error()).then(|| response.data().len());
                    held.push(Deferred {
                        instance,
                        stream: response.stream_id(),
                        data,
                        completion,
                    });
                }
            }

            /// RANGE reservations: count and bytes.
            fn reserved(&self) -> (usize, u64) {
                let mut state = lock(&self.channel.state);
                state
                    .range_responses
                    .retain_mut(|(completion, _)| pending(completion));
                (
                    state.range_responses.len(),
                    state.range_responses.iter().map(|(_, bytes)| bytes).sum(),
                )
            }

            fn refused(&self, refusal: Refusal) -> u64 {
                lock(&self.channel.jobs.refusals).0[refusal as usize].0
            }

            /// The server copies one format, the app pastes it, and the server answers `response`.
            fn remote_paste(&mut self, format: ClipboardFormat, response: OwnedFormatDataResponse) {
                let copy =
                    ClipboardPdu::FormatList(FormatList::new_unicode(&[format], true).unwrap());
                let output = self
                    .cliprdr
                    .process(&ironrdp_core::encode_vec(&copy).unwrap())
                    .unwrap();
                assert_eq!(
                    kinds(&output).last().map(String::as_str),
                    Some("FormatDataRequest")
                );
                assert!(self.ordered.try_recv().is_err());
                let pdu = ClipboardPdu::FormatDataResponse(response);
                assert!(self
                    .cliprdr
                    .process(&ironrdp_core::encode_vec(&pdu).unwrap())
                    .unwrap()
                    .is_empty());
            }

            /// The bytes of server clipboard data held for the clip worker.
            fn held_remote(&self) -> Option<usize> {
                lock(&self.channel.jobs.remote).as_ref().map(Remote::bytes)
            }
        }

        /// What the clip worker handed to the app.
        #[derive(Default)]
        struct Delivered {
            texts: Vec<String>,
            files: Vec<Vec<(String, u64)>>,
            logs: Vec<String>,
        }

        fn delivering_connection(delivered: &mut Delivered) -> Connection {
            extern "C" fn text(
                _: u64,
                bytes: *const u8,
                length: usize,
                context: *mut std::ffi::c_void,
            ) {
                let bytes = unsafe { std::slice::from_raw_parts(bytes, length) };
                unsafe { &mut *context.cast::<Delivered>() }
                    .texts
                    .push(String::from_utf8(bytes.to_vec()).unwrap());
            }
            extern "C" fn files(
                _: u64,
                files: *const CNDFIronRemoteFile,
                count: usize,
                context: *mut std::ffi::c_void,
            ) {
                let files = unsafe { std::slice::from_raw_parts(files, count) }
                    .iter()
                    .map(|file| {
                        let name =
                            unsafe { std::slice::from_raw_parts(file.name_utf8, file.name_length) };
                        (String::from_utf8(name.to_vec()).unwrap(), file.size)
                    })
                    .collect();
                unsafe { &mut *context.cast::<Delivered>() }
                    .files
                    .push(files);
            }
            extern "C" fn log(
                _: u64,
                _: CNDFIronLogLevel,
                bytes: *const u8,
                length: usize,
                context: *mut std::ffi::c_void,
            ) {
                let bytes = unsafe { std::slice::from_raw_parts(bytes, length) };
                unsafe { &mut *context.cast::<Delivered>() }
                    .logs
                    .push(String::from_utf8_lossy(bytes).into_owned());
            }
            Connection {
                generation: 1,
                connected: AtomicBool::new(true),
                stop: AtomicBool::new(false),
                input: Mutex::default(),
                clipboard: Mutex::default(),
                log_level: CNDFIronLogLevel::CNDF_IRON_LOG_WARN,
                callbacks: Arc::new(Callbacks {
                    table: CNDFIronCallbacks {
                        remote_text: Some(text),
                        remote_file_list: Some(files),
                        log: Some(log),
                        context: (delivered as *mut Delivered).cast(),
                        ..unsafe { std::mem::zeroed() }
                    },
                    gate: Mutex::default(),
                    closed: AtomicBool::new(false),
                }),
                statistics: Arc::default(),
            }
        }

        fn text_format() -> ClipboardFormat {
            ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)
        }

        fn file_format() -> ClipboardFormat {
            ClipboardFormat::new(ClipboardFormatId::new(0xc0ff))
                .with_name(ClipboardFormatName::FILE_LIST)
        }

        /// NUL-terminated UTF-16LE, as Windows sends CF_UNICODETEXT.
        fn utf16(text: &str) -> Vec<u8> {
            text.encode_utf16()
                .chain([0])
                .flat_map(u16::to_le_bytes)
                .collect()
        }

        fn file_list(name: &str, size: u64) -> OwnedFormatDataResponse {
            FormatDataResponse::new_file_list(&PackedFileList {
                files: vec![FileDescriptor::new(name).with_file_size(size)],
            })
            .unwrap()
        }

        /// The CLIPRDR PDU type of each message in `output`.
        fn kinds(output: &[SvcMessage]) -> Vec<String> {
            output
                .iter()
                .map(|message| {
                    let bytes = message.encode_unframed_pdu().unwrap();
                    let pdu = ironrdp_core::decode::<ClipboardPdu<'_>>(&bytes).unwrap();
                    let debug = format!("{pdu:?}");
                    debug.split('(').next().unwrap().to_owned()
                })
                .collect()
        }

        fn answers(output: Vec<SvcMessage>) -> Vec<(u32, Option<usize>)> {
            output
                .iter()
                .map(|message| {
                    let bytes = message.encode_unframed_pdu().unwrap();
                    match ironrdp_core::decode::<ClipboardPdu<'_>>(&bytes).unwrap() {
                        ClipboardPdu::FileContentsResponse(response) => (
                            response.stream_id(),
                            (!response.is_error()).then(|| response.data().len()),
                        ),
                        other => panic!("unexpected answer {other:?}"),
                    }
                })
                .collect()
        }

        fn range(stream_id: u32, position: u64, requested_size: u32) -> FileContentsRequest {
            FileContentsRequest {
                stream_id,
                index: 0,
                flags: FileContentsFlags::RANGE,
                position,
                requested_size,
                data_id: None,
            }
        }

        /// A deferred response the session took from its queue but has not written.
        struct Deferred {
            instance: CliprdrInstance,
            stream: u32,
            data: Option<usize>,
            completion: oneshot::Sender<()>,
        }

        type Held = Vec<Deferred>;

        fn held_bytes(held: &Held) -> u64 {
            held.iter()
                .map(|response| response.data.unwrap_or(0) as u64)
                .sum()
        }

        // oracle: mutant answering a refused RANGE through the session's clipboard queue or queuing
        // its log for the clip worker.
        #[test]
        fn refused_ranges_are_answered_in_the_current_iteration_without_queuing() {
            const MIB: u32 = 1024 * 1024;
            let mut logs = Vec::new();
            let connection = range_connection(&mut logs);
            let (_fixture, file) = sparse_file("range-refused", 1 << 30);
            let mut offered = Offered::new(vec![file]);
            let mut held = Held::new();
            for stream_id in 0..MAX_RANGE_RESPONSES_IN_FLIGHT as u32 {
                assert!(offered.request(range(stream_id, 0, MIB)).is_empty());
            }
            assert_eq!(offered.run_jobs(&connection), MAX_RANGE_RESPONSES_IN_FLIGHT);
            offered.hold(&mut held);
            assert_eq!(held.len(), MAX_RANGE_RESPONSES_IN_FLIGHT);

            // The writes are blocked: the limit is reached and the next request is refused.
            assert_eq!(offered.request(range(16, 0, MIB)), [(16, None)]);
            assert!(
                offered.ordered.try_recv().is_err(),
                "the refusal was queued for the session"
            );
            assert!(
                offered.jobs.try_recv().is_err(),
                "the refusal queued clip work"
            );
            assert_eq!(offered.refused(Refusal::Budget), 1);
            assert_eq!(offered.reserved(), (16, 16 * u64::from(MIB)));

            offered.channel.jobs.log_refusals(&connection);
            assert_eq!(
                logs,
                ["Clipboard RANGE failed reason=budget count=1 max_length=1048576"]
            );
            drop(held);
        }

        // oracle: mutant releasing a reservation when the RANGE is read or queued instead of when
        // the session handles its frame, or skipping the byte or count limit.
        #[test]
        fn range_responses_stay_within_budget_while_the_session_cannot_write() {
            const MIB: u32 = 1024 * 1024;
            let mut logs = Vec::new();
            let connection = range_connection(&mut logs);
            let (_fixture, file) = sparse_file("range-budget", 1 << 30);
            let mut offered = Offered::new(vec![file]);
            let mut held = Held::new();
            let within_budget = |offered: &Offered, held: &Held| {
                let (count, bytes) = offered.reserved();
                assert!(count <= MAX_RANGE_RESPONSES_IN_FLIGHT);
                assert!(bytes <= MAX_RANGE_BYTES_IN_FLIGHT);
                assert!(held.len() <= count && held_bytes(held) <= bytes);
            };

            // Count limit: 100 small requests in one burst, each answered or deferred at once.
            let mut refused = Vec::new();
            for stream_id in 0..100 {
                let answer =
                    offered.request(range(stream_id, u64::from(stream_id) * u64::from(MIB), MIB));
                assert!(answer.len() <= 1);
                refused.extend(answer.into_iter().map(|(stream, data)| {
                    assert!(data.is_none());
                    stream
                }));
                within_budget(&offered, &held);
            }
            assert_eq!(refused, (16..100).collect::<Vec<_>>());
            assert_eq!(offered.run_jobs(&connection), MAX_RANGE_RESPONSES_IN_FLIGHT);
            offered.hold(&mut held);
            within_budget(&offered, &held);
            assert_eq!(held.len(), MAX_RANGE_RESPONSES_IN_FLIGHT);
            assert!(held
                .iter()
                .all(|response| response.instance == offered.cliprdr.instance()
                    && response.data == Some(MIB as usize)));

            // Nothing more is served until the session writes a held frame.
            assert_eq!(offered.request(range(100, 0, MIB)), [(100, None)]);
            let _ = held.remove(0).completion.send(());
            assert!(offered.request(range(101, 0, MIB)).is_empty());
            offered.run_jobs(&connection);
            offered.hold(&mut held);
            within_budget(&offered, &held);
            assert_eq!(held.len(), MAX_RANGE_RESPONSES_IN_FLIGHT);

            // Byte limit: the largest requests fit twice.
            for response in held.drain(..) {
                let _ = response.completion.send(());
            }
            let mut refused = Vec::new();
            for stream_id in 200..204 {
                refused.extend(offered.request(range(stream_id, 0, MAX_FILE_RANGE_LENGTH)));
                within_budget(&offered, &held);
            }
            assert_eq!(refused, [(202, None), (203, None)]);
            offered.run_jobs(&connection);
            offered.hold(&mut held);
            within_budget(&offered, &held);
            assert_eq!(held_bytes(&held), MAX_RANGE_BYTES_IN_FLIGHT);

            offered.channel.jobs.log_refusals(&connection);
            assert_eq!(
                logs,
                ["Clipboard RANGE failed reason=budget count=87 max_length=16777216"]
            );
        }

        // oracle: mutant keeping a reservation whose frame the session dropped or failed to write, or
        // whose job never ran or could not be submitted.
        #[test]
        fn dropped_responses_and_jobs_release_their_reservations() {
            let mut logs = Vec::new();
            let connection = range_connection(&mut logs);
            let (_fixture, file) = sparse_file("range-release", 1 << 30);
            let mut offered = Offered::new(vec![file]);
            let mut held = Held::new();
            for stream_id in 0..2 {
                assert!(offered
                    .request(range(stream_id, 0, MAX_FILE_RANGE_LENGTH))
                    .is_empty());
            }
            // One response reaches the session and its write fails or is canceled; the other job
            // never runs.
            offered.jobs.try_recv().unwrap()(&connection);
            offered.hold(&mut held);
            assert_eq!(held.len(), 1);
            assert_eq!(offered.reserved().0, 2);
            held.clear();
            assert_eq!(offered.reserved().0, 1);
            let Offered {
                channel,
                mut cliprdr,
                jobs,
                ..
            } = offered;
            drop(jobs);
            assert_eq!(lock(&channel.state).range_responses.len(), 1);

            // The clip worker is gone: the RANGE fails at once and keeps no reservation.
            let pdu = ClipboardPdu::FileContentsRequest(range(2, 0, MAX_FILE_RANGE_LENGTH));
            let answer = answers(
                cliprdr
                    .process(&ironrdp_core::encode_vec(&pdu).unwrap())
                    .unwrap(),
            );
            assert_eq!(answer, [(2, None)]);
            let mut state = lock(&channel.state);
            assert!(state.reserve_range(MAX_RANGE_BYTES_IN_FLIGHT).is_some());
        }

        // oracle: mutant reading a RANGE after the session started stopping.
        #[test]
        fn stopping_sessions_start_no_more_reads() {
            let mut logs = Vec::new();
            let connection = range_connection(&mut logs);
            let (fixture, file) = sparse_file("range-stop", 8);
            let mut offered = Offered::new(vec![file]);
            assert!(offered.request(range(1, 0, 8)).is_empty());
            connection.stop.store(true, Ordering::Release);
            // A read would fail and log once the file is gone.
            drop(fixture);
            assert_eq!(offered.run_jobs(&connection), 1);
            assert!(offered.ordered.try_recv().is_err());
            assert_eq!(offered.reserved(), (0, 0));
            assert!(logs.is_empty());
        }

        // oracle: mutant resetting the budget when the session builds a new CLIPRDR processor, or
        // naming another processor in a deferred response.
        #[test]
        fn new_clipboard_channels_share_the_budget_and_name_their_requests() {
            let mut logs = Vec::new();
            let connection = range_connection(&mut logs);
            let (_fixture, file) = sparse_file("range-reconnect", 1 << 30);
            let mut offered = Offered::new(vec![file]);
            let mut held = Held::new();
            for stream_id in 0..2 {
                assert!(offered
                    .request(range(stream_id, 0, MAX_FILE_RANGE_LENGTH))
                    .is_empty());
            }
            offered.run_jobs(&connection);
            offered.hold(&mut held);
            let previous = offered.cliprdr.instance();

            // The same client connects again, here as after a server redirection.
            offered.cliprdr = CliprdrClient::new(offered.channel.build_cliprdr_backend());
            offered.ready();
            let files = lock(&offered.channel.state)
                .advertised
                .iter()
                .map(|file| LocalFile::clone(file))
                .collect();
            offered.channel.submit(ClipboardCommand::Files(files));
            offered.hand_offer_to_cliprdr();
            assert_ne!(offered.cliprdr.instance(), previous);
            assert!(held.iter().all(|response| response.instance == previous));
            assert_eq!(offered.request(range(2, 0, 1)), [(2, None)]);

            held.clear();
            assert!(offered.request(range(3, 0, 1)).is_empty());
            offered.run_jobs(&connection);
            offered.hold(&mut held);
            assert_eq!(held.len(), 1);
            assert_eq!(held[0].instance, offered.cliprdr.instance());
        }

        // oracle: mutant deferring a response that needs no file read, or answering a request twice.
        #[test]
        fn each_file_contents_request_is_answered_once_with_its_stream() {
            let mut logs = Vec::new();
            let connection = range_connection(&mut logs);
            let (_small, small) = sparse_file("range-outcomes-small", 10);
            let (gone_fixture, gone) = sparse_file("range-outcomes-gone", 10);
            let mut offered = Offered::new(vec![small, gone]);
            let mut held = Held::new();
            drop(gone_fixture);

            let size = FileContentsRequest {
                flags: FileContentsFlags::SIZE,
                requested_size: 8,
                ..range(1, 0, 8)
            };
            assert_eq!(offered.request(size), [(1, Some(8))]);
            // Upstream validation: an index past the offered files.
            assert_eq!(
                offered.request(FileContentsRequest {
                    index: 2,
                    ..range(2, 0, 1)
                }),
                [(2, None)]
            );
            assert_eq!(offered.request(range(3, 11, 1)), [(3, None)]);
            assert_eq!(
                offered.request(range(4, 0, MAX_FILE_RANGE_LENGTH + 1)),
                [(4, None)]
            );
            // Windows asks for a full buffer at the end of a file.
            assert!(offered.request(range(5, 7, 256 * 1024)).is_empty());
            assert!(offered.request(range(6, 10, 1)).is_empty());
            assert!(offered
                .request(FileContentsRequest {
                    index: 1,
                    ..range(7, 0, 4)
                })
                .is_empty());
            assert_eq!(offered.run_jobs(&connection), 3);
            offered.hold(&mut held);
            let deferred: Vec<_> = held
                .iter()
                .map(|response| (response.stream, response.data))
                .collect();
            assert_eq!(deferred, [(5, Some(3)), (6, Some(0)), (7, None)]);
            assert!(offered.ordered.try_recv().is_err());
            assert_eq!(offered.refused(Refusal::InvalidRange), 2);
            assert_eq!(logs, ["Clipboard RANGE failed reason=range-read length=4"]);
        }

        // oracle: mutant queuing a text response for the session, which a blocked write would let
        // pile up and a later failure overtake.
        #[test]
        fn text_responses_are_answered_in_request_order() {
            let (input, _events, mut ordered) = RdpInputSender::channel_with_ordered_queue(1);
            let (channel, jobs) = test_channel(input);
            let mut cliprdr = CliprdrClient::new(channel.build_cliprdr_backend());
            let ready = ClipboardPdu::FormatListResponse(FormatListResponse::Ok);
            cliprdr
                .process(&ironrdp_core::encode_vec(&ready).unwrap())
                .unwrap();
            channel.submit(ClipboardCommand::Text("가".repeat(1024)));
            while ordered.try_recv().is_ok() {}

            let mut answers = Vec::new();
            for format in [
                ClipboardFormatId::CF_UNICODETEXT,
                ClipboardFormatId::CF_TEXT,
                ClipboardFormatId::CF_UNICODETEXT,
            ] {
                let pdu = ClipboardPdu::FormatDataRequest(FormatDataRequest { format });
                let output = cliprdr
                    .process(&ironrdp_core::encode_vec(&pdu).unwrap())
                    .unwrap();
                assert_eq!(output.len(), 1);
                let bytes = output[0].encode_unframed_pdu().unwrap();
                let ClipboardPdu::FormatDataResponse(response) =
                    ironrdp_core::decode::<ClipboardPdu<'_>>(&bytes).unwrap()
                else {
                    panic!("expected a format data response");
                };
                answers.push((response.is_error(), decode_text(response.data())));
            }
            let text = Some("가".repeat(1024));
            assert_eq!(
                answers,
                [
                    (false, text.clone()),
                    (true, Some(String::new())),
                    (false, text)
                ]
            );
            assert!(ordered.try_recv().is_err());
            assert!(jobs.try_recv().is_err());
        }

        // oracle: mutant queuing each server text or file list for the clip worker, holding more
        // than the newest, or delivering it twice.
        #[test]
        fn remote_clipboard_data_keeps_only_the_newest_while_the_clip_worker_is_blocked() {
            let mut delivered = Delivered::default();
            let connection = delivering_connection(&mut delivered);
            let mut offered = Offered::new(Vec::new());
            let text = |copy: u64| utf16(&format!("text {copy} ").repeat(1024));
            for copy in 0..64 {
                if copy % 2 == 0 {
                    offered.remote_paste(text_format(), FormatDataResponse::new_data(text(copy)));
                } else {
                    offered
                        .remote_paste(file_format(), file_list(&format!("file {copy}.txt"), copy));
                }
                // The clip worker is blocked: no work is queued for it and one value is held.
                assert!(
                    offered.jobs.try_recv().is_err(),
                    "copy {copy} queued clip work"
                );
                assert!(offered
                    .held_remote()
                    .is_some_and(|bytes| bytes <= MAX_REMOTE_CLIPBOARD_BYTES));
            }

            offered.channel.jobs.flush(&connection);
            offered.channel.jobs.flush(&connection);
            assert!(delivered.texts.is_empty());
            assert_eq!(delivered.files, [vec![("file 63.txt".to_owned(), 63)]]);
            assert_eq!(
                delivered.logs,
                [format!(
                    "Clipboard remote data dropped reason=superseded count=63 max_length={}",
                    text(62).len()
                )]
            );
            assert_eq!(offered.held_remote(), None);
        }

        // oracle: mutant holding server data over the limit, or delivering the older data it
        // replaced.
        #[test]
        fn oversized_remote_clipboard_data_is_dropped_with_the_data_it_replaced() {
            let mut delivered = Delivered::default();
            let connection = delivering_connection(&mut delivered);
            let mut offered = Offered::new(Vec::new());
            offered.remote_paste(text_format(), FormatDataResponse::new_data(utf16("older")));
            let oversized = vec![b'A'; MAX_REMOTE_CLIPBOARD_BYTES + 2];
            offered.remote_paste(text_format(), FormatDataResponse::new_data(oversized));
            assert!(offered.jobs.try_recv().is_err());
            assert_eq!(offered.held_remote(), None);

            offered.channel.jobs.flush(&connection);
            assert!(delivered.texts.is_empty());
            assert_eq!(
                delivered.logs,
                [
                    "Clipboard remote data dropped reason=superseded count=1 max_length=12"
                        .to_owned(),
                    format!(
                        "Clipboard remote data dropped reason=oversized count=1 max_length={}",
                        MAX_REMOTE_CLIPBOARD_BYTES + 2
                    ),
                ]
            );

            // Data within the limit is delivered again.
            offered.remote_paste(text_format(), FormatDataResponse::new_data(utf16("newer")));
            offered.channel.jobs.flush(&connection);
            assert_eq!(delivered.texts, ["newer"]);

            // A file list counts its entries as well as its names.
            let name = "a".repeat(MAX_REMOTE_CLIPBOARD_BYTES);
            offered
                .channel
                .jobs
                .offer_remote(Remote::Files(vec![(name, 0)]));
            assert_eq!(offered.held_remote(), None);
            offered.channel.jobs.flush(&connection);
            assert!(delivered.files.is_empty());
            assert_eq!(
                delivered.logs.last().unwrap(),
                &format!(
                    "Clipboard remote data dropped reason=oversized count=1 max_length={}",
                    MAX_REMOTE_CLIPBOARD_BYTES + std::mem::size_of::<(String, u64)>()
                )
            );
        }

        // oracle: mutant leaving the oversized response's paste queued, shifting the next response
        // onto it, or logging the server data instead of the declared length.
        #[test]
        fn oversized_server_responses_fail_their_paste_and_log_the_declared_length() {
            /// One byte over the CLIPRDR message limit, CLIPRDR header included.
            const DECLARED: usize = 64 * 1024 * 1024 + 1;

            let mut delivered = Delivered::default();
            let connection = delivering_connection(&mut delivered);
            let (input, _events, mut ordered) = RdpInputSender::channel_with_ordered_queue(1);
            let (channel, _jobs) = test_channel(input);
            let mut cliprdr = CliprdrClient::new(channel.build_cliprdr_backend());
            let capabilities = ClipboardPdu::Capabilities(ChannelCapabilities::new(
                ClipboardProtocolVersion::V2,
                Capabilities::USE_LONG_FORMAT_NAMES,
            ));
            let ready = ClipboardPdu::FormatListResponse(FormatListResponse::Ok);
            for pdu in [capabilities, ready] {
                cliprdr
                    .process(&ironrdp_core::encode_vec(&pdu).unwrap())
                    .unwrap();
            }
            // The server copies twice and the app pastes each copy.
            for _ in 0..2 {
                let copy = ClipboardPdu::FormatList(
                    FormatList::new_unicode(&[text_format()], true).unwrap(),
                );
                let output = cliprdr
                    .process(&ironrdp_core::encode_vec(&copy).unwrap())
                    .unwrap();
                assert_eq!(
                    kinds(&output).last().map(String::as_str),
                    Some("FormatDataRequest")
                );
            }
            assert!(ordered.try_recv().is_err());

            // The server answers the first paste with text over the limit, in fragments.
            let mut svc = ironrdp_svc::StaticVirtualChannel::new(cliprdr);
            let declared = u32::try_from(DECLARED).unwrap();
            let mut message = vec![0x05, 0x00, 0x01, 0x00];
            message.extend_from_slice(&(declared - 8).to_le_bytes());
            message.resize(DECLARED, b'A');
            let count = message.len().div_ceil(1600);
            for (i, chunk) in message.chunks(1600).enumerate() {
                let flags = u32::from(i == 0) | (u32::from(i + 1 == count) << 1);
                let mut fragment = declared.to_le_bytes().to_vec();
                fragment.extend_from_slice(&flags.to_le_bytes());
                fragment.extend_from_slice(chunk);
                assert!(svc.process(&fragment).unwrap().is_empty());
            }
            drop(message);
            // The second answer goes to the second paste.
            let pdu =
                ClipboardPdu::FormatDataResponse(FormatDataResponse::new_data(utf16("after")));
            let pdu = ironrdp_core::encode_vec(&pdu).unwrap();
            let mut fragment = u32::try_from(pdu.len()).unwrap().to_le_bytes().to_vec();
            fragment.extend_from_slice(&3u32.to_le_bytes());
            fragment.extend_from_slice(&pdu);
            assert!(svc.process(&fragment).unwrap().is_empty());

            channel.jobs.flush(&connection);
            assert_eq!(delivered.texts, ["after"]);
            assert_eq!(
                delivered.logs,
                [format!(
                    "Clipboard remote data dropped reason=oversized count=1 max_length={DECLARED}"
                )]
            );
        }

        // oracle: mutant answering Monitor Ready or Format List through the session's ordered queue,
        // advertising the app's clipboard on connection, not counting a sent paste, or pasting past
        // the bound on unanswered requests.
        #[test]
        fn repeated_monitor_ready_and_copies_are_answered_without_queuing_for_the_session() {
            let (input, _events, mut ordered) = RdpInputSender::channel_with_ordered_queue(1);
            let (channel, _jobs) = test_channel(input);
            let mut cliprdr = CliprdrClient::new(channel.build_cliprdr_backend());
            let mut process = |pdu: ClipboardPdu<'_>| {
                cliprdr
                    .process(&ironrdp_core::encode_vec(&pdu).unwrap())
                    .unwrap()
            };
            let capabilities = ClipboardPdu::Capabilities(ChannelCapabilities::new(
                ClipboardProtocolVersion::V2,
                Capabilities::USE_LONG_FORMAT_NAMES,
            ));
            assert!(process(capabilities).is_empty());

            // A new connection advertises an empty format list in the initialization batch.
            let output = process(ClipboardPdu::MonitorReady);
            assert_eq!(
                kinds(&output),
                ["Capabilities", "TemporaryDirectory", "FormatList"]
            );
            let bytes = output[2].encode_unframed_pdu().unwrap();
            let ClipboardPdu::FormatList(list) = ironrdp_core::decode(&bytes).unwrap() else {
                panic!("expected a format list");
            };
            assert!(list.get_formats(true).unwrap().is_empty());
            assert!(process(ClipboardPdu::FormatListResponse(FormatListResponse::Ok)).is_empty());

            let mut requests = 0;
            for _ in 0..1000 {
                assert_eq!(kinds(&process(ClipboardPdu::MonitorReady)), ["FormatList"]);
                let copy = ClipboardPdu::FormatList(
                    FormatList::new_unicode(&[text_format()], true).unwrap(),
                );
                let output = kinds(&process(copy));
                assert_eq!(output[0], "FormatListResponse");
                assert!(output[1..].iter().all(|kind| kind == "FormatDataRequest"));
                requests += output.len() - 1;
            }
            let mut queued = 0;
            while ordered.try_recv().is_ok() {
                queued += 1;
            }
            assert_eq!(queued, 0);
            assert_eq!(requests, 64);
            let mut delivered = Delivered::default();
            let connection = delivering_connection(&mut delivered);
            for index in 1..=64 {
                let text = index.to_string();
                assert!(process(ClipboardPdu::FormatDataResponse(
                    FormatDataResponse::new_unicode_string(&text),
                ))
                .is_empty());
                channel.jobs.flush(&connection);
                assert_eq!(delivered.texts.last(), Some(&text));
            }
            assert_eq!(delivered.texts.len(), 64);
        }

        fn process(cliprdr: &mut CliprdrClient, pdu: ClipboardPdu<'_>) -> Vec<SvcMessage> {
            cliprdr
                .process(&ironrdp_core::encode_vec(&pdu).unwrap())
                .unwrap()
        }

        fn copy(cliprdr: &mut CliprdrClient, format: ClipboardFormat) -> Vec<SvcMessage> {
            process(
                cliprdr,
                ClipboardPdu::FormatList(FormatList::new_unicode(&[format], true).unwrap()),
            )
        }

        fn ready(cliprdr: &mut CliprdrClient) -> Vec<SvcMessage> {
            process(
                cliprdr,
                ClipboardPdu::FormatListResponse(FormatListResponse::Ok),
            )
        }

        fn client(channel: &Channel) -> CliprdrClient {
            let mut cliprdr = CliprdrClient::new(channel.build_cliprdr_backend());
            process(
                &mut cliprdr,
                ClipboardPdu::Capabilities(ChannelCapabilities::new(
                    ClipboardProtocolVersion::V2,
                    Capabilities::USE_LONG_FORMAT_NAMES,
                )),
            );
            cliprdr
        }

        fn answer(cliprdr: &mut CliprdrClient, response: FormatDataResponse<'_>) {
            process(cliprdr, ClipboardPdu::FormatDataResponse(response));
        }

        #[test]
        fn ready_paste_precedes_the_next_remote_copy() {
            let (input, _events, mut ordered) = RdpInputSender::channel_with_ordered_queue(1);
            let (channel, _jobs) = test_channel(input);
            let mut delivered = Delivered::default();
            let connection = delivering_connection(&mut delivered);
            let mut cliprdr = client(&channel);

            assert_eq!(
                kinds(&copy(&mut cliprdr, text_format())),
                ["FormatListResponse"]
            );
            assert_eq!(kinds(&ready(&mut cliprdr)), ["FormatDataRequest"]);
            assert_eq!(
                kinds(&copy(&mut cliprdr, file_format())),
                ["FormatListResponse", "FormatDataRequest"]
            );
            assert!(ordered.try_recv().is_err());

            answer(
                &mut cliprdr,
                FormatDataResponse::new_unicode_string("older"),
            );
            channel.jobs.flush(&connection);
            assert_eq!(delivered.texts, ["older"]);
            assert!(delivered.files.is_empty());
            answer(&mut cliprdr, file_list("newer.txt", 1));
            channel.jobs.flush(&connection);
            assert_eq!(delivered.files, [vec![("newer.txt".to_owned(), 1)]]);
        }

        #[test]
        fn locally_refused_paste_leaves_the_oldest_requests_pending() {
            let (input, _events) = RdpInputSender::channel(1);
            let (channel, _jobs) = test_channel(input);
            let mut delivered = Delivered::default();
            let connection = delivering_connection(&mut delivered);
            let mut cliprdr = client(&channel);
            ready(&mut cliprdr);
            copy(&mut cliprdr, text_format());
            copy(&mut cliprdr, file_format());
            for _ in 0..62 {
                copy(&mut cliprdr, text_format());
            }
            assert_eq!(
                kinds(&copy(&mut cliprdr, text_format())),
                ["FormatListResponse"]
            );

            answer(
                &mut cliprdr,
                FormatDataResponse::new_unicode_string("first"),
            );
            channel.jobs.flush(&connection);
            assert_eq!(delivered.texts, ["first"]);
            answer(&mut cliprdr, file_list("second.txt", 1));
            channel.jobs.flush(&connection);
            assert_eq!(delivered.files, [vec![("second.txt".to_owned(), 1)]]);
        }

        #[test]
        fn malformed_file_list_is_not_delivered_as_text() {
            let (input, _events) = RdpInputSender::channel(1);
            let (channel, _jobs) = test_channel(input);
            let mut cliprdr = client(&channel);
            ready(&mut cliprdr);
            copy(&mut cliprdr, file_format());
            answer(&mut cliprdr, FormatDataResponse::new_unicode_string("x"));
            assert!(lock(&channel.jobs.remote).is_none());
        }

        #[test]
        fn unsolicited_format_data_is_discarded() {
            let (input, _events) = RdpInputSender::channel(1);
            let (channel, _jobs) = test_channel(input);
            let mut cliprdr = client(&channel);
            ready(&mut cliprdr);
            answer(
                &mut cliprdr,
                FormatDataResponse::new_unicode_string("unsolicited"),
            );
            assert!(lock(&channel.jobs.remote).is_none());
        }

        #[test]
        fn deferred_copy_and_ready_belong_to_the_cliprdr_instance() {
            let (input, _events, mut ordered) = RdpInputSender::channel_with_ordered_queue(1);
            let (channel, _jobs) = test_channel(input);
            let mut previous = client(&channel);
            copy(&mut previous, text_format());
            drop(previous);
            let mut current = client(&channel);
            assert!(ready(&mut current).is_empty());
            assert!(ordered.try_recv().is_err());

            let mut next = client(&channel);
            assert_eq!(
                kinds(&copy(&mut next, text_format())),
                ["FormatListResponse"]
            );
            assert_eq!(kinds(&ready(&mut next)), ["FormatDataRequest"]);
            assert!(ordered.try_recv().is_err());
        }

        // oracle: mutant clip worker that never delivers the held server data.
        #[test]
        fn clip_worker_hands_the_held_remote_data_to_the_app() {
            let mut delivered = Delivered::default();
            let connection = Arc::new(delivering_connection(&mut delivered));
            let (jobs, worker) = ClipWork::spawn(Arc::clone(&connection)).unwrap();
            jobs.offer_remote(Remote::Text(utf16("한글")));
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            while lock(&jobs.remote).is_some() && std::time::Instant::now() < deadline {
                thread::sleep(Duration::from_millis(1));
            }
            connection.stop.store(true, Ordering::Release);
            worker.join().unwrap();
            drop(connection);
            assert_eq!(delivered.texts, ["한글"]);
        }

        // oracle: mutant queuing a log for each failed or malformed server response.
        #[test]
        fn failed_and_malformed_server_responses_are_counted_without_queuing() {
            let mut delivered = Delivered::default();
            let connection = delivering_connection(&mut delivered);
            let mut offered = Offered::new(Vec::new());
            let error = ClipboardPdu::FormatDataResponse(FormatDataResponse::new_error());
            for _ in 0..100 {
                // Unsolicited: CLIPRDR hands every format data response to the backend.
                offered
                    .cliprdr
                    .process(&ironrdp_core::encode_vec(&error).unwrap())
                    .unwrap();
                assert!(
                    offered.jobs.try_recv().is_err(),
                    "a failure queued clip work"
                );
            }
            // An odd number of bytes is not UTF-16.
            offered.remote_paste(
                text_format(),
                FormatDataResponse::new_data(vec![b'A', 0, 0]),
            );
            assert!(
                offered.jobs.try_recv().is_err(),
                "the text queued clip work"
            );

            offered.channel.jobs.flush(&connection);
            assert!(delivered.texts.is_empty());
            assert_eq!(
                delivered.logs,
                [
                    "Clipboard format data rejected reason=remote-failure count=100 max_length=0",
                    "Clipboard format data rejected reason=malformed-utf16 count=1 max_length=3",
                ]
            );
        }

        #[test]
        fn selects_first_matching_format() {
            let text = ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT);
            let files = ClipboardFormat::new(ClipboardFormatId::new(0xc001))
                .with_name(ClipboardFormatName::FILE_LIST);
            assert_eq!(choose_format(&[text.clone(), files.clone()]), Some(text.id));
            assert_eq!(choose_format(&[files.clone(), text]), Some(files.id));
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

        /// R1: only a DIRECTORY entry ends with the `\` marker the session reads as a folder.
        #[test]
        fn marks_only_directory_entries_with_a_trailing_backslash() {
            let folder = FileDescriptor::new("하위")
                .with_relative_path("폴더W")
                .with_attributes(ClipboardFileAttributes::DIRECTORY);
            let file = FileDescriptor::new("루트.txt")
                .with_relative_path("폴더W")
                .with_attributes(ClipboardFileAttributes::ARCHIVE);
            let bare = FileDescriptor::new("빈.txt");
            assert_eq!(remote_name(&folder), r"폴더W\하위\");
            assert_eq!(remote_name(&file), r"폴더W\루트.txt");
            assert_eq!(remote_name(&bare), "빈.txt");
        }

        fn range_recording_connection(responses: &mut Vec<(u32, Option<Vec<u8>>)>) -> Connection {
            extern "C" fn record_range(
                _: u64,
                stream_id: u32,
                ok: bool,
                bytes: *const u8,
                length: usize,
                context: *mut std::ffi::c_void,
            ) {
                let data =
                    ok.then(|| unsafe { std::slice::from_raw_parts(bytes, length).to_vec() });
                unsafe { &mut *context.cast::<Vec<(u32, Option<Vec<u8>>)>>() }
                    .push((stream_id, data));
            }
            let table = CNDFIronCallbacks {
                remote_file_contents: Some(record_range),
                context: (responses as *mut Vec<(u32, Option<Vec<u8>>)>).cast(),
                // Every other field is an optional callback.
                ..unsafe { std::mem::zeroed() }
            };
            Connection {
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
            }
        }

        /// A ready CLIPRDR client whose RANGE requests the test forwards itself.
        fn range_client() -> (
            Channel,
            CliprdrClient,
            mpsc::Receiver<Job>,
            mpsc::Receiver<Message>,
        ) {
            let (input, _events) = RdpInputSender::channel(1);
            let (mut channel, jobs) = test_channel(input);
            let (messages, receive) = mpsc::channel();
            channel.messages = Some(messages);
            let mut cliprdr = CliprdrClient::new(channel.build_cliprdr_backend());
            process(
                &mut cliprdr,
                ClipboardPdu::Capabilities(ChannelCapabilities::new(
                    ClipboardProtocolVersion::V2,
                    Capabilities::STREAM_FILECLIP_ENABLED | Capabilities::USE_LONG_FORMAT_NAMES,
                )),
            );
            ready(&mut cliprdr);
            (channel, cliprdr, jobs, receive)
        }

        fn submit_range(
            channel: &Channel,
            cliprdr: &mut CliprdrClient,
            receive: &mpsc::Receiver<Message>,
            stream_id: u32,
        ) {
            assert_eq!(
                channel.submit(ClipboardCommand::Range {
                    stream_id,
                    list_index: 0,
                    offset: 0,
                    length: 1,
                }),
                CNDF_IRON_OK
            );
            while let Ok(message) = receive.try_recv() {
                if let Message::SendFileContentsRequest(request) = message {
                    assert!(cliprdr
                        .request_file_contents_for_session(request)
                        .unwrap()
                        .is_some());
                }
            }
        }

        /// R2: any server Format List, even one with no supported format, fails the RANGE in
        /// flight once, and the late response for it is not delivered.
        #[test]
        fn server_format_list_fails_the_range_in_flight_once() {
            let mut responses = Vec::new();
            let connection = range_recording_connection(&mut responses);
            let (channel, mut cliprdr, jobs, receive) = range_client();
            submit_range(&channel, &mut cliprdr, &receive, 7);
            while jobs.try_recv().is_ok() {}

            let unsupported = ClipboardFormat::new(ClipboardFormatId::new(0xc123))
                .with_name(ClipboardFormatName::new("PNG"));
            copy(&mut cliprdr, unsupported);
            assert!(lock(&channel.state).requests.is_empty());
            while let Ok(job) = jobs.try_recv() {
                job(&connection);
            }

            process(
                &mut cliprdr,
                ClipboardPdu::FileContentsResponse(FileContentsResponse::new_data_response(
                    7,
                    vec![1],
                )),
            );
            while let Ok(job) = jobs.try_recv() {
                job(&connection);
            }
            assert_eq!(responses, [(7, None)]);
        }

        /// R3: a server Format List with no RANGE in flight notifies nothing.
        #[test]
        fn server_format_list_without_ranges_notifies_nothing() {
            let mut responses = Vec::new();
            let connection = range_recording_connection(&mut responses);
            let (channel, mut cliprdr, jobs, _receive) = range_client();
            while jobs.try_recv().is_ok() {}
            copy(&mut cliprdr, text_format());
            assert!(lock(&channel.state).requests.is_empty());
            while let Ok(job) = jobs.try_recv() {
                job(&connection);
            }
            assert!(responses.is_empty());
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

use super::*;

#[cfg(feature = "stub")]
use std::io::{Read, Seek, SeekFrom};

#[cfg_attr(not(feature = "stub"), allow(dead_code))]
pub(super) struct LocalFile {
    path: String,
    name: String,
    size: u64,
}

#[cfg_attr(not(feature = "stub"), allow(dead_code))]
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
        #[cfg(feature = "stub")]
        return CNDF_IRON_CAP_CLIPBOARD
            | CNDF_IRON_CAP_DRIVE
            | CNDF_IRON_CAP_AUDIO_LOCAL
            | CNDF_IRON_CAP_AUDIO_REMOTE;
        #[cfg(not(feature = "stub"))]
        0
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
    drop(command);
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
    let generation = connection.generation;
    while !connection.stop.load(Ordering::Acquire) {
        let command = match commands.recv_timeout(Duration::from_millis(5)) {
            Ok(command) => command,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        };
        match command {
            ClipboardCommand::Text(text) => {
                files.clear();
                connection.callbacks.invoke(|table| {
                    if let Some(callback) = table.remote_text {
                        callback(generation, text.as_ptr(), text.len(), table.context);
                    }
                });
            }
            ClipboardCommand::Files(offer) => {
                files = offer;
                let descriptors: Vec<_> = files
                    .iter()
                    .map(|file| CNDFIronRemoteFile {
                        name_utf8: file.name.as_ptr(),
                        name_length: file.name.len(),
                        size: file.size,
                    })
                    .collect();
                connection.callbacks.invoke(|table| {
                    if let Some(callback) = table.remote_file_list {
                        callback(
                            generation,
                            descriptors.as_ptr(),
                            descriptors.len(),
                            table.context,
                        );
                    }
                });
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
                connection.callbacks.invoke(|table| {
                    if let Some(callback) = table.remote_file_contents {
                        let (data, count) = bytes
                            .as_ref()
                            .map_or((ptr::null(), 0), |bytes| (bytes.as_ptr(), bytes.len()));
                        callback(
                            generation,
                            stream_id,
                            bytes.is_some(),
                            data,
                            count,
                            table.context,
                        );
                    }
                });
            }
        }
    }
}

#[cfg(feature = "stub")]
fn read_range(file: &LocalFile, offset: u64, length: u32) -> Option<Vec<u8>> {
    if length > 64 * 1024 * 1024 || offset.checked_add(u64::from(length))? > file.size {
        return None;
    }
    let mut source = std::fs::File::open(&file.path).ok()?;
    source.seek(SeekFrom::Start(offset)).ok()?;
    let mut bytes = vec![0; length as usize];
    source.read_exact(&mut bytes).ok()?;
    Some(bytes)
}

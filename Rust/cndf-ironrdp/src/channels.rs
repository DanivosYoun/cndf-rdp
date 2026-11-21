use super::*;
use std::mem::{offset_of, size_of};

pub(super) const V0_SIZE: usize = offset_of!(CNDFIronConnectOptions, clipboard);

#[allow(dead_code)]
pub(super) struct Options {
    pub clipboard: bool,
    pub drive: Option<(String, String)>,
    pub audio: CNDFIronAudioMode,
}

impl Options {
    pub(super) unsafe fn read(raw: *const CNDFIronConnectOptions) -> Option<Self> {
        use CNDFIronAudioMode::*;
        if (raw.cast::<u32>().read() as usize)
            < offset_of!(CNDFIronConnectOptions, audio_mode) + size_of::<CNDFIronAudioMode>()
        {
            return Some(Self {
                clipboard: false,
                drive: None,
                audio: CNDF_IRON_AUDIO_OFF,
            });
        }
        let clipboard = match ptr::addr_of!((*raw).clipboard).cast::<u8>().read() {
            0 => false,
            1 => true,
            _ => return None,
        };
        let audio = match ptr::addr_of!((*raw).audio_mode).cast::<u32>().read() {
            0 => CNDF_IRON_AUDIO_OFF,
            1 => CNDF_IRON_AUDIO_LOCAL,
            2 => CNDF_IRON_AUDIO_REMOTE,
            _ => return None,
        };
        let path = ptr::addr_of!((*raw).drive_path).read();
        let drive = if path.is_null() {
            None
        } else {
            let path = text(path)?;
            if !std::path::Path::new(&path).is_dir() {
                return None;
            }
            let name = ptr::addr_of!((*raw).drive_name).read();
            let name = if name.is_null() {
                "RemoteShare".to_owned()
            } else {
                text(name)?
            };
            Some((path, name))
        };
        Some(Self {
            clipboard,
            drive,
            audio,
        })
    }
}

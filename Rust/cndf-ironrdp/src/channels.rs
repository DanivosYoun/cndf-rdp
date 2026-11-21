use super::*;
use std::mem::{offset_of, size_of};

pub(super) const V0_SIZE: usize = offset_of!(CNDFIronConnectOptions, clipboard);

#[cfg_attr(feature = "stub", allow(dead_code))]
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

#[cfg(not(feature = "stub"))]
pub(super) use drive::{client_name, rdpdr_enabled, DriveFactory};

#[cfg(not(feature = "stub"))]
mod drive {
    use super::*;
    use ironrdp_pdu::PduResult;
    use ironrdp_rdpdr::backend::{
        RdpdrBackend, RdpdrBackendFactory, RdpdrBackendFactoryResult, RdpdrBackendProduct,
    };
    use ironrdp_rdpdr::pdu::efs::{
        AnyIoCtlCode, DecodedDeviceControlRequest, DeviceControlRequest,
        ServerDeviceAnnounceResponse, ServerDriveIoRequest,
    };
    use ironrdp_rdpdr::pdu::esc::{ScardCall, ScardIoCtlCode};
    use ironrdp_rdpdr_native::backend::NixRdpdrBackendFactory;
    use ironrdp_svc::SvcMessage;

    pub(crate) fn client_name() -> String {
        let mut hostname = [0u8; 256];
        let result = unsafe { libc::gethostname(hostname.as_mut_ptr().cast(), hostname.len()) };
        if result == 0 {
            short_name(&hostname)
        } else {
            String::new()
        }
    }

    fn short_name(hostname: &[u8]) -> String {
        let prefix = hostname
            .split(|byte| matches!(byte, 0 | b'.'))
            .next()
            .unwrap_or_default();
        let mut end = prefix.len().min(15);
        while let Err(error) = std::str::from_utf8(&prefix[..end]) {
            end = error.valid_up_to();
        }
        String::from_utf8_lossy(&prefix[..end]).into_owned()
    }

    pub(crate) fn rdpdr_enabled(drive: bool, audio: CNDFIronAudioMode) -> bool {
        drive || audio == CNDFIronAudioMode::CNDF_IRON_AUDIO_LOCAL
    }

    pub(crate) struct DriveFactory {
        factory: NixRdpdrBackendFactory,
        statistics: Arc<Mutex<CNDFIronStatistics>>,
    }

    impl DriveFactory {
        pub(crate) fn new(
            path: String,
            name: String,
            statistics: Arc<Mutex<CNDFIronStatistics>>,
        ) -> Self {
            Self {
                factory: NixRdpdrBackendFactory::new(path).with_drive(1, name),
                statistics,
            }
        }
    }

    impl RdpdrBackendFactory for DriveFactory {
        fn build_rdpdr_backend(&self) -> RdpdrBackendFactoryResult<RdpdrBackendProduct> {
            let (inner, drives) = self.factory.build_rdpdr_backend()?.into_parts();
            let drive = DriveBackend {
                inner,
                statistics: Arc::clone(&self.statistics),
            };
            Ok(RdpdrBackendProduct::new(Box::new(drive), drives))
        }
    }

    struct DriveBackend {
        inner: Box<dyn RdpdrBackend>,
        statistics: Arc<Mutex<CNDFIronStatistics>>,
    }

    ironrdp_core::impl_as_any!(DriveBackend);

    impl std::fmt::Debug for DriveBackend {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("DriveBackend")
        }
    }

    impl RdpdrBackend for DriveBackend {
        fn supports_drive_security(&self) -> bool {
            self.inner.supports_drive_security()
        }

        fn reset(&mut self) -> PduResult<()> {
            self.inner.reset()
        }

        fn restore_drive(&mut self, device_id: u32) -> PduResult<()> {
            self.inner.restore_drive(device_id)
        }

        fn handle_server_device_announce_response(
            &mut self,
            pdu: ServerDeviceAnnounceResponse,
        ) -> PduResult<()> {
            self.inner.handle_server_device_announce_response(pdu)
        }

        fn handle_scard_call(
            &mut self,
            req: DeviceControlRequest<ScardIoCtlCode>,
            call: ScardCall,
        ) -> PduResult<Vec<SvcMessage>> {
            self.inner.handle_scard_call(req, call)
        }

        fn handle_drive_io_request(
            &mut self,
            req: ServerDriveIoRequest,
        ) -> PduResult<Vec<SvcMessage>> {
            lock(&self.statistics).drive_io_requests += 1;
            self.inner.handle_drive_io_request(req)
        }

        fn handle_drive_device_control(
            &mut self,
            req: DecodedDeviceControlRequest<AnyIoCtlCode>,
        ) -> PduResult<Vec<SvcMessage>> {
            lock(&self.statistics).drive_io_requests += 1;
            self.inner.handle_drive_device_control(req)
        }

        fn poll_deferred_messages(&mut self) -> PduResult<Vec<SvcMessage>> {
            self.inner.poll_deferred_messages()
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use CNDFIronAudioMode::*;

        #[test]
        fn winpr_client_name() {
            assert_eq!(short_name(b"a.local\0"), "a");
            assert_eq!(short_name(b"01234567890123456789"), "012345678901234");
        }

        #[test]
        fn rdpdr_is_enabled_for_drive_or_local_sound() {
            for mode in [
                CNDF_IRON_AUDIO_OFF,
                CNDF_IRON_AUDIO_LOCAL,
                CNDF_IRON_AUDIO_REMOTE,
            ] {
                assert!(rdpdr_enabled(true, mode));
                assert_eq!(rdpdr_enabled(false, mode), mode == CNDF_IRON_AUDIO_LOCAL);
            }
        }
    }
}

#[cfg(not(feature = "stub"))]
pub(super) fn audio_mode(mode: CNDFIronAudioMode) -> ironrdp_cfg::AudioMode {
    use CNDFIronAudioMode::*;
    match mode {
        CNDF_IRON_AUDIO_OFF => ironrdp_cfg::AudioMode::Disabled,
        CNDF_IRON_AUDIO_LOCAL => ironrdp_cfg::AudioMode::RedirectToClient,
        CNDF_IRON_AUDIO_REMOTE => ironrdp_cfg::AudioMode::PlayOnServer,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn validates_drive_path_and_ignores_truncated_v1() {
        let dir = std::env::temp_dir().join(format!("cndf-iron-drive-{}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let file = dir.join("file");
        let link = dir.join("link");
        std::fs::File::create(&file).unwrap();
        std::os::unix::fs::symlink(&dir, &link).unwrap();
        let missing = CString::new(dir.join("missing").to_str().unwrap()).unwrap();
        let file = CString::new(file.to_str().unwrap()).unwrap();
        let link = CString::new(link.to_str().unwrap()).unwrap();
        let mut raw: CNDFIronConnectOptions = unsafe { std::mem::zeroed() };
        raw.struct_size = size_of::<CNDFIronConnectOptions>() as u32;
        let no_drive = unsafe { Options::read(&raw) }.unwrap();
        raw.drive_path = missing.as_ptr();
        let missing_drive = unsafe { Options::read(&raw) };
        raw.drive_path = file.as_ptr();
        let file_drive = unsafe { Options::read(&raw) };
        raw.drive_path = link.as_ptr();
        let linked_drive = unsafe { Options::read(&raw) }.unwrap();
        raw.clipboard = true;
        raw.struct_size = V0_SIZE as u32;
        let truncated = unsafe { Options::read(&raw) }.unwrap();
        std::fs::remove_dir_all(dir).unwrap();
        assert!(no_drive.drive.is_none());
        assert!(missing_drive.is_none());
        assert!(file_drive.is_none());
        assert_eq!(linked_drive.drive.unwrap().1, "RemoteShare");
        assert!(truncated.drive.is_none());
        assert!(!truncated.clipboard);
    }
}

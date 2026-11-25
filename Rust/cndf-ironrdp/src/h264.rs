//! H.264 decoding for the graphics pipeline through VideoToolbox (design m4-h264 D1-D6).
//!
//! Upstream `ironrdp-egfx` parses the AVC420 and AVC444 PDUs, owns one decoder per surface
//! stream and recombines AVC444 views. A decoder here only turns one access unit into the
//! planes of the picture it carries, synchronously, so the two AVC444 views pair up (H1).
//!
//! The access unit parser is platform independent; the VideoToolbox session exists on macOS
//! only, and elsewhere the connection gets no decoder and advertises no AVC capability set.

#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use std::sync::{Arc, Mutex};

use ironrdp_client::h264::H264DecoderFactory;

/// Log target the engine forwards with its message: the lines carry picture sizes, color
/// range and counts only.
pub(super) const H264_LOG_TARGET: &str = "cndf_rdp_h264";

/// Longest picture side VideoToolbox may allocate for, the desktop limit of patch 0004.
const MAX_SIDE: u32 = 8192;
/// Most pixels in one picture: 8K UHD rounded up to whole macroblocks (D6).
const MAX_PICTURE_PIXELS: u64 = 8192 * 4352;
/// Most pixels of the sessions alive in one connection at once (D6).
const CONNECTION_PIXEL_BUDGET: u64 = 2 * MAX_PICTURE_PIXELS;
/// Largest parameter set kept, as in FreeRDP.
const MAX_PARAMETER_SET: usize = 4096;
const SPS_IDS: usize = 32;
const PPS_IDS: usize = 256;

/// Creates the decoders of one connection, all sharing its pixel budget and adding to its
/// `totals`, or `None` where VideoToolbox is unavailable.
pub(super) fn factory(totals: Arc<Totals>) -> Option<H264DecoderFactory> {
    #[cfg(target_os = "macos")]
    {
        let budget = PixelBudget::new(CONNECTION_PIXEL_BUDGET);
        Some(H264DecoderFactory::new(move || {
            let decoder = vt::VtDecoder::new(budget.clone(), vt::probe_once);
            Some(Box::new(decoder.with_totals(Arc::clone(&totals))))
        }))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = totals;
        None
    }
}

/// What the decoders of one connection generation did (design iron-autologon-log). The
/// generation's end seals it and logs its summary once; a decode ending later changes nothing.
#[derive(Default)]
pub(super) struct Totals(Mutex<Tally>);

#[derive(Default, Clone, Copy)]
struct Tally {
    /// Decoded pictures, not frames delivered to the host.
    pictures: u64,
    /// Decode errors other than waiting for an IDR picture.
    failures: u64,
    idr_waits: u64,
    /// Created VideoToolbox sessions, by what VideoToolbox reported about them.
    hardware: u64,
    software: u64,
    unknown: u64,
    sealed: bool,
}

impl Totals {
    fn add<T: Default>(&self, change: impl FnOnce(&mut Tally) -> T) -> T {
        let mut tally = self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if !tally.sealed {
            change(&mut tally)
        } else {
            T::default()
        }
    }

    pub(super) fn picture(&self) {
        self.add(|tally| tally.pictures += 1);
    }

    pub(super) fn failure(&self) {
        self.add(|tally| tally.failures += 1);
    }

    pub(super) fn idr_wait(&self) {
        self.add(|tally| tally.idr_waits += 1);
    }

    pub(super) fn session(&self, hardware: Option<bool>) -> bool {
        self.add(|tally| {
            let first = tally.hardware == 0 && tally.software == 0 && tally.unknown == 0;
            match hardware {
                Some(true) => tally.hardware += 1,
                Some(false) => tally.software += 1,
                None => tally.unknown += 1,
            }
            first
        })
    }

    /// Seals the totals. The first call returns the summary line, if any decode was attempted.
    pub(super) fn seal(&self) -> Option<String> {
        let tally = {
            let mut tally = self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if tally.sealed {
                return None;
            }
            tally.sealed = true;
            *tally
        };
        if tally.pictures + tally.failures + tally.idr_waits == 0 {
            return None;
        }
        let sessions = tally.hardware + tally.software + tally.unknown;
        let hardware = if tally.unknown != 0 || sessions == 0 {
            "unknown"
        } else if tally.software == 0 {
            "yes"
        } else if tally.hardware == 0 {
            "no"
        } else {
            "mixed"
        };
        Some(format!(
            "H.264 summary pictures={} failures={} idr_waits={} sessions={sessions} hardware={hardware}",
            tally.pictures, tally.failures, tally.idr_waits,
        ))
    }
}

/// Pixels the live VideoToolbox sessions of one connection hold (H5).
#[derive(Clone)]
struct PixelBudget(Arc<Mutex<(u64, u64)>>);

impl PixelBudget {
    fn new(limit: u64) -> Self {
        Self(Arc::new(Mutex::new((0, limit))))
    }

    /// Takes `pixels` from the budget, or returns `false` when they do not fit.
    fn reserve(&self, pixels: u64) -> bool {
        let mut state = self
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (used, limit) = *state;
        match used.checked_add(pixels) {
            Some(total) if total <= limit => {
                state.0 = total;
                true
            }
            _ => false,
        }
    }

    fn release(&self, pixels: u64) {
        let mut state = self
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.0 = state.0.saturating_sub(pixels);
    }
}

/// What the parser found in one access unit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct AccessUnit {
    idr: bool,
    pps_id: u8,
}

/// The sequence and picture parameter sets a stream has sent, by id (D3-1).
struct ParameterSets {
    sps: Vec<Option<Vec<u8>>>,
    /// The picture parameter set and the id of the sequence parameter set it refers to.
    pps: Vec<Option<(u8, Vec<u8>)>>,
}

impl ParameterSets {
    fn new() -> Self {
        Self {
            sps: vec![None; SPS_IDS],
            pps: vec![None; PPS_IDS],
        }
    }

    fn clear(&mut self) {
        self.sps.iter_mut().for_each(|set| *set = None);
        self.pps.iter_mut().for_each(|set| *set = None);
    }

    /// The sequence and picture parameter sets picture parameter set `pps_id` selects.
    fn lookup(&self, pps_id: u8) -> Result<(&[u8], &[u8]), String> {
        let (sps_id, pps) = self.pps[usize::from(pps_id)]
            .as_ref()
            .ok_or_else(|| format!("no picture parameter set {pps_id}"))?;
        let sps = self.sps[usize::from(*sps_id)]
            .as_deref()
            .ok_or_else(|| format!("no sequence parameter set {sps_id}"))?;
        Ok((sps, pps))
    }

    /// Splits `data`, an Annex B byte stream or AVC-format NAL units, keeps its parameter sets,
    /// and writes the NAL units VideoToolbox decodes to `sample` with 4-byte length prefixes.
    fn parse(&mut self, data: &[u8], sample: &mut Vec<u8>) -> Result<AccessUnit, String> {
        sample.clear();
        let mut picture: Option<AccessUnit> = None;
        let mut nal_unit = |nal: &[u8]| -> Result<(), String> {
            let Some(&header) = nal.first() else {
                return Err("empty NAL unit".into());
            };
            if header & 0x80 != 0 {
                return Err("NAL unit with the forbidden bit set".into());
            }
            let kind = header & 0x1F;
            match kind {
                7 => {
                    let id = sps_id(nal)?;
                    self.sps[usize::from(id)] = Some(parameter_set(nal)?);
                }
                8 => {
                    let (id, sps) = pps_ids(nal)?;
                    self.pps[usize::from(id)] = Some((sps, parameter_set(nal)?));
                }
                9..=12 => {}
                1 | 5 | 6 => {
                    if kind != 6 {
                        let slice = AccessUnit {
                            idr: kind == 5,
                            pps_id: slice_pps_id(nal)?,
                        };
                        // One picture per access unit: FreeRDP rejects mixed slices too.
                        match picture {
                            None => picture = Some(slice),
                            Some(first) if first == slice => {}
                            Some(first) if first.idr != slice.idr => {
                                return Err("IDR and non-IDR slices in one access unit".into())
                            }
                            Some(_) => {
                                return Err("slices of different picture parameter sets".into())
                            }
                        }
                    }
                    let length = u32::try_from(nal.len()).map_err(|_| "NAL unit too long")?;
                    sample.extend_from_slice(&length.to_be_bytes());
                    sample.extend_from_slice(nal);
                }
                _ => return Err(format!("unsupported NAL unit type {kind}")),
            }
            Ok(())
        };
        if ironrdp_egfx::pdu::is_avc_format(data) {
            let mut rest = data;
            while let Some((length, tail)) = rest.split_first_chunk::<4>() {
                let length = usize::try_from(u32::from_be_bytes(*length))
                    .map_err(|_| "NAL unit too long")?;
                let (nal, tail) = tail
                    .split_at_checked(length)
                    .ok_or("NAL unit past the end")?;
                nal_unit(nal)?;
                rest = tail;
            }
        } else {
            for nal in annex_b_units(data) {
                nal_unit(nal)?;
            }
        }
        picture.ok_or_else(|| "access unit without a picture".into())
    }
}

fn parameter_set(nal: &[u8]) -> Result<Vec<u8>, String> {
    if nal.len() > MAX_PARAMETER_SET {
        return Err(format!("parameter set of {} bytes", nal.len()));
    }
    Ok(nal.to_vec())
}

/// Splits an Annex B byte stream into NAL units without their start codes, one at a time,
/// so a unit is checked before the rest of the input is searched.
fn annex_b_units(data: &[u8]) -> impl Iterator<Item = &[u8]> {
    let mut next = after_start_code(data, 0);
    core::iter::from_fn(move || loop {
        let start = next?;
        next = after_start_code(data, start);
        let mut end = next.map_or(data.len(), |after| after - 3);
        // Zero bytes before a start code belong to it (a 4-byte start code or trailing_zero_8bits).
        while end > start && data[end - 1] == 0 {
            end -= 1;
        }
        if end > start {
            return Some(&data[start..end]);
        }
    })
}

/// The position after the first start code at or after `from`.
fn after_start_code(data: &[u8], from: usize) -> Option<usize> {
    data.get(from..)?
        .windows(3)
        .position(|window| window == [0, 0, 1])
        .map(|at| from + at + 3)
}

/// Reads the Exp-Golomb fields at the start of a NAL unit's payload.
struct Bits {
    /// The first payload bytes with emulation prevention bytes removed.
    bytes: [u8; 32],
    len: usize,
    bit: usize,
}

impl Bits {
    /// Starts after the one-byte NAL header and `skip` more payload bytes.
    fn new(nal: &[u8], skip: usize) -> Self {
        let mut bits = Self {
            bytes: [0; 32],
            len: 0,
            bit: 0,
        };
        let mut zeros = 0;
        for &byte in nal.iter().skip(1) {
            if zeros >= 2 && byte == 3 {
                zeros = 0;
                continue;
            }
            zeros = if byte == 0 { zeros + 1 } else { 0 };
            if bits.len == bits.bytes.len() {
                break;
            }
            bits.bytes[bits.len] = byte;
            bits.len += 1;
        }
        bits.bit = skip * 8;
        bits
    }

    fn read_bit(&mut self) -> Result<u32, String> {
        let byte = self
            .bytes
            .get(self.bit / 8)
            .filter(|_| self.bit / 8 < self.len)
            .ok_or("NAL unit header field past the end")?;
        let value = (byte >> (7 - self.bit % 8)) & 1;
        self.bit += 1;
        Ok(u32::from(value))
    }

    /// An unsigned Exp-Golomb value, ue(v).
    fn read_ue(&mut self) -> Result<u32, String> {
        let mut zeros = 0;
        while self.read_bit()? == 0 {
            zeros += 1;
            if zeros > 31 {
                return Err("Exp-Golomb value too long".into());
            }
        }
        let mut value = 0u64;
        for _ in 0..zeros {
            value = value << 1 | u64::from(self.read_bit()?);
        }
        u32::try_from((1u64 << zeros) - 1 + value).map_err(|_| "Exp-Golomb value too large".into())
    }

    fn read_id(&mut self, ids: usize, what: &str) -> Result<u8, String> {
        let id = self.read_ue()?;
        match u8::try_from(id) {
            Ok(id) if usize::from(id) < ids => Ok(id),
            _ => Err(format!("{what} id {id}")),
        }
    }
}

/// `seq_parameter_set_id`, after `profile_idc`, the constraint flags and `level_idc`.
fn sps_id(nal: &[u8]) -> Result<u8, String> {
    Bits::new(nal, 3).read_id(SPS_IDS, "sequence parameter set")
}

/// `pic_parameter_set_id` and the `seq_parameter_set_id` it refers to.
fn pps_ids(nal: &[u8]) -> Result<(u8, u8), String> {
    let mut bits = Bits::new(nal, 0);
    let pps = bits.read_id(PPS_IDS, "picture parameter set")?;
    let sps = bits.read_id(SPS_IDS, "sequence parameter set")?;
    Ok((pps, sps))
}

/// `pic_parameter_set_id`, after `first_mb_in_slice` and `slice_type`.
fn slice_pps_id(nal: &[u8]) -> Result<u8, String> {
    let mut bits = Bits::new(nal, 0);
    bits.read_ue()?;
    bits.read_ue()?;
    bits.read_id(PPS_IDS, "picture parameter set")
}

/// VideoToolbox decompression session behind `ironrdp_egfx::decode::H264Decoder` (D2-D3).
///
/// cbindgen:ignore
#[cfg(target_os = "macos")]
#[allow(non_upper_case_globals, non_snake_case)]
mod vt {
    use core::ffi::c_void;
    use std::ptr;
    use std::sync::OnceLock;

    use ironrdp_egfx::decode::{
        DecodedFrame, DecoderError, DecoderResult, H264Decoder, Yuv420Frame,
    };
    use tracing::{debug, info};

    use super::{
        AccessUnit, ParameterSets, PixelBudget, Totals, H264_LOG_TARGET, MAX_PICTURE_PIXELS,
        MAX_SIDE,
    };
    use std::sync::Arc;

    type OSStatus = i32;
    type Ref = *const c_void;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CMTime {
        value: i64,
        timescale: i32,
        flags: u32,
        epoch: i64,
    }

    #[repr(C)]
    struct CMVideoDimensions {
        width: i32,
        height: i32,
    }

    type OutputCallback =
        extern "C" fn(*mut c_void, *mut c_void, OSStatus, u32, Ref, CMTime, CMTime);

    #[repr(C)]
    struct VTDecompressionOutputCallbackRecord {
        callback: OutputCallback,
        refcon: *mut c_void,
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        static kCFTypeDictionaryKeyCallBacks: u8;
        static kCFTypeDictionaryValueCallBacks: u8;
        static kCFBooleanTrue: Ref;
        fn CFRelease(cf: Ref);
        fn CFDictionaryCreate(
            allocator: Ref,
            keys: *const Ref,
            values: *const Ref,
            count: isize,
            key_callbacks: *const c_void,
            value_callbacks: *const c_void,
        ) -> Ref;
        fn CFNumberCreate(allocator: Ref, kind: isize, value: *const c_void) -> Ref;
    }

    #[link(name = "CoreVideo", kind = "framework")]
    extern "C" {
        static kCVPixelBufferPixelFormatTypeKey: Ref;
        fn CVPixelBufferRetain(buffer: Ref) -> Ref;
        fn CVPixelBufferRelease(buffer: Ref);
        fn CVPixelBufferLockBaseAddress(buffer: Ref, flags: u64) -> i32;
        fn CVPixelBufferUnlockBaseAddress(buffer: Ref, flags: u64) -> i32;
        fn CVPixelBufferGetWidth(buffer: Ref) -> usize;
        fn CVPixelBufferGetHeight(buffer: Ref) -> usize;
        fn CVPixelBufferGetPlaneCount(buffer: Ref) -> usize;
        fn CVPixelBufferGetPixelFormatType(buffer: Ref) -> u32;
        fn CVPixelBufferGetBaseAddressOfPlane(buffer: Ref, plane: usize) -> *const u8;
        fn CVPixelBufferGetBytesPerRowOfPlane(buffer: Ref, plane: usize) -> usize;
        fn CVPixelBufferGetHeightOfPlane(buffer: Ref, plane: usize) -> usize;
    }

    #[link(name = "CoreMedia", kind = "framework")]
    extern "C" {
        static kCMFormatDescriptionExtension_FullRangeVideo: Ref;
        fn CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: Ref,
            count: usize,
            pointers: *const *const u8,
            sizes: *const usize,
            nal_header_length: i32,
            out: *mut Ref,
        ) -> OSStatus;
        fn CMFormatDescriptionGetExtension(description: Ref, key: Ref) -> Ref;
        fn CMVideoFormatDescriptionGetDimensions(description: Ref) -> CMVideoDimensions;
        fn CMBlockBufferCreateWithMemoryBlock(
            allocator: Ref,
            memory: *mut c_void,
            length: usize,
            block_allocator: Ref,
            custom_source: *const c_void,
            offset: usize,
            data_length: usize,
            flags: u32,
            out: *mut Ref,
        ) -> OSStatus;
        fn CMBlockBufferReplaceDataBytes(
            source: *const c_void,
            destination: Ref,
            offset: usize,
            length: usize,
        ) -> OSStatus;
        fn CMSampleBufferCreateReady(
            allocator: Ref,
            data: Ref,
            format: Ref,
            samples: isize,
            timings: isize,
            timing: *const c_void,
            sizes_count: isize,
            sizes: *const usize,
            out: *mut Ref,
        ) -> OSStatus;
    }

    #[link(name = "VideoToolbox", kind = "framework")]
    extern "C" {
        static kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder: Ref;
        static kVTDecompressionPropertyKey_RealTime: Ref;
        fn VTDecompressionSessionCreate(
            allocator: Ref,
            format: Ref,
            decoder_specification: Ref,
            image_attributes: Ref,
            callback: *const VTDecompressionOutputCallbackRecord,
            out: *mut Ref,
        ) -> OSStatus;
        fn VTDecompressionSessionCanAcceptFormatDescription(session: Ref, format: Ref) -> u8;
        fn VTDecompressionSessionDecodeFrame(
            session: Ref,
            sample: Ref,
            flags: u32,
            frame_refcon: *mut c_void,
            info: *mut u32,
        ) -> OSStatus;
        fn VTDecompressionSessionInvalidate(session: Ref);
        fn VTDecompressionSessionWaitForAsynchronousFrames(session: Ref) -> OSStatus;
        fn VTSessionCopyProperty(
            session: Ref,
            key: Ref,
            allocator: Ref,
            out: *mut c_void,
        ) -> OSStatus;
        fn VTSessionSetProperty(session: Ref, key: Ref, value: Ref) -> OSStatus;
    }

    /// Planar 4:2:0 in the stream's own range: VideoToolbox converts nothing (H2).
    const PLANAR_VIDEO_RANGE: u32 = u32::from_be_bytes(*b"y420");
    const PLANAR_FULL_RANGE: u32 = u32::from_be_bytes(*b"f420");
    const CF_NUMBER_SINT32: isize = 3;
    const BLOCK_BUFFER_ASSURE_MEMORY_NOW: u32 = 1;
    /// Synchronous decoding without temporal processing (D3-4, H1).
    const DECODE_FLAGS: u32 = 0;
    const DECODE_INFO_ASYNCHRONOUS: u32 = 1;
    const LOCK_READ_ONLY: u64 = 1;

    /// A 64x64 gray IDR picture with its parameter sets (x264, SEI removed), decoded once per
    /// process before AVC is advertised (D3-6).
    pub(super) const PROBE_STREAM: &[u8] = &[
        0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x0a, 0xac, 0xd9, 0x44, 0x26, 0xc0, 0x5b, 0x20,
        0x00, 0x00, 0x03, 0x00, 0x20, 0x00, 0x00, 0x06, 0x41, 0xe2, 0x44, 0xb2, 0xc0, 0x00, 0x00,
        0x00, 0x01, 0x68, 0xeb, 0xe1, 0x12, 0xc8, 0xb0, 0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84,
        0x00, 0xff, 0xfe, 0xbb, 0x3a, 0x50, 0x3e, 0x94, 0x35, 0x2e, 0xc7, 0x16, 0x78, 0x08, 0x25,
        0xf7, 0x90, 0xc4, 0x81,
    ];

    #[cfg(test)]
    pub(super) static CALLBACKS: std::sync::atomic::AtomicU64 =
        std::sync::atomic::AtomicU64::new(0);

    /// Whether VideoToolbox decodes the probe picture, decided once per process.
    pub(super) fn probe_once() -> bool {
        static READY: OnceLock<bool> = OnceLock::new();
        *READY.get_or_init(|| probe(PROBE_STREAM))
    }

    /// Whether a fresh decoder decodes `stream` to a 64x64 picture.
    pub(super) fn probe(stream: &[u8]) -> bool {
        let mut decoder = VtDecoder::new(PixelBudget::new(MAX_PICTURE_PIXELS), || true);
        decoder.quiet = true;
        let ready = decoder
            .decode_yuv420(stream)
            .is_ok_and(|picture| picture.width() == 64 && picture.height() == 64);
        debug!(target: H264_LOG_TARGET, "H.264 decoder: VideoToolbox probe ready={ready}");
        ready
    }

    /// One decode call's output, written by the callback. Boxed, so its address is stable.
    #[derive(Default)]
    struct Slot {
        count: u32,
        status: OSStatus,
        image: Ref,
    }

    extern "C" fn on_output(
        _session_refcon: *mut c_void,
        frame_refcon: *mut c_void,
        status: OSStatus,
        _info: u32,
        image: Ref,
        _presentation: CMTime,
        _duration: CMTime,
    ) {
        #[cfg(test)]
        CALLBACKS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        // SAFETY: `frame_refcon` is the `Slot` `Session::decode` passed to DecodeFrame. It
        // outlives the call because the session waits for its frames before the slot drops,
        // and VideoToolbox calls back for one frame at a time.
        let slot = unsafe { &mut *frame_refcon.cast::<Slot>() };
        slot.count += 1;
        slot.status = status;
        if !image.is_null() {
            // SAFETY: `image` is a valid CVPixelBuffer for the duration of the callback; the
            // retain keeps it, and the slot holds at most one, releasing an earlier one.
            unsafe {
                if !slot.image.is_null() {
                    CVPixelBufferRelease(slot.image);
                }
                slot.image = CVPixelBufferRetain(image);
            }
        }
    }

    /// A Core Foundation object this code owns one reference to, or NULL.
    struct Owned(Ref);

    impl Drop for Owned {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // SAFETY: the reference was returned by a Create function and is released once.
                unsafe { CFRelease(self.0) }
            }
        }
    }

    /// A retained decoded picture.
    struct PixelBuffer(Ref);

    impl Drop for PixelBuffer {
        fn drop(&mut self) {
            // SAFETY: the callback retained the buffer once, and only this guard releases it.
            unsafe { CVPixelBufferRelease(self.0) }
        }
    }

    /// The stream format parameter sets describe.
    struct Format {
        description: Owned,
        sps: Vec<u8>,
        pps: Vec<u8>,
        width: u32,
        height: u32,
        full_range: bool,
    }

    impl Format {
        /// Describes `sps` and `pps`, or fails when the picture is outside the limits (H5).
        fn new(sps: &[u8], pps: &[u8]) -> Result<Self, String> {
            let pointers = [sps.as_ptr(), pps.as_ptr()];
            let sizes = [sps.len(), pps.len()];
            let mut description: Ref = ptr::null();
            // SAFETY: both arrays hold two entries pointing at live parameter sets of the given
            // sizes, and `description` receives an owned reference on success.
            let status = unsafe {
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    ptr::null(),
                    2,
                    pointers.as_ptr(),
                    sizes.as_ptr(),
                    4,
                    &mut description,
                )
            };
            if status != 0 || description.is_null() {
                return Err(format!("parameter sets rejected status={status}"));
            }
            let description = Owned(description);
            // SAFETY: `description` is a valid video format description.
            let (dimensions, full_range) = unsafe {
                (
                    CMVideoFormatDescriptionGetDimensions(description.0),
                    CMFormatDescriptionGetExtension(
                        description.0,
                        kCMFormatDescriptionExtension_FullRangeVideo,
                    ) == kCFBooleanTrue,
                )
            };
            let (Ok(width), Ok(height)) = (
                u32::try_from(dimensions.width),
                u32::try_from(dimensions.height),
            ) else {
                return Err("negative picture size".into());
            };
            if width == 0
                || height == 0
                || width > MAX_SIDE
                || height > MAX_SIDE
                || u64::from(width) * u64::from(height) > MAX_PICTURE_PIXELS
            {
                return Err(format!("picture {width}x{height} outside the limits"));
            }
            Ok(Self {
                description,
                sps: sps.to_vec(),
                pps: pps.to_vec(),
                width,
                height,
                full_range,
            })
        }

        fn pixels(&self) -> u64 {
            u64::from(self.width) * u64::from(self.height)
        }

        fn pixel_format(&self) -> u32 {
            if self.full_range {
                PLANAR_FULL_RANGE
            } else {
                PLANAR_VIDEO_RANGE
            }
        }
    }

    /// A decompression session and the pixels it holds of its connection's budget (H4, H5).
    struct Session {
        session: Ref,
        format: Format,
        budget: PixelBudget,
        hardware: Option<bool>,
    }

    impl Session {
        fn new(format: Format, budget: &PixelBudget) -> Result<Self, String> {
            if !budget.reserve(format.pixels()) {
                return Err(format!(
                    "connection picture budget exhausted by {}x{}",
                    format.width, format.height
                ));
            }
            let pixel_format = format.pixel_format();
            let record = VTDecompressionOutputCallbackRecord {
                callback: on_output,
                refcon: ptr::null_mut(),
            };
            let mut session: Ref = ptr::null();
            // SAFETY: the number, dictionary and session are created and released here; the
            // dictionary retains the number and the session copies the attributes. A NULL
            // decoder specification lets VideoToolbox pick hardware or software (D3-3).
            let status = unsafe {
                let number = Owned(CFNumberCreate(
                    ptr::null(),
                    CF_NUMBER_SINT32,
                    (&pixel_format as *const u32).cast(),
                ));
                let keys = [kCVPixelBufferPixelFormatTypeKey];
                let values = [number.0];
                let attributes = Owned(CFDictionaryCreate(
                    ptr::null(),
                    keys.as_ptr(),
                    values.as_ptr(),
                    1,
                    (&kCFTypeDictionaryKeyCallBacks as *const u8).cast(),
                    (&kCFTypeDictionaryValueCallBacks as *const u8).cast(),
                ));
                VTDecompressionSessionCreate(
                    ptr::null(),
                    format.description.0,
                    ptr::null(),
                    attributes.0,
                    &record,
                    &mut session,
                )
            };
            if status != 0 || session.is_null() {
                budget.release(format.pixels());
                return Err(format!("decompression session rejected status={status}"));
            }
            let mut hardware = None;
            // SAFETY: `session` is the valid session just created. The copied property is an
            // owned CFBoolean or NULL.
            unsafe {
                VTSessionSetProperty(
                    session,
                    kVTDecompressionPropertyKey_RealTime,
                    kCFBooleanTrue,
                );
                let mut value: Ref = ptr::null();
                if VTSessionCopyProperty(
                    session,
                    kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                    ptr::null(),
                    (&mut value as *mut Ref).cast(),
                ) == 0
                    && !value.is_null()
                {
                    hardware = Some(value == kCFBooleanTrue);
                    CFRelease(value);
                }
            }
            Ok(Self {
                session,
                format,
                budget: budget.clone(),
                hardware,
            })
        }

        fn uses(&self, sps: &[u8], pps: &[u8]) -> bool {
            self.format.sps == sps && self.format.pps == pps
        }

        /// Switches to `format` when the session decodes it unchanged, or gives it back.
        fn accept(&mut self, format: Format) -> Result<(), Format> {
            // SAFETY: both the session and the description are valid.
            let accepts = unsafe {
                VTDecompressionSessionCanAcceptFormatDescription(self.session, format.description.0)
            } != 0;
            // The size is the session's budget share and the range its output pixel format.
            if accepts
                && format.width == self.format.width
                && format.height == self.format.height
                && format.full_range == self.format.full_range
            {
                self.format = format;
                Ok(())
            } else {
                Err(format)
            }
        }

        /// Decodes one length-prefixed access unit to its picture (H1).
        fn decode(&mut self, sample: &[u8], stats: &mut Stats) -> Result<PixelBuffer, String> {
            let length = sample.len();
            let mut block: Ref = ptr::null();
            // SAFETY: the block buffer allocates `length` bytes now and copies `sample` into them.
            let block = unsafe {
                let status = CMBlockBufferCreateWithMemoryBlock(
                    ptr::null(),
                    ptr::null_mut(),
                    length,
                    ptr::null(),
                    ptr::null(),
                    0,
                    length,
                    BLOCK_BUFFER_ASSURE_MEMORY_NOW,
                    &mut block,
                );
                if status != 0 || block.is_null() {
                    return Err(format!("block buffer status={status}"));
                }
                let block = Owned(block);
                let status =
                    CMBlockBufferReplaceDataBytes(sample.as_ptr().cast(), block.0, 0, length);
                if status != 0 {
                    return Err(format!("block buffer copy status={status}"));
                }
                block
            };
            let mut sample_buffer: Ref = ptr::null();
            // SAFETY: `block` and the format description are valid, and `length` is one size.
            let status = unsafe {
                CMSampleBufferCreateReady(
                    ptr::null(),
                    block.0,
                    self.format.description.0,
                    1,
                    0,
                    ptr::null(),
                    1,
                    &length,
                    &mut sample_buffer,
                )
            };
            if status != 0 || sample_buffer.is_null() {
                return Err(format!("sample buffer status={status}"));
            }
            let sample_buffer = Owned(sample_buffer);
            let mut slot = Box::new(Slot::default());
            let mut info = 0u32;
            // SAFETY: the session and sample are valid. The slot outlives every callback for
            // this frame: the session is waited for before the slot drops.
            let (status, before_return) = unsafe {
                let status = VTDecompressionSessionDecodeFrame(
                    self.session,
                    sample_buffer.0,
                    DECODE_FLAGS,
                    (&mut *slot as *mut Slot).cast(),
                    &mut info,
                );
                let before_return = slot.count;
                VTDecompressionSessionWaitForAsynchronousFrames(self.session);
                (status, before_return)
            };
            let image = (!slot.image.is_null()).then(|| PixelBuffer(slot.image));
            stats.decodes += 1;
            stats.callbacks += u64::from(slot.count);
            stats.outputs_before_return += u64::from(before_return == 1);
            stats.late_outputs += u64::from(slot.count - before_return);
            stats.asynchronous += u64::from(info & DECODE_INFO_ASYNCHRONOUS != 0);
            match image {
                Some(image) if status == 0 && slot.status == 0 && slot.count == 1 => Ok(image),
                _ => Err(format!(
                    "decode status={status} callback={} outputs={}",
                    slot.status, slot.count
                )),
            }
        }
    }

    impl Drop for Session {
        fn drop(&mut self) {
            // SAFETY: the session is valid and released once, after it has delivered its
            // frames and been invalidated, so no callback follows (H4).
            unsafe {
                VTDecompressionSessionWaitForAsynchronousFrames(self.session);
                VTDecompressionSessionInvalidate(self.session);
                CFRelease(self.session);
            }
            self.budget.release(self.format.pixels());
        }
    }

    /// What one decoder did over its lifetime (D3-8).
    #[derive(Default, Debug, Clone, Copy)]
    pub(super) struct Stats {
        pub(super) pictures: u64,
        pub(super) failures: u64,
        pub(super) idr_waits: u64,
        pub(super) sessions: u64,
        pub(super) decodes: u64,
        pub(super) callbacks: u64,
        pub(super) outputs_before_return: u64,
        pub(super) late_outputs: u64,
        pub(super) asynchronous: u64,
    }

    enum Failure {
        WaitingForIdr,
        Other(String),
    }

    impl From<String> for Failure {
        fn from(message: String) -> Self {
            Self::Other(message)
        }
    }

    /// Capacity the access unit copy keeps between decodes, as upstream
    /// `MAX_DECOMPRESSED_BUFFER_CAPACITY` keeps for the decompression buffer.
    const KEPT_SAMPLE_CAPACITY: usize = 16 * 1024;

    /// One surface stream's decoder: owns at most one VideoToolbox session (D2).
    pub(super) struct VtDecoder {
        sets: ParameterSets,
        budget: PixelBudget,
        ready: fn() -> bool,
        session: Option<Session>,
        /// Set until an IDR picture decodes after creation, a failure or a reset (H3).
        needs_idr: bool,
        sample: Vec<u8>,
        quiet: bool,
        /// The connection generation's totals this decoder adds to.
        totals: Option<Arc<Totals>>,
        pub(super) stats: Stats,
    }

    // SAFETY: the session and the Core Foundation objects it holds are only used through
    // `&mut self`, one thread at a time, and VideoToolbox sessions are not bound to a thread.
    unsafe impl Send for VtDecoder {}

    impl VtDecoder {
        /// A decoder taking its sessions' pixels from `budget`, ready when `ready` says so.
        pub(super) fn new(budget: PixelBudget, ready: fn() -> bool) -> Self {
            Self {
                sets: ParameterSets::new(),
                budget,
                ready,
                session: None,
                needs_idr: true,
                sample: Vec::new(),
                quiet: false,
                totals: None,
                stats: Stats::default(),
            }
        }

        /// Adds this decoder's results to `totals`.
        pub(super) fn with_totals(mut self, totals: Arc<Totals>) -> Self {
            self.totals = Some(totals);
            self
        }

        fn total(&self, add: impl FnOnce(&Totals)) {
            if let Some(totals) = &self.totals {
                add(totals);
            }
        }

        /// Whether the live session outputs full-range pictures.
        #[cfg(test)]
        pub(super) fn full_range(&self) -> Option<bool> {
            self.session
                .as_ref()
                .map(|session| session.format.full_range)
        }

        /// How many bytes the access unit copy holds on to between decodes.
        #[cfg(test)]
        pub(super) fn sample_capacity(&self) -> usize {
            self.sample.capacity()
        }

        fn end_stream(&mut self) {
            self.session = None;
            self.needs_idr = true;
        }

        fn decode_picture(&mut self, data: &[u8]) -> Result<Yuv420Frame, Failure> {
            let unit: AccessUnit = self.sets.parse(data, &mut self.sample)?;
            // Before any session work, so a failing VideoToolbox is only retried on IDR (D3-2).
            if self.needs_idr && !unit.idr {
                return Err(Failure::WaitingForIdr);
            }
            let (sps, pps) = self.sets.lookup(unit.pps_id)?;
            if !self
                .session
                .as_ref()
                .is_some_and(|session| session.uses(sps, pps))
            {
                let format = Format::new(sps, pps)?;
                let format = match self.session.as_mut() {
                    Some(session) => session.accept(format).err(),
                    None => Some(format),
                };
                if let Some(format) = format {
                    self.end_stream();
                    if !unit.idr {
                        return Err(Failure::WaitingForIdr);
                    }
                    let session = Session::new(format, &self.budget)?;
                    self.stats.sessions += 1;
                    let first = self
                        .totals
                        .as_ref()
                        .is_some_and(|totals| totals.session(session.hardware));
                    if first && !self.quiet {
                        let hardware = if session.hardware == Some(true) { "yes" } else { "no" };
                        let format = if session.format.full_range { "f420" } else { "y420" };
                        info!(target: H264_LOG_TARGET, "IronRDP h264 decoder: hardware={hardware} format={format}");
                    }
                    self.session = Some(session);
                }
            }
            let Some(session) = self.session.as_mut() else {
                return Err(Failure::Other("no decompression session".into()));
            };
            let pixel_format = session.format.pixel_format();
            let image = session.decode(&self.sample, &mut self.stats)?;
            let picture = planes(&image, pixel_format)?;
            self.needs_idr = false;
            Ok(picture)
        }
    }

    /// Copies the three planes of `image` byte for byte (D3-5, H2).
    fn planes(image: &PixelBuffer, pixel_format: u32) -> Result<Yuv420Frame, String> {
        let buffer = image.0;
        // SAFETY: `buffer` is a retained CVPixelBuffer. Its planes are read only between the
        // lock and the unlock, and each plane is `bytes per row * rows` bytes long.
        unsafe {
            if CVPixelBufferGetPixelFormatType(buffer) != pixel_format
                || CVPixelBufferGetPlaneCount(buffer) != 3
            {
                return Err("unexpected picture layout".into());
            }
            if CVPixelBufferLockBaseAddress(buffer, LOCK_READ_ONLY) != 0 {
                return Err("picture lock failed".into());
            }
            let plane = |index: usize| {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, index);
                let rows = CVPixelBufferGetHeightOfPlane(buffer, index);
                let base = CVPixelBufferGetBaseAddressOfPlane(buffer, index);
                if base.is_null() {
                    return (stride, Vec::new());
                }
                (
                    stride,
                    std::slice::from_raw_parts(base, stride * rows).to_vec(),
                )
            };
            let (luma_stride, y) = plane(0);
            let (u_stride, u) = plane(1);
            let (v_stride, v) = plane(2);
            let (width, height) = (
                CVPixelBufferGetWidth(buffer),
                CVPixelBufferGetHeight(buffer),
            );
            CVPixelBufferUnlockBaseAddress(buffer, LOCK_READ_ONLY);
            if u_stride != v_stride {
                return Err("chroma strides differ".into());
            }
            let (Ok(width), Ok(height)) = (u16::try_from(width), u16::try_from(height)) else {
                return Err("picture too large".into());
            };
            Yuv420Frame::new(width, height, y, luma_stride, u, v, u_stride)
                .map_err(|error| error.to_string())
        }
    }

    impl H264Decoder for VtDecoder {
        fn decode(&mut self, data: &[u8]) -> DecoderResult<DecodedFrame> {
            self.decode_yuv420(data).map(|picture| picture.to_rgba())
        }

        fn decode_yuv420(&mut self, data: &[u8]) -> DecoderResult<Yuv420Frame> {
            let result = self.decode_picture(data);
            // Whatever the result, a large access unit's copy must not stay for the
            // decoder's life; upstream bounds its decompression buffer the same way.
            self.sample.clear();
            self.sample.shrink_to(KEPT_SAMPLE_CAPACITY);
            match result {
                Ok(picture) => {
                    self.stats.pictures += 1;
                    self.total(Totals::picture);
                    Ok(picture)
                }
                Err(Failure::WaitingForIdr) => {
                    self.stats.idr_waits += 1;
                    self.total(Totals::idr_wait);
                    Err(DecoderError::msg("waiting for an IDR picture"))
                }
                // The graphics pipeline already logs dropped updates at a bounded rate.
                Err(Failure::Other(message)) => {
                    self.stats.failures += 1;
                    self.total(Totals::failure);
                    self.end_stream();
                    debug!(target: H264_LOG_TARGET, "H.264 decode failed: {message}");
                    Err(DecoderError::msg(message))
                }
            }
        }

        fn supports_yuv420(&self) -> bool {
            true
        }

        fn wait_until_ready(&mut self) -> bool {
            (self.ready)()
        }

        fn reset(&mut self) {
            self.end_stream();
            self.sets.clear();
        }
    }

    // The connection generation summarizes the totals when it ends (`Connection::end`).
    impl Drop for VtDecoder {
        fn drop(&mut self) {
            self.session = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn annex_b(units: &[&[u8]]) -> Vec<u8> {
        units
            .iter()
            .flat_map(|nal| [&[0, 0, 0, 1][..], nal].concat())
            .collect()
    }

    fn avc(units: &[&[u8]]) -> Vec<u8> {
        units
            .iter()
            .flat_map(|nal| [&(nal.len() as u32).to_be_bytes()[..], nal].concat())
            .collect()
    }

    /// Writes unsigned Exp-Golomb values after `prefix`, then the stop bit and padding.
    fn nal(prefix: &[u8], values: &[u32]) -> Vec<u8> {
        let mut bits = Vec::new();
        for &value in values {
            let code = u64::from(value) + 1;
            let length = 64 - code.leading_zeros() as usize;
            bits.extend(std::iter::repeat_n(0u8, length - 1));
            bits.extend((0..length).rev().map(|bit| (code >> bit & 1) as u8));
        }
        bits.push(1);
        while bits.len() % 8 != 0 {
            bits.push(0);
        }
        let mut out = prefix.to_vec();
        out.extend(
            bits.chunks(8)
                .map(|byte| byte.iter().fold(0, |acc, &bit| acc << 1 | bit)),
        );
        out
    }

    fn sps(id: u32) -> Vec<u8> {
        nal(&[0x67, 0x64, 0x00, 0x1f], &[id])
    }

    fn pps(id: u32, sps: u32) -> Vec<u8> {
        nal(&[0x68], &[id, sps])
    }

    fn slice(kind: u8, pps: u32) -> Vec<u8> {
        nal(&[0x60 | kind], &[0, if kind == 5 { 7 } else { 5 }, pps])
    }

    fn parse(sets: &mut ParameterSets, data: &[u8]) -> Result<(AccessUnit, Vec<u8>), String> {
        let mut sample = Vec::new();
        sets.parse(data, &mut sample).map(|unit| (unit, sample))
    }

    #[test]
    fn access_units_keep_parameter_sets_by_id_and_select_them_through_the_slice() {
        let mut sets = ParameterSets::new();
        let (sps0, sps31, pps0, pps255) = (sps(0), sps(31), pps(0, 31), pps(255, 0));
        let (idr, sei) = (slice(5, 255), [0x06, 0x05, 0x01, 0x80]);
        let aud = [0x09, 0xf0];
        let data = annex_b(&[&aud, &sps0, &sps31, &pps0, &pps255, &sei, &idr]);
        let (unit, sample) = parse(&mut sets, &data).unwrap();
        assert_eq!(
            unit,
            AccessUnit {
                idr: true,
                pps_id: 255
            }
        );
        // Only SEI and slices reach VideoToolbox, length prefixed.
        assert_eq!(sample, avc(&[&sei, &idr]));
        assert_eq!(sets.lookup(255).unwrap(), (&sps0[..], &pps255[..]));
        assert_eq!(sets.lookup(0).unwrap(), (&sps31[..], &pps0[..]));
        let (unit, _) = parse(&mut sets, &annex_b(&[&slice(1, 0)])).unwrap();
        assert_eq!(
            unit,
            AccessUnit {
                idr: false,
                pps_id: 0
            }
        );
        assert!(sets
            .lookup(1)
            .unwrap_err()
            .contains("no picture parameter set 1"));
        sets.clear();
        assert!(sets.lookup(0).is_err());
    }

    #[test]
    fn avc_format_input_parses_like_annex_b() {
        let units: [&[u8]; 3] = [&sps(2), &pps(9, 2), &slice(5, 9)];
        let (mut a, mut b) = (ParameterSets::new(), ParameterSets::new());
        assert_eq!(parse(&mut a, &annex_b(&units)), parse(&mut b, &avc(&units)));
        assert_eq!(a.lookup(9).unwrap(), b.lookup(9).unwrap());
        // A 3-byte start code and trailing zero bytes are Annex B too.
        let mut c = ParameterSets::new();
        let data = [
            &[0, 0, 1][..],
            &sps(2),
            &[0, 0, 0, 0, 1],
            &pps(9, 2),
            &[0, 0, 1],
            &slice(5, 9),
            &[0, 0],
        ]
        .concat();
        assert_eq!(parse(&mut c, &data), parse(&mut a, &annex_b(&units)));
    }

    #[test]
    fn exp_golomb_fields_skip_emulation_prevention_bytes() {
        // pic_parameter_set_id 0 is a single 1 bit; force 00 00 03 before it with zero bytes.
        let mut sets = ParameterSets::new();
        assert_eq!(pps_ids(&nal(&[0x68], &[200, 17])).unwrap(), (200, 17));
        // ue(65535) starts with fifteen zero bits: 00 00 is followed by an inserted 03.
        let raw = nal(&[0x68], &[65535]);
        let escaped = [&raw[..3], &[3], &raw[3..]].concat();
        assert!(pps_ids(&escaped)
            .unwrap_err()
            .contains("picture parameter set id 65535"));
        assert!(parse(&mut sets, &annex_b(&[&escaped])).is_err());
    }

    #[test]
    fn malformed_access_units_are_rejected() {
        let mut sets = ParameterSets::new();
        let base: [&[u8]; 2] = [&sps(0), &pps(0, 0)];
        parse(&mut sets, &annex_b(&base)).unwrap_err();
        let cases: [(&str, Vec<u8>); 9] = [
            ("sequence parameter set id 32", annex_b(&[&sps(32)])),
            ("picture parameter set id 256", annex_b(&[&pps(256, 0)])),
            ("sequence parameter set id 32", annex_b(&[&pps(1, 32)])),
            (
                "parameter set of 4097 bytes",
                annex_b(&[&[&sps(1)[..], &[0x55; 4097 - 5]].concat()]),
            ),
            (
                "unsupported NAL unit type 20",
                annex_b(&[&[0x74, 0x80], &slice(5, 0)]),
            ),
            ("unsupported NAL unit type 0", annex_b(&[&[0x00, 0x80]])),
            ("forbidden bit", annex_b(&[&[0xe5, 0x80]])),
            (
                "IDR and non-IDR slices",
                annex_b(&[&slice(5, 0), &slice(1, 0)]),
            ),
            (
                "different picture parameter sets",
                annex_b(&[&slice(1, 0), &slice(1, 3)]),
            ),
        ];
        for (error, data) in cases {
            let result = parse(&mut sets, &data);
            assert!(
                result.as_ref().is_err_and(|e| e.contains(error)),
                "{error}: {result:?}"
            );
        }
        assert!(parse(&mut sets, &annex_b(&[&[0x09, 0xf0]]))
            .unwrap_err()
            .contains("without a picture"));
        assert!(parse(&mut sets, &annex_b(&[&[0x65]]))
            .unwrap_err()
            .contains("past the end"));
        // A rejected oversized set leaves the stored one in place.
        assert_eq!(sets.lookup(0).unwrap().0, &sps(0)[..]);
    }

    #[test]
    fn pixel_budget_takes_and_returns_pixels() {
        let budget = PixelBudget::new(100);
        assert!(budget.reserve(60));
        assert!(!budget.clone().reserve(41));
        assert!(budget.reserve(40));
        assert!(!budget.reserve(1));
        budget.release(60);
        assert!(budget.reserve(60));
        assert!(!budget.reserve(u64::MAX));
    }

    // Design iron-autologon-log: what one generation's summary counts.
    #[test]
    fn totals_summarize_decode_results_once() {
        let totals = Totals::default();
        totals.idr_wait();
        totals.session(Some(true));
        totals.picture();
        totals.picture();
        totals.failure();
        totals.session(Some(true));
        totals.picture();
        assert_eq!(
            totals.seal().as_deref(),
            Some("H.264 summary pictures=3 failures=1 idr_waits=1 sessions=2 hardware=yes")
        );
        // A decode ending after the seal changes nothing, and the summary is not repeated.
        totals.picture();
        totals.failure();
        assert_eq!(totals.seal(), None);
    }

    #[test]
    fn totals_without_a_decode_attempt_have_no_summary() {
        assert_eq!(Totals::default().seal(), None);
        // A session alone is not a decode attempt.
        let totals = Totals::default();
        totals.session(Some(true));
        assert_eq!(totals.seal(), None);
    }

    #[test]
    fn totals_summarize_attempts_without_pictures() {
        let totals = Totals::default();
        totals.idr_wait();
        totals.idr_wait();
        assert_eq!(
            totals.seal().as_deref(),
            Some("H.264 summary pictures=0 failures=0 idr_waits=2 sessions=0 hardware=unknown")
        );
    }

    #[test]
    fn totals_report_hardware_only_when_every_session_is_hardware() {
        let cases: [(&[Option<bool>], &str); 6] = [
            (&[Some(true), Some(true)], "sessions=2 hardware=yes"),
            (&[Some(false)], "sessions=1 hardware=no"),
            (&[Some(true), Some(false)], "sessions=2 hardware=mixed"),
            (&[Some(true), None], "sessions=2 hardware=unknown"),
            (&[None], "sessions=1 hardware=unknown"),
            (&[], "sessions=0 hardware=unknown"),
        ];
        for (sessions, expected) in cases {
            let totals = Totals::default();
            for &hardware in sessions {
                totals.session(hardware);
            }
            totals.picture();
            let summary = totals.seal().unwrap();
            assert!(summary.ends_with(expected), "{summary} vs {expected}");
        }
    }

    /// The splitter before it became lazy: every start position, then every end position.
    fn indexed_annex_b_units(data: &[u8]) -> Vec<&[u8]> {
        let mut starts = Vec::new();
        let mut i = 0;
        while i + 3 <= data.len() {
            if data[i..i + 3] == [0, 0, 1] {
                starts.push(i + 3);
                i += 3;
            } else {
                i += 1;
            }
        }
        let ends = starts
            .iter()
            .skip(1)
            .map(|&next| next - 3)
            .chain([data.len()]);
        starts
            .iter()
            .zip(ends)
            .filter_map(|(&start, mut end)| {
                while end > start && data[end - 1] == 0 {
                    end -= 1;
                }
                (end > start).then(|| &data[start..end])
            })
            .collect()
    }

    #[test]
    fn annex_b_units_split_as_the_indexed_splitter_did() {
        let mut seed = 0x2545_f491_4f6c_dd1du64;
        for length in (0..400).chain([4096]) {
            let data: Vec<u8> = (0..length)
                .map(|_| {
                    seed ^= seed << 13;
                    seed ^= seed >> 7;
                    seed ^= seed << 17;
                    // Mostly zeros and ones, so start codes and trailing zeros are frequent.
                    [0, 0, 0, 1, 0x65, 0x41, 0x09, 0x55][(seed >> 61) as usize]
                })
                .collect();
            assert_eq!(
                annex_b_units(&data).collect::<Vec<_>>(),
                indexed_annex_b_units(&data),
                "{data:02x?}"
            );
        }
    }

    // annex-b-index-amplification: a 60 MiB access unit of four-byte delimiters made the
    // splitter allocate 248 MiB of start and end positions before it looked at one unit.
    // The lazy splitter holds the input and one position, so it cannot hold an index.
    #[test]
    fn annex_b_units_keep_no_index_of_the_input() {
        let data = [0, 0, 1, 9].repeat(4096);
        let units = annex_b_units(&data);
        assert!(
            core::mem::size_of_val(&units) <= core::mem::size_of::<(&[u8], Option<usize>)>(),
            "splitter of {} bytes",
            core::mem::size_of_val(&units)
        );
        assert_eq!(units.count(), 4096);
        let mut sets = ParameterSets::new();
        assert_eq!(
            parse(&mut sets, &data).unwrap_err(),
            "access unit without a picture"
        );
    }

    #[test]
    fn the_factory_exists_only_with_videotoolbox() {
        assert_eq!(factory(Arc::default()).is_some(), cfg!(target_os = "macos"));
    }
}

/// VideoToolbox against checked-in streams (design m4-h264 T1-T8).
///
/// The streams in `tests/data/h264` come from x264 and their `.fnv` hashes from ffmpeg's
/// software decode of the same files, regenerated with:
///
/// ```text
/// H264_VECTORS=<dir> cargo test --lib h264::vt_tests::write_sources -- --ignored
/// cd <dir>
/// for r in pc tv; do ffmpeg -f rawvideo -pix_fmt yuv420p -s 320x240 -i main420.yuv -c:v libx264 \
///   -preset fast -qp 30 -x264-params keyint=infinite:min-keyint=infinite:scenecut=0:bframes=0:ref=2:aud=1:threads=4:sliced-threads=1 \
///   -color_range $r -f h264 avc420-$r.h264; done
/// ffmpeg -f rawvideo -pix_fmt yuv420p -s 320x240 -i v2pairs.yuv -c:v libx264 -preset fast -qp 30 \
///   -x264-params keyint=infinite:min-keyint=infinite:scenecut=0:bframes=0:ref=2:aud=1:threads=4:sliced-threads=1 \
///   -color_range pc -f h264 avc444v2.h264
/// for s in avc420-pc avc420-tv avc444v2; do ffmpeg -i $s.h264 -fps_mode passthrough -f rawvideo $s.ref.yuv; done
/// H264_VECTORS=<dir> cargo test --lib h264::vt_tests::write_reference_hashes -- --ignored
/// ```
///
/// Oversized parameter sets: `ffmpeg -f lavfi -i color=black:s=8208x16 -frames 1 -c:v libx264 -qp 51
/// -x264-params aud=1 -f h264 side-8208x16.h264`, and the same for `area-8192x4368`. The probe
/// stream is `color=gray:s=64x64 -frames 1 -qp 30 -x264-params aud=0 -color_range pc` without its SEI.
#[cfg(all(test, target_os = "macos"))]
mod vt_tests {
    use std::sync::{Mutex, MutexGuard};

    use ironrdp_core::{decode, encode_vec};
    use ironrdp_dvc::DvcProcessor;
    use ironrdp_egfx::avc444::{Avc444Layout, Yuv444Frame};
    use ironrdp_egfx::client::{GraphicsPipelineClient, GraphicsPipelineHandler};
    use ironrdp_egfx::decode::{H264Decoder, Yuv420Frame};
    use ironrdp_egfx::pdu::GfxPdu;
    use ironrdp_pdu::geometry::ExclusiveRectangle;

    use super::vt::{probe, probe_once, VtDecoder, CALLBACKS};
    use super::*;

    const DATA: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/h264/");
    const WIDTH: u16 = 320;
    const HEIGHT: u16 = 240;
    const FRAMES: usize = 30;

    /// VideoToolbox tests run one at a time, so footprint and callback counts are their own.
    fn serial() -> MutexGuard<'static, ()> {
        static LOCK: Mutex<()> = Mutex::new(());
        LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn read(name: &str) -> Vec<u8> {
        std::fs::read(format!("{DATA}{name}")).unwrap()
    }

    /// Splits an Annex B stream at its access unit delimiters.
    fn access_units(stream: &[u8]) -> Vec<Vec<u8>> {
        let mut units: Vec<Vec<u8>> = Vec::new();
        let mut i = 0;
        let mut start = None;
        while i + 4 < stream.len() {
            if stream[i..i + 4] == [0, 0, 0, 1] && stream[i + 4] & 0x1f == 9 {
                if let Some(start) = start {
                    units.push(stream[start..i].to_vec());
                }
                start = Some(i);
            }
            i += 1;
        }
        units.push(stream[start.unwrap()..].to_vec());
        units
    }

    fn decoder() -> VtDecoder {
        VtDecoder::new(PixelBudget::new(u64::MAX), probe_once)
    }

    /// FNV-1a over the visible luma, U and V rows.
    fn fnv(planes: impl IntoIterator<Item = impl AsRef<[u8]>>) -> u64 {
        planes.into_iter().fold(0xcbf2_9ce4_8422_2325, |hash, row| {
            row.as_ref().iter().fold(hash, |hash, &byte| {
                (hash ^ u64::from(byte)).wrapping_mul(0x100_0000_01b3)
            })
        })
    }

    fn picture_hash(picture: &Yuv420Frame) -> u64 {
        let (h, ch) = (
            usize::from(picture.height()),
            usize::from(picture.height().div_ceil(2)),
        );
        let rows = (0..h)
            .map(|row| picture.luma_row(row).unwrap())
            .chain((0..ch).map(|row| picture.u_row(row).unwrap()))
            .chain((0..ch).map(|row| picture.v_row(row).unwrap()));
        fnv(rows)
    }

    fn reference_hashes(name: &str) -> Vec<u64> {
        String::from_utf8(read(&format!("{name}.fnv")))
            .unwrap()
            .lines()
            .map(|line| u64::from_str_radix(line, 16).unwrap())
            .collect()
    }

    /// Synthetic desktop: gradient, frame counter bar, a box changing color as it moves, and
    /// one-pixel colored glyph rows scrolling four rows per frame.
    fn source_rgba(frame: usize) -> Vec<u8> {
        let (w, h) = (usize::from(WIDTH), usize::from(HEIGHT));
        let mut rgba = vec![0u8; w * h * 4];
        let (bx, by) = ((frame * 7) % (w - 48), 40 + (frame * 5) % (h - 120));
        let colors = [
            [255, 0, 0],
            [0, 200, 0],
            [0, 0, 255],
            [255, 255, 0],
            [255, 0, 255],
            [0, 255, 255],
        ];
        for y in 0..h {
            for x in 0..w {
                let mut pixel = [(x * 255 / w) as u8, (y * 255 / h) as u8, 128];
                if y < 8 && x < frame * 10 {
                    pixel = [255, 255, 255];
                }
                if (bx..bx + 48).contains(&x) && (by..by + 48).contains(&y) {
                    pixel = [
                        (frame * 37) as u8,
                        255 - (frame * 23) as u8,
                        (frame * 91) as u8,
                    ];
                }
                if (150..166).contains(&y) && (16..176).contains(&x) {
                    let line = y + 4 * frame;
                    let seed =
                        (line as u32).wrapping_mul(2_654_435_761) ^ (x as u32).wrapping_mul(40_503);
                    if seed.rotate_left(13).wrapping_mul(0x9e37_79b9) >> 27 == 0 {
                        pixel = colors[line % colors.len()];
                    } else {
                        pixel = [16, 16, 16];
                    }
                }
                rgba[(y * w + x) * 4..][..4].copy_from_slice(&[pixel[0], pixel[1], pixel[2], 255]);
            }
        }
        rgba
    }

    fn source_views(frame: usize) -> (Yuv420Frame, Yuv420Frame) {
        Yuv444Frame::from_rgba(&source_rgba(frame), WIDTH, HEIGHT)
            .unwrap()
            .split(Avc444Layout::V2)
            .unwrap()
    }

    fn write_yuv(out: &mut Vec<u8>, picture: &Yuv420Frame) {
        let (h, ch) = (
            usize::from(picture.height()),
            usize::from(picture.height().div_ceil(2)),
        );
        (0..h).for_each(|row| out.extend_from_slice(picture.luma_row(row).unwrap()));
        (0..ch).for_each(|row| out.extend_from_slice(picture.u_row(row).unwrap()));
        (0..ch).for_each(|row| out.extend_from_slice(picture.v_row(row).unwrap()));
    }

    #[test]
    #[ignore = "regenerates the encoder input of tests/data/h264"]
    fn write_sources() {
        let dir = std::env::var("H264_VECTORS").unwrap();
        let (mut main, mut pairs) = (Vec::new(), Vec::new());
        for frame in 0..FRAMES {
            let (main_view, aux_view) = source_views(frame);
            write_yuv(&mut main, &main_view);
            write_yuv(&mut pairs, &main_view);
            write_yuv(&mut pairs, &aux_view);
        }
        std::fs::write(format!("{dir}/main420.yuv"), main).unwrap();
        std::fs::write(format!("{dir}/v2pairs.yuv"), pairs).unwrap();
    }

    #[test]
    #[ignore = "regenerates the ffmpeg reference hashes of tests/data/h264"]
    fn write_reference_hashes() {
        let dir = std::env::var("H264_VECTORS").unwrap();
        let (w, h) = (usize::from(WIDTH), usize::from(HEIGHT));
        let size = w * h * 3 / 2;
        for name in ["avc420-pc", "avc420-tv", "avc444v2"] {
            let reference = std::fs::read(format!("{dir}/{name}.ref.yuv")).unwrap();
            assert_eq!(reference.len() % size, 0);
            let lines: String = reference
                .chunks_exact(size)
                .map(|picture| format!("{:016x}\n", fnv([picture])))
                .collect();
            std::fs::write(format!("{DATA}{name}.fnv"), lines).unwrap();
        }
    }

    /// Decodes every access unit of `name`, which must all succeed.
    fn decode_all(decoder: &mut VtDecoder, name: &str) -> Vec<Yuv420Frame> {
        access_units(&read(&format!("{name}.h264")))
            .iter()
            .map(|unit| decoder.decode_yuv420(unit).unwrap())
            .collect()
    }

    // T1: planes byte for byte equal to ffmpeg's decode, in the stream's own range.
    #[test]
    fn pictures_equal_the_reference_decode() {
        let _serial = serial();
        for (name, full_range, count) in [
            ("avc420-pc", true, FRAMES),
            ("avc420-tv", false, FRAMES),
            ("avc444v2", true, 2 * FRAMES),
        ] {
            let mut decoder = decoder();
            let pictures = decode_all(&mut decoder, name);
            assert_eq!(decoder.full_range(), Some(full_range), "{name}");
            let hashes: Vec<u64> = pictures.iter().map(picture_hash).collect();
            assert_eq!(hashes.len(), count, "{name}");
            assert_eq!(hashes, reference_hashes(name), "{name}");
            assert!(pictures
                .iter()
                .all(|p| (p.width(), p.height()) == (WIDTH, HEIGHT)));
        }
    }

    // T2: every picture is delivered before DecodeFrame returns, never asynchronously.
    #[test]
    fn every_picture_is_delivered_before_the_decode_call_returns() {
        let _serial = serial();
        let mut decoder = decoder();
        let pictures = decode_all(&mut decoder, "avc444v2").len()
            + decode_all(&mut decoder, "avc420-tv").len();
        let stats = decoder.stats;
        assert_eq!(stats.pictures, pictures as u64);
        assert_eq!(stats.decodes, pictures as u64);
        assert_eq!(stats.outputs_before_return, pictures as u64);
        assert_eq!(stats.callbacks, pictures as u64);
        assert_eq!(
            (stats.late_outputs, stats.asynchronous, stats.failures),
            (0, 0, 0)
        );
    }

    fn psnr(a: &[u8], b: &[u8]) -> f64 {
        let (mut sum, mut count) = (0f64, 0f64);
        for (a, b) in a.chunks_exact(4).zip(b.chunks_exact(4)) {
            for channel in 0..3 {
                let d = f64::from(a[channel]) - f64::from(b[channel]);
                sum += d * d;
                count += 1.0;
            }
        }
        10.0 * (255.0 * 255.0 / (sum / count)).log10()
    }

    fn combine(main: &Yuv420Frame, aux: &Yuv420Frame) -> Vec<u8> {
        let rect = ExclusiveRectangle {
            left: 0,
            top: 0,
            right: WIDTH,
            bottom: HEIGHT,
        };
        let mut frame = Yuv444Frame::new(WIDTH, HEIGHT);
        frame.apply_main_view(main, core::slice::from_ref(&rect));
        frame.apply_auxiliary_view(Avc444Layout::V2, aux, core::slice::from_ref(&rect));
        frame.to_rgba(&rect)
    }

    // T3: the upstream AVC444v2 recombination of each decoded pair reproduces the source,
    // and pairing a main view with another picture's auxiliary view does not.
    #[test]
    fn avc444v2_views_pair_up_with_their_own_picture() {
        let _serial = serial();
        let views = decode_all(&mut decoder(), "avc444v2");
        let (mut paired, mut shifted) = (Vec::new(), Vec::new());
        for frame in 1..FRAMES {
            let source = source_rgba(frame);
            paired.push(psnr(
                &combine(&views[2 * frame], &views[2 * frame + 1]),
                &source,
            ));
            let other = (frame + FRAMES / 2) % FRAMES;
            shifted.push(psnr(
                &combine(&views[2 * frame], &views[2 * other + 1]),
                &source,
            ));
        }
        let mean = |v: &[f64]| v.iter().sum::<f64>() / v.len() as f64;
        let (paired, shifted) = (mean(&paired), mean(&shifted));
        eprintln!("AVC444v2 PSNR paired={paired:.2} dB shifted={shifted:.2} dB");
        assert!(paired >= PAIRED_PSNR, "{paired}");
        assert!(paired - shifted >= 6.0, "{paired} {shifted}");
    }

    /// Mean RGB PSNR of the recombined pairs against the source, measured with ffmpeg-equal
    /// views less a margin.
    const PAIRED_PSNR: f64 = 28.3;

    // Design iron-autologon-log: every decoder of a generation adds to its totals, through
    // several surfaces, a reset, IDR waits and a decode error; another generation's stay apart.
    #[test]
    fn factory_decoders_add_to_their_generation_totals() {
        let _serial = serial();
        let units = access_units(&read("avc420-pc.h264"));
        let totals = Arc::new(Totals::default());
        let other = Arc::new(Totals::default());
        let factory = factory(Arc::clone(&totals)).unwrap();
        let _other_factory = factory_for_other_generation(&other);
        let mut first = factory.create().unwrap();
        let mut second = factory.create().unwrap();
        // First surface: a P before any IDR waits, then the whole stream decodes.
        assert!(first.decode_yuv420(&units[1]).is_err());
        for unit in &units {
            first.decode_yuv420(unit).unwrap();
        }
        // Second surface: one decode error, a wait for the next IDR, then a reset and the IDR.
        second.decode_yuv420(&units[0]).unwrap();
        assert!(second
            .decode_yuv420(&[&units[1][..], &[0, 0, 0, 1, 0x74, 0x80]].concat())
            .is_err());
        assert!(second.decode_yuv420(&units[2]).is_err());
        second.reset();
        second.decode_yuv420(&units[0]).unwrap();
        // Dropping decoders (surface deletion) summarizes nothing.
        drop(first);
        drop(second);
        let pictures = units.len() + 2;
        assert_eq!(
            totals.seal(),
            Some(format!(
                "H.264 summary pictures={pictures} failures=1 idr_waits=2 sessions=3 hardware=yes"
            ))
        );
        assert_eq!(other.seal(), None);
    }

    fn factory_for_other_generation(totals: &Arc<Totals>) -> ironrdp_client::h264::H264DecoderFactory {
        factory(Arc::clone(totals)).unwrap()
    }

    // T4: no picture and no session before an IDR, after a failure or after a reset.
    #[test]
    fn non_idr_access_units_wait_for_an_idr_without_creating_a_session() {
        let _serial = serial();
        let units = access_units(&read("avc420-pc.h264"));
        let (idr, p) = (&units[0], &units[1]);
        let slice = idr.windows(4).position(|w| w == [0, 0, 1, 0x65]).unwrap();
        let parameter_sets_and_p = [&idr[..slice], p].concat();
        let mut decoder = decoder();
        let error = decoder.decode_yuv420(&parameter_sets_and_p).unwrap_err();
        assert!(
            error.to_string().contains("waiting for an IDR picture"),
            "{error}"
        );
        assert_eq!(
            (
                decoder.stats.sessions,
                decoder.stats.idr_waits,
                decoder.stats.decodes
            ),
            (0, 1, 0)
        );
        decoder.decode_yuv420(idr).unwrap();
        decoder.decode_yuv420(p).unwrap();
        assert_eq!(decoder.stats.sessions, 1);

        // A failed access unit ends the session; the next P waits without a new one.
        decoder
            .decode_yuv420(&[&p[..], &[0, 0, 0, 1, 0x74, 0x80]].concat())
            .unwrap_err();
        assert_eq!(decoder.stats.failures, 1);
        decoder.decode_yuv420(&units[2]).unwrap_err();
        assert_eq!((decoder.stats.sessions, decoder.stats.idr_waits), (1, 2));
        decoder.decode_yuv420(idr).unwrap();
        assert_eq!(decoder.stats.sessions, 2);

        // reset forgets the parameter sets and the session.
        decoder.reset();
        decoder.decode_yuv420(p).unwrap_err();
        assert_eq!((decoder.stats.sessions, decoder.stats.idr_waits), (2, 3));
        decoder.decode_yuv420(idr).unwrap();
        assert_eq!(decoder.stats.sessions, 3);
    }

    /// Deterministic xorshift, so the corrupted streams are the same on every run.
    struct Rng(u64);

    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0
        }

        fn below(&mut self, n: usize) -> usize {
            (self.next() % n as u64) as usize
        }
    }

    // T5: corrupted P pictures never crash, and every following IDR decodes.
    #[test]
    fn corrupted_access_units_fail_cleanly_and_the_next_idr_recovers() {
        let _serial = serial();
        let units = access_units(&read("avc420-pc.h264"));
        let mut rng = Rng(0x5eed_cafe_f00d_0001);
        let mut decoder = decoder();
        let (mut failed, mut recovered) = (0, 0);
        for _ in 0..400 {
            decoder.decode_yuv420(&units[0]).unwrap();
            let mut unit = units[1 + rng.below(units.len() - 1)].clone();
            // Past the delimiter and the slice's NAL header, flip bytes or cut the unit short.
            let start = 8;
            for _ in 0..1 + rng.below(8) {
                let at = start + rng.below(unit.len() - start);
                unit[at] ^= 1 << rng.below(8);
            }
            if rng.below(4) == 0 {
                unit.truncate(start + 1 + rng.below(unit.len() - start - 1));
            }
            failed += usize::from(decoder.decode_yuv420(&unit).is_err());
            recovered += usize::from(decoder.decode_yuv420(&units[0]).is_ok());
        }
        eprintln!(
            "corrupted P: failed={failed}/400 recovered={recovered}/400 stats={:?}",
            decoder.stats
        );
        assert_eq!(recovered, 400);
    }

    // T5: pictures past the size limits are refused before a session exists.
    #[test]
    fn oversized_pictures_are_refused_before_a_session_is_created() {
        let _serial = serial();
        for name in ["side-8208x16", "area-8192x4368"] {
            let mut decoder = decoder();
            let error = decoder
                .decode_yuv420(&read(&format!("{name}.h264")))
                .unwrap_err();
            assert!(
                error.to_string().contains("outside the limits"),
                "{name}: {error}"
            );
            assert_eq!(
                (decoder.stats.sessions, decoder.stats.decodes),
                (0, 0),
                "{name}"
            );
        }
    }

    fn footprint() -> u64 {
        // SAFETY: rusage_info_v2 is plain integers, for which all zero bytes are valid.
        let mut info: libc::rusage_info_v2 = unsafe { core::mem::zeroed() };
        // SAFETY: `info` is a rusage_info_v2, the flavor asked for.
        let status = unsafe {
            libc::proc_pid_rusage(
                libc::getpid(),
                libc::RUSAGE_INFO_V2,
                (&mut info as *mut libc::rusage_info_v2).cast(),
            )
        };
        assert_eq!(status, 0);
        info.ri_phys_footprint
    }

    // T6: creating and dropping sessions does not grow the process, and no callback arrives
    // for a dropped session.
    #[test]
    fn sessions_are_released_and_never_call_back_after_drop() {
        let _serial = serial();
        let units = access_units(&read("avc420-pc.h264"));
        let callbacks = CALLBACKS.load(std::sync::atomic::Ordering::Relaxed);
        let mut delivered = 0;
        // Warm up once so lazily loaded frameworks are not counted.
        for _ in 0..20 {
            let mut decoder = decoder();
            decoder.decode_yuv420(&units[0]).unwrap();
            delivered += decoder.stats.callbacks;
        }
        let before = footprint();
        for _ in 0..600 {
            let mut decoder = decoder();
            decoder.decode_yuv420(&units[0]).unwrap();
            decoder.decode_yuv420(&units[1]).unwrap();
            delivered += decoder.stats.callbacks;
        }
        let growth = footprint().saturating_sub(before);
        eprintln!("footprint growth after 600 sessions: {} KiB", growth / 1024);
        assert!(growth <= 32 << 20, "{growth}");
        assert_eq!(
            CALLBACKS.load(std::sync::atomic::Ordering::Relaxed) - callbacks,
            delivered
        );
    }

    // T7: a session past the connection's budget is refused until an earlier one is dropped.
    #[test]
    fn the_connection_pixel_budget_is_returned_when_a_session_ends() {
        let _serial = serial();
        let units = access_units(&read("avc420-pc.h264"));
        let budget = PixelBudget::new(u64::from(WIDTH) * u64::from(HEIGHT) * 3 / 2);
        let mut first = VtDecoder::new(budget.clone(), probe_once);
        let mut second = VtDecoder::new(budget.clone(), probe_once);
        first.decode_yuv420(&units[0]).unwrap();
        let error = second.decode_yuv420(&units[0]).unwrap_err();
        assert!(error.to_string().contains("budget"), "{error}");
        assert_eq!(second.stats.sessions, 0);
        drop(first);
        second.decode_yuv420(&units[0]).unwrap();
        // reset returns the pixels as well.
        second.reset();
        let mut third = VtDecoder::new(budget, probe_once);
        third.decode_yuv420(&units[0]).unwrap();
    }

    struct Handler;
    impl GraphicsPipelineHandler for Handler {}

    fn advertised(decoder: VtDecoder) -> Vec<u32> {
        let mut client = GraphicsPipelineClient::new(Box::new(Handler), Some(Box::new(decoder)));
        let messages = client.start(1).unwrap();
        assert_eq!(messages.len(), 1);
        match decode::<GfxPdu>(&encode_vec(messages[0].as_ref()).unwrap()).unwrap() {
            GfxPdu::CapabilitiesAdvertise(pdu) => pdu.0.iter().map(|set| set.version.0).collect(),
            other => panic!("{other:?}"),
        }
    }

    /// The probe stream cut inside its IDR slice data, so VideoToolbox itself refuses it.
    fn broken_probe_stream() -> Vec<u8> {
        let stream = probe_stream();
        stream[..stream.len() - 12].to_vec()
    }

    fn broken_probe() -> bool {
        probe(&broken_probe_stream())
    }

    fn probe_stream() -> &'static [u8] {
        super::vt::PROBE_STREAM
    }

    // T8: AVC is advertised only when the probe picture decodes.
    #[test]
    fn avc_is_advertised_only_when_the_probe_decodes() {
        let _serial = serial();
        assert!(probe(probe_stream()));
        assert!(!broken_probe());
        let mut decoder = decoder();
        let error = decoder.decode_yuv420(&broken_probe_stream()).unwrap_err();
        assert!(
            error.to_string().contains("decode status=0 callback=-"),
            "{error}"
        );
        let ready = advertised(VtDecoder::new(PixelBudget::new(u64::MAX), probe_once));
        assert_eq!(ready.first(), Some(&0xA0701), "{ready:x?}");
        assert!(ready.contains(&0x80004));
        let unavailable = advertised(VtDecoder::new(PixelBudget::new(u64::MAX), broken_probe));
        assert_eq!(unavailable, [0x80004]);
    }

    // retained-h264-sample-buffer: a large access unit's copy kept its capacity for the
    // decoder's life whether it failed to parse, waited for an IDR picture or decoded.
    #[test]
    fn a_large_access_unit_leaves_no_large_copy_behind() {
        const KEPT: usize = 16 * 1024;
        let _serial = serial();
        let filler = vec![0x55; 1 << 20];
        let mut decoder = decoder();
        // An IDR slice, then a NAL unit type the parser rejects after copying the slice.
        let failing = [
            &[0, 0, 0, 1, 0x65, 0xb8][..],
            &filler,
            &[0, 0, 0, 1, 0x74, 0x80],
        ]
        .concat();
        assert!(decoder.decode_yuv420(&failing).is_err());
        assert!(
            decoder.sample_capacity() <= KEPT,
            "{}",
            decoder.sample_capacity()
        );
        // A predicted slice before any IDR picture.
        let waiting = [&[0, 0, 0, 1, 0x41, 0x9a][..], &filler].concat();
        assert!(decoder.decode_yuv420(&waiting).is_err());
        assert_eq!(decoder.stats.idr_waits, 1);
        assert!(
            decoder.sample_capacity() <= KEPT,
            "{}",
            decoder.sample_capacity()
        );
        // A picture that decodes, carrying a 1 MiB user data SEI after its delimiter.
        let size = 16 + filler.len();
        let mut sei = vec![0, 0, 0, 1, 0x06, 0x05];
        sei.extend(std::iter::repeat_n(0xff, size / 255));
        sei.push((size % 255) as u8);
        sei.extend([0x11; 16]);
        sei.extend(&filler);
        sei.push(0x80);
        let first = access_units(&read("avc420-pc.h264")).swap_remove(0);
        let unit = [&first[..6], &sei, &first[6..]].concat();
        let picture = decoder.decode_yuv420(&unit).unwrap();
        assert_eq!(picture_hash(&picture), reference_hashes("avc420-pc")[0]);
        assert!(
            decoder.sample_capacity() <= KEPT,
            "{}",
            decoder.sample_capacity()
        );
        decoder.reset();
        assert!(
            decoder.sample_capacity() <= KEPT,
            "{}",
            decoder.sample_capacity()
        );
    }
}

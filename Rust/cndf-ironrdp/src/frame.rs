use crate::{lock, CNDFIronRect, Connection};
use ironrdp_client::rdp::DesktopUpdate;
use ironrdp_pdu::desktop_framebuffer::{desktop_pixel_count, DesktopFramebufferError};
use std::time::{Duration, Instant};

// The 0xFFRRGGBB words are handed to the host as BGRA bytes, which holds on little-endian only.
#[cfg(not(target_endian = "little"))]
compile_error!("the frame hands its pixel words to the host as BGRA bytes");

/// How long a backlog may hold back a completed frame.
const BATCH: Duration = Duration::from_millis(16);

#[derive(Default)]
pub(super) struct Frame {
    /// Opaque 0xFFRRGGBB words, which are BGRA bytes in memory.
    pixels: Vec<u32>,
    width: u32,
    height: u32,
    dirty: Option<CNDFIronRect>,
    sequence: u64,
    /// When the oldest change not yet published was composed.
    since: Option<Instant>,
    /// Whether the server data composed since the last publish ended a frame.
    complete: bool,
}

impl Frame {
    pub fn changes_size(&self, update: &DesktopUpdate) -> bool {
        self.width != u32::from(update.width().get())
            || self.height != u32::from(update.height().get())
    }

    pub fn compose(&mut self, update: DesktopUpdate) -> Result<u64, DesktopFramebufferError> {
        let width = u32::from(update.width().get());
        let height = u32::from(update.height().get());
        let len = desktop_pixel_count(width, height)? as usize;
        self.complete |= update.ends_frame();
        self.since.get_or_insert_with(Instant::now);
        let region = update.region();
        let dirty = CNDFIronRect {
            x: region.left.into(),
            y: region.top.into(),
            width: u32::from(region.right - region.left) + 1,
            height: u32::from(region.bottom - region.top) + 1,
        };
        if dirty.x == 0 && dirty.y == 0 && dirty.width == width && dirty.height == height {
            // A full update's packed words already carry the alpha, so they become the frame.
            let (buffer, ..) = update.into_parts();
            debug_assert_eq!(buffer.len(), len);
            debug_assert!(buffer.first().is_none_or(|pixel| pixel >> 24 == 0xff));
            self.pixels = buffer;
            self.width = width;
            self.height = height;
            self.dirty = Some(dirty);
            return Ok(len as u64 * 4);
        }
        if self.changes_size(&update) {
            return Ok(0);
        }
        for (row, source) in update
            .buffer()
            .chunks_exact(dirty.width as usize)
            .enumerate()
        {
            let offset = (dirty.y as usize + row) * width as usize + dirty.x as usize;
            let destination = &mut self.pixels[offset..offset + source.len()];
            for (pixel, rgb) in destination.iter_mut().zip(source) {
                *pixel = rgb | 0xff00_0000;
            }
        }
        self.dirty = Some(self.dirty.map_or(dirty, |other| {
            let x = other.x.min(dirty.x);
            let y = other.y.min(dirty.y);
            CNDFIronRect {
                x,
                y,
                width: (other.x + other.width).max(dirty.x + dirty.width) - x,
                height: (other.y + other.height).max(dirty.y + dirty.height) - y,
            }
        }));
        Ok(update.buffer().len() as u64 * 4)
    }

    /// Whether the composed changes should be published now: once the server data ended a
    /// frame, and with a backlog only after the oldest unpublished change waited for `BATCH`.
    pub fn ready(&self, backlog: bool) -> bool {
        self.complete && (!backlog || self.since.is_some_and(|since| since.elapsed() >= BATCH))
    }

    pub fn publish(&mut self, connection: &Connection, full: bool) {
        self.since = None;
        self.complete = false;
        let dirty = self.dirty.take();
        let dirty = if full && !self.pixels.is_empty() {
            Some(CNDFIronRect {
                x: 0,
                y: 0,
                width: self.width,
                height: self.height,
            })
        } else {
            dirty
        };
        let Some(dirty) = dirty else { return };
        connection.callbacks.invoke(|table| {
            if let Some(callback) = table.frame {
                {
                    let mut statistics = lock(&connection.statistics);
                    statistics.frames_delivered += 1;
                    statistics.frame_bytes_delivered += self.pixels.len() as u64 * 4;
                }
                self.sequence += 1;
                callback(
                    connection.generation,
                    self.pixels.as_ptr().cast::<u8>(),
                    self.width,
                    self.height,
                    self.width * 4,
                    dirty,
                    self.sequence,
                    table.context,
                );
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp_pdu::geometry::InclusiveRectangle;
    use std::num::NonZeroU16;

    fn update(width: u16, x: u16, pixels: Vec<u32>) -> DesktopUpdate {
        DesktopUpdate::new(
            pixels.clone(),
            NonZeroU16::new(width).unwrap(),
            NonZeroU16::new(1).unwrap(),
            InclusiveRectangle {
                left: x,
                right: x + pixels.len() as u16 - 1,
                top: 0,
                bottom: 0,
            },
        )
        .unwrap()
    }

    // Prevent a regression from making the test allocate the oversized buffer.
    // Count only allocations of that exact size, leaving all other tests alone.
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::sync::atomic::{AtomicUsize, Ordering};

    const SERVER_EDGE: u16 = 32_766;
    const OVERSIZED_BYTES: usize = SERVER_EDGE as usize * SERVER_EDGE as usize * 4;
    static OVERSIZED_ATTEMPTS: AtomicUsize = AtomicUsize::new(0);

    struct FramebufferTestAllocator;

    #[global_allocator]
    static TEST_ALLOCATOR: FramebufferTestAllocator = FramebufferTestAllocator;

    unsafe impl GlobalAlloc for FramebufferTestAllocator {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            if layout.size() == OVERSIZED_BYTES {
                OVERSIZED_ATTEMPTS.fetch_add(1, Ordering::Relaxed);
                return std::ptr::null_mut();
            }
            System.alloc(layout)
        }

        unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
            System.dealloc(ptr, layout);
        }
    }

    #[test]
    fn rejects_oversized_server_desktop_before_framebuffer_allocation() {
        use crate::errors;
        use crate::CNDFIronStage::CNDF_IRON_STAGE_CAPABILITIES;
        use ironrdp_connector::{ConnectorError, ConnectorErrorKind};
        use ironrdp_session::image::DecodedImage;

        let error = DecodedImage::try_new_desktop(SERVER_EDGE, SERVER_EDGE).unwrap_err();
        let error = ConnectorError::new("prepare desktop framebuffer", ConnectorErrorKind::General)
            .with_source(error);
        assert_eq!(
            errors::classify(&error, false),
            errors::framebuffer_failure(
                DesktopFramebufferError::Dimensions,
                CNDF_IRON_STAGE_CAPABILITIES,
            )
        );

        let size = NonZeroU16::new(SERVER_EDGE).unwrap();
        let update = DesktopUpdate::new(
            vec![0],
            size,
            size,
            InclusiveRectangle {
                left: 0,
                right: 0,
                top: 0,
                bottom: 0,
            },
        )
        .unwrap();
        let mut frame = Frame::default();
        assert_eq!(
            frame.compose(update),
            Err(DesktopFramebufferError::Dimensions)
        );
        assert_eq!(frame.pixels.capacity(), 0);
        assert_eq!(OVERSIZED_ATTEMPTS.load(Ordering::Relaxed), 0);
    }

    fn bytes(pixels: &[u32]) -> Vec<u8> {
        pixels.iter().flat_map(|pixel| pixel.to_le_bytes()).collect()
    }

    #[test]
    fn full_update_becomes_the_frame_without_copy() {
        let mut frame = Frame::default();
        let update = update(2, 0, vec![0xff112233, 0xffaabbcc]);
        let pointer = update.buffer().as_ptr();
        assert_eq!(frame.compose(update), Ok(8));
        assert_eq!(frame.pixels.as_ptr(), pointer);
    }

    #[test]
    fn full_update_frame_is_opaque_bgra() {
        let mut frame = Frame::default();
        assert_eq!(frame.compose(update(1, 0, vec![0xff112233])), Ok(4));
        assert_eq!(bytes(&frame.pixels), [0x33, 0x22, 0x11, 0xff]);
    }

    #[test]
    fn partial_update_after_adoption_keeps_other_pixels() {
        let mut frame = Frame::default();
        assert_eq!(
            frame.compose(update(2, 0, vec![0xff112233, 0xffaabbcc])),
            Ok(8)
        );
        frame.dirty = None;
        assert_eq!(frame.compose(update(2, 1, vec![0x00123456])), Ok(4));
        assert_eq!(
            bytes(&frame.pixels),
            [0x33, 0x22, 0x11, 255, 0x56, 0x34, 0x12, 255]
        );
        assert_eq!(frame.dirty.unwrap().x, 1);
        assert_eq!(frame.dirty.unwrap().width, 1);
    }

    #[test]
    fn new_extent_requires_full_update() {
        let mut frame = Frame::default();
        assert_eq!(frame.compose(update(2, 0, vec![0xff00_0000; 2])), Ok(8));
        frame.dirty = None;
        assert_eq!(frame.compose(update(3, 1, vec![0xff00_0000])), Ok(0));
        assert_eq!(frame.width, 2);
        assert_eq!(frame.pixels.len(), 2);
        assert!(frame.dirty.is_none());
        assert_eq!(frame.compose(update(3, 0, vec![0xff00_0000; 3])), Ok(12));
        assert_eq!(frame.width, 3);
        assert_eq!(bytes(&frame.pixels), [0, 0, 0, 255].repeat(3));
    }

    fn marked(update: DesktopUpdate) -> DesktopUpdate {
        update.with_frame_end()
    }

    #[test]
    fn frame_is_ready_only_at_frame_end() {
        let mut frame = Frame::default();
        frame.compose(update(3, 0, vec![0xff00_0000; 3])).unwrap();
        frame.compose(update(3, 1, vec![0xff00_0000])).unwrap();
        let first = frame.ready(false);
        frame.compose(update(3, 2, vec![0xff00_0000])).unwrap();
        let second = frame.ready(false);
        frame.compose(marked(update(3, 0, vec![0xff00_0000]))).unwrap();
        assert_eq!((first, second, frame.ready(false)), (false, false, true));
    }

    #[test]
    fn ignored_update_still_ends_the_frame() {
        let mut frame = Frame::default();
        frame.compose(update(2, 0, vec![0xff00_0000; 2])).unwrap();
        assert_eq!(frame.compose(marked(update(3, 1, vec![0]))), Ok(0));
        assert!(frame.ready(false));
    }

    #[test]
    fn stale_publish_time_does_not_split_a_frame() {
        // A frame just published has neither a pending change nor an end.
        let mut frame = Frame::default();
        std::thread::sleep(Duration::from_millis(20));
        frame.compose(update(2, 0, vec![0xff00_0000; 2])).unwrap();
        assert!(!frame.ready(true));
        assert!(!frame.ready(false));
    }

    #[test]
    fn backlog_coalesces_until_batch_limit() {
        let mut frame = Frame::default();
        frame.compose(marked(update(2, 0, vec![0xff00_0000; 2]))).unwrap();
        assert!(!frame.ready(true));
        assert!(frame.ready(false));
        std::thread::sleep(Duration::from_millis(20));
        assert!(frame.ready(true));
    }
}

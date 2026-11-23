use crate::{lock, CNDFIronRect, Connection};
use ironrdp_client::rdp::DesktopUpdate;
use ironrdp_pdu::desktop_framebuffer::{desktop_pixel_count, DesktopFramebufferError};
use std::time::{Duration, Instant};

// The 0xFFRRGGBB words are handed to the host as BGRA bytes, which holds on little-endian only.
#[cfg(not(target_endian = "little"))]
compile_error!("the frame hands its pixel words to the host as BGRA bytes");

/// How long a completed frame may wait to be merged with the next queued frame end.
const BATCH: Duration = Duration::from_millis(16);

/// What the pixels hold beyond what was last published.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum State {
    /// Nothing unpublished.
    #[default]
    Clean,
    /// Tiles of a frame whose end has not been composed yet.
    Composing,
    /// A whole frame, not published yet.
    Complete,
}

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
    state: State,
    /// A redelivery asked for while a frame was composing: the next publish is full.
    redeliver: bool,
}

impl Frame {
    pub fn changes_size(&self, update: &DesktopUpdate) -> bool {
        self.width != u32::from(update.width().get())
            || self.height != u32::from(update.height().get())
    }

    /// Drops an unfinished frame of the old size; a new size starts from a full update.
    pub fn resize(&mut self) {
        if self.state == State::Composing {
            *self = Frame {
                sequence: self.sequence,
                redeliver: self.redeliver,
                ..Frame::default()
            };
        }
    }

    pub fn compose(
        &mut self,
        update: DesktopUpdate,
        now: Instant,
    ) -> Result<u64, DesktopFramebufferError> {
        let width = u32::from(update.width().get());
        let height = u32::from(update.height().get());
        let len = desktop_pixel_count(width, height)? as usize;
        let ends = update.ends_frame();
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
            self.composed(ends, now);
            return Ok(len as u64 * 4);
        }
        if self.changes_size(&update) {
            // Without a frame of its size the tile, and its end, apply to nothing.
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
        self.composed(ends, now);
        Ok(update.buffer().len() as u64 * 4)
    }

    fn composed(&mut self, ends: bool, now: Instant) {
        self.since.get_or_insert(now);
        self.state = if ends {
            State::Complete
        } else {
            State::Composing
        };
    }

    /// Whether a completed frame should be published now rather than merged with the next
    /// queued update, which only a frame end of the same size within `BATCH` of the oldest
    /// unpublished change may be.
    pub fn ready(&self, merges: bool, now: Instant) -> bool {
        self.state == State::Complete
            && !(merges && self.since.is_some_and(|since| now - since < BATCH))
    }

    /// Republishes a published frame in full now; an unfinished one is published in full
    /// once complete.
    pub fn redeliver(&mut self, connection: &Connection) {
        if self.state == State::Composing || self.pixels.is_empty() {
            self.redeliver = true;
        } else {
            self.publish(connection, true);
        }
    }

    pub fn publish(&mut self, connection: &Connection, full: bool) {
        self.since = None;
        self.state = State::Clean;
        let full = full || std::mem::take(&mut self.redeliver);
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
            frame.compose(update, Instant::now()),
            Err(DesktopFramebufferError::Dimensions)
        );
        assert_eq!(frame.pixels.capacity(), 0);
        assert_eq!(OVERSIZED_ATTEMPTS.load(Ordering::Relaxed), 0);
    }

    fn bytes(pixels: &[u32]) -> Vec<u8> {
        pixels.iter().flat_map(|pixel| pixel.to_le_bytes()).collect()
    }

    fn at(ms: u64) -> Instant {
        static BASE: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
        *BASE.get_or_init(Instant::now) + Duration::from_millis(ms)
    }

    /// What `publish` leaves, without a connection.
    fn published(frame: &mut Frame) {
        frame.dirty = None;
        frame.since = None;
        frame.state = State::Clean;
    }

    #[test]
    fn full_update_becomes_the_frame_without_copy() {
        let mut frame = Frame::default();
        let update = update(2, 0, vec![0xff112233, 0xffaabbcc]);
        let pointer = update.buffer().as_ptr();
        assert_eq!(frame.compose(update, at(0)), Ok(8));
        assert_eq!(frame.pixels.as_ptr(), pointer);
    }

    #[test]
    fn full_update_frame_is_opaque_bgra() {
        let mut frame = Frame::default();
        assert_eq!(frame.compose(update(1, 0, vec![0xff112233]), at(0)), Ok(4));
        assert_eq!(bytes(&frame.pixels), [0x33, 0x22, 0x11, 0xff]);
    }

    #[test]
    fn partial_update_after_adoption_keeps_other_pixels() {
        let mut frame = Frame::default();
        assert_eq!(
            frame.compose(update(2, 0, vec![0xff112233, 0xffaabbcc]), at(0)),
            Ok(8)
        );
        published(&mut frame);
        assert_eq!(frame.compose(update(2, 1, vec![0x00123456]), at(0)), Ok(4));
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
        assert_eq!(frame.compose(update(2, 0, vec![0xff00_0000; 2]), at(0)), Ok(8));
        published(&mut frame);
        assert_eq!(frame.compose(update(3, 1, vec![0xff00_0000]), at(0)), Ok(0));
        assert_eq!(frame.width, 2);
        assert_eq!(frame.pixels.len(), 2);
        assert!(frame.dirty.is_none());
        assert_eq!(frame.compose(update(3, 0, vec![0xff00_0000; 3]), at(0)), Ok(12));
        assert_eq!(frame.width, 3);
        assert_eq!(bytes(&frame.pixels), [0, 0, 0, 255].repeat(3));
    }

    fn marked(update: DesktopUpdate) -> DesktopUpdate {
        update.with_frame_end()
    }

    #[test]
    fn frame_is_ready_only_at_frame_end() {
        let mut frame = Frame::default();
        frame.compose(update(3, 0, vec![0xff00_0000; 3]), at(0)).unwrap();
        frame.compose(update(3, 1, vec![0xff00_0000]), at(0)).unwrap();
        let first = frame.ready(false, at(0));
        frame.compose(update(3, 2, vec![0xff00_0000]), at(0)).unwrap();
        let second = frame.ready(false, at(0));
        frame.compose(marked(update(3, 0, vec![0xff00_0000])), at(0)).unwrap();
        assert_eq!((first, second, frame.ready(false, at(0))), (false, false, true));
    }

    // Design frame-boundary: the end of an update dropped for its size completes no frame.
    #[test]
    fn ignored_update_does_not_end_the_frame() {
        let mut frame = Frame::default();
        frame.compose(update(2, 0, vec![0xff00_0000; 2]), at(0)).unwrap();
        assert_eq!(frame.compose(marked(update(3, 1, vec![0])), at(0)), Ok(0));
        assert!(!frame.ready(false, at(0)));
        published(&mut frame);
        assert_eq!(frame.compose(marked(update(3, 1, vec![0])), at(0)), Ok(0));
        assert!(!frame.ready(false, at(0)));
        assert_eq!(frame.since, None);
    }

    // A frame end keeps no state past its publish: the next frame's first tile is unfinished.
    #[test]
    fn publish_ends_the_completed_state() {
        let mut frame = Frame::default();
        frame.compose(marked(update(2, 0, vec![0xff00_0000; 2])), at(0)).unwrap();
        published(&mut frame);
        frame.compose(update(2, 0, vec![0xff00_0000]), at(1)).unwrap();
        assert!(!frame.ready(false, at(1)));
        assert!(!frame.ready(false, at(100)));
    }

    #[test]
    fn stale_publish_time_does_not_split_a_frame() {
        // A frame just published has neither a pending change nor an end.
        let mut frame = Frame::default();
        frame.compose(update(2, 0, vec![0xff00_0000; 2]), at(20)).unwrap();
        assert!(!frame.ready(true, at(40)));
        assert!(!frame.ready(false, at(40)));
    }

    #[test]
    fn merge_window_is_measured_from_the_oldest_change() {
        let mut frame = Frame::default();
        frame.compose(marked(update(2, 0, vec![0xff00_0000; 2])), at(10)).unwrap();
        frame.compose(marked(update(2, 0, vec![0xff00_0000])), at(20)).unwrap();
        assert!(!frame.ready(true, at(25)));
        assert!(frame.ready(true, at(26)));
        assert!(frame.ready(false, at(11)));
    }
}

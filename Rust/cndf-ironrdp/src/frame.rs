use crate::{lock, CNDFIronRect, Connection};
use ironrdp_client::rdp::DesktopUpdate;
use ironrdp_pdu::desktop_framebuffer::{desktop_pixel_count, DesktopFramebufferError};

#[derive(Default)]
pub(super) struct Frame {
    pixels: Vec<u8>,
    width: u32,
    height: u32,
    dirty: Option<CNDFIronRect>,
    sequence: u64,
}

impl Frame {
    pub fn changes_size(&self, update: &DesktopUpdate) -> bool {
        self.width != u32::from(update.width().get())
            || self.height != u32::from(update.height().get())
    }

    pub fn compose(&mut self, update: &DesktopUpdate) -> Result<u64, DesktopFramebufferError> {
        let width = u32::from(update.width().get());
        let height = u32::from(update.height().get());
        let len = desktop_pixel_count(width, height)? as usize * 4;
        let region = update.region();
        let dirty = CNDFIronRect {
            x: region.left.into(),
            y: region.top.into(),
            width: u32::from(region.right - region.left) + 1,
            height: u32::from(region.bottom - region.top) + 1,
        };
        if self.changes_size(update) {
            if dirty.x != 0 || dirty.y != 0 || dirty.width != width || dirty.height != height {
                return Ok(0);
            }
            self.pixels
                .try_reserve_exact(len.saturating_sub(self.pixels.len()))
                .map_err(|_| DesktopFramebufferError::Allocation)?;
            self.pixels.resize(len, 0);
            self.width = width;
            self.height = height;
        }
        for (row, source) in update
            .buffer()
            .chunks_exact(dirty.width as usize)
            .enumerate()
        {
            let offset = ((dirty.y as usize + row) * width as usize + dirty.x as usize) * 4;
            let destination = &mut self.pixels[offset..offset + source.len() * 4];
            for (pixel, rgb) in destination.chunks_exact_mut(4).zip(source) {
                pixel.copy_from_slice(&(rgb | 0xff00_0000).to_le_bytes());
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

    pub fn publish(&mut self, connection: &Connection, full: bool) {
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
                    statistics.frame_bytes_delivered += self.pixels.len() as u64;
                }
                self.sequence += 1;
                callback(
                    connection.generation,
                    self.pixels.as_ptr(),
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
            frame.compose(&update),
            Err(DesktopFramebufferError::Dimensions)
        );
        assert_eq!(frame.pixels.capacity(), 0);
        assert_eq!(OVERSIZED_ATTEMPTS.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn composes_bgra_and_requires_full_update_on_resize() {
        let mut frame = Frame::default();
        assert_eq!(
            frame.compose(&update(2, 0, vec![0x00112233, 0x00aabbcc])),
            Ok(8)
        );
        frame.dirty = None;
        assert_eq!(frame.compose(&update(2, 1, vec![0x00123456])), Ok(4));
        assert_eq!(frame.pixels, [0x33, 0x22, 0x11, 255, 0x56, 0x34, 0x12, 255]);
        assert_eq!(frame.dirty.unwrap().x, 1);
        assert_eq!(frame.compose(&update(3, 1, vec![0])), Ok(0));
        assert_eq!(frame.width, 2);
        frame.dirty = None;
        assert_eq!(frame.compose(&update(3, 0, vec![0; 3])), Ok(12));
        assert_eq!(frame.width, 3);
        assert_eq!(frame.pixels, [0, 0, 0, 255].repeat(3));
    }
}

use crate::{lock, CNDFIronRect, Connection};
use ironrdp_client::rdp::DesktopUpdate;

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

    pub fn compose(&mut self, update: &DesktopUpdate) -> u64 {
        let width = u32::from(update.width().get());
        let height = u32::from(update.height().get());
        let region = update.region();
        let dirty = CNDFIronRect {
            x: region.left.into(),
            y: region.top.into(),
            width: u32::from(region.right - region.left) + 1,
            height: u32::from(region.bottom - region.top) + 1,
        };
        if self.changes_size(update) {
            if dirty.x != 0 || dirty.y != 0 || dirty.width != width || dirty.height != height {
                return 0;
            }
            self.width = width;
            self.height = height;
            self.pixels.resize(
                (usize::from(update.width().get()) * usize::from(update.height().get())) * 4,
                0,
            );
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
        update.buffer().len() as u64 * 4
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

    #[test]
    fn composes_bgra_and_requires_full_update_on_resize() {
        let mut frame = Frame::default();
        assert_eq!(
            frame.compose(&update(2, 0, vec![0x00112233, 0x00aabbcc])),
            8
        );
        frame.dirty = None;
        assert_eq!(frame.compose(&update(2, 1, vec![0x00123456])), 4);
        assert_eq!(frame.pixels, [0x33, 0x22, 0x11, 255, 0x56, 0x34, 0x12, 255]);
        assert_eq!(frame.dirty.unwrap().x, 1);
        assert_eq!(frame.compose(&update(3, 1, vec![0])), 0);
        assert_eq!(frame.width, 2);
        frame.dirty = None;
        assert_eq!(frame.compose(&update(3, 0, vec![0; 3])), 12);
        assert_eq!(frame.width, 3);
        assert_eq!(frame.pixels, [0, 0, 0, 255].repeat(3));
    }
}

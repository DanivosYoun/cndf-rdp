use std::fmt::Write as _;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};

use ironrdp_egfx::client::CodecEvent;
use tracing::info;

pub(super) const LOG_TARGET: &str = "cndf_rdp_codec";

const CODEC_NAMES: [Option<&str>; 16] = [
    Some("Uncompressed"),
    None,
    None,
    Some("RemoteFX"),
    None,
    None,
    None,
    None,
    Some("ClearCodec"),
    Some("Progressive"),
    Some("Planar"),
    Some("AVC420"),
    Some("Alpha"),
    None,
    Some("AVC444"),
    Some("AVC444v2"),
];

#[derive(Default)]
pub(super) struct Totals {
    pdus: [AtomicU64; CODEC_NAMES.len()],
    lc: [AtomicU64; 3],
    decode_failures: AtomicU64,
    dropped: AtomicU64,
    sealed: AtomicBool,
}

impl Totals {
    pub(super) fn observe(&self, event: CodecEvent) {
        if self.sealed.load(Relaxed) {
            return;
        }
        match event {
            CodecEvent::SurfaceUpdate {
                codec_id,
                surface_id,
                width,
                height,
            } => {
                let index = usize::from(codec_id);
                if let Some(&Some(codec)) = CODEC_NAMES.get(index) {
                    if self.pdus[index].fetch_add(1, Relaxed) == 0 {
                        info!(
                            target: LOG_TARGET,
                            "IronRDP codec first: {codec} surface={surface_id} size={width}x{height}"
                        );
                    }
                }
            }
            CodecEvent::Avc444Lc(lc) => {
                if let Some(count) = self.lc.get(usize::from(lc)) {
                    count.fetch_add(1, Relaxed);
                }
            }
            CodecEvent::Dropped { decode_failed } => {
                self.dropped.fetch_add(1, Relaxed);
                if decode_failed {
                    self.decode_failures.fetch_add(1, Relaxed);
                }
            }
        }
    }

    /// The callback gate serializes summary emission with the generation's end.
    pub(super) fn seal(&self) -> Option<String> {
        if self.sealed.swap(true, Relaxed) {
            return None;
        }
        let mut summary = String::from("IronRDP codec summary:");
        for (name, count) in CODEC_NAMES.into_iter().zip(&self.pdus) {
            let count = count.load(Relaxed);
            if let Some(name) = name.filter(|_| count != 0) {
                let _ = write!(summary, " {name}={count}");
            }
        }
        let [lc0, lc1, lc2] = self.lc.each_ref().map(|count| count.load(Relaxed));
        let failures = self.decode_failures.load(Relaxed);
        let dropped = self.dropped.load(Relaxed);
        let _ = write!(
            summary,
            " avc444_lc=0:{lc0},1:{lc1},2:{lc2} decode_failures={failures} dropped={dropped}"
        );
        Some(summary)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp_egfx::pdu::{Codec1Type, Codec2Type};

    #[test]
    fn summarizes_surface_pdus_lc_and_drops_once() {
        let totals = Totals::default();
        for codec_id in [
            Codec1Type::ClearCodec.into(),
            Codec2Type::RemoteFxProgressive.into(),
            Codec1Type::Avc420.into(),
            Codec1Type::Avc444.into(),
            Codec1Type::Avc444v2.into(),
            Codec1Type::Avc444v2.into(),
        ] {
            totals.observe(CodecEvent::SurfaceUpdate {
                codec_id,
                surface_id: 1,
                width: 1280,
                height: 800,
            });
        }
        for lc in [0, 1, 1, 2] {
            totals.observe(CodecEvent::Avc444Lc(lc));
        }
        totals.observe(CodecEvent::Dropped { decode_failed: true });
        totals.observe(CodecEvent::Dropped { decode_failed: false });
        assert_eq!(
            totals.seal().as_deref(),
            Some(concat!(
                "IronRDP codec summary: ClearCodec=1 Progressive=1 AVC420=1 AVC444=1 AVC444v2=2 ",
                "avc444_lc=0:1,1:2,2:1 decode_failures=1 dropped=2"
            ))
        );
        totals.observe(CodecEvent::Dropped { decode_failed: false });
        assert!(totals.seal().is_none());
    }
}

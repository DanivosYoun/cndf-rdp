# RDP engine harness — test servers and scenarios

Design: CNDF-Docs `2026-11-20/ironrdp/design.md` D7 (H-A harness, H-B servers), D8 C5.

| Dir | Server | Port (run script) |
|---|---|---|
| `b1-ironrdp/` | IronRDP `examples/server` @ `15b4a03ff552`, `--sec hybrid` (TLS + CredSSP) | 33891 (cert A / B), 33892 (chain) |
| `b2-freerdp-shadow/` | FreeRDP 3.33.1 `freerdp-shadow-cli` on Xvfb, NTLM NLA via SAM file, Tk probe window | 33893 |
| (pulled) | xrdp `danielguerra/ubuntu-xrdp` pinned by digest, TLS | 33894 |
| `b4-legacy-tls/` | xrdp 0.9.17 (Ubuntu 22.04, OpenSSL 3.0.2), TLS security layer, one TLS window per container: 1.0 / 1.1 / 1.2+1.3, CBC-SHA ciphers at SECLEVEL 0 | 33895 / 33896 / 33897 |
| `scenarios/` | Harness scenario JSON (cert trust chain, per-server baselines) | |

`Scripts/run-engine-harness.sh all` builds the images, starts the servers on the Linux
Docker host (LAN IP only, label `roster.batch=$HARNESS_BATCH`, no tmpfs), opens one reverse
ssh tunnel to the Mac, builds `RDPEngineHarness` on the Mac, runs the scenarios and removes
everything again (`docker rm -fv`, tunnel PID, Mac work dir, one-time secrets). Results stay
in `$HARNESS_WORK/results`.

Certificate scenarios share one isolated `HOME` (FreeRDP's own known_hosts lives there) and
one harness trust suite, and B1 is restarted between them to swap the certificate behind the
same host:port:

1. `cert-1-new-same` — cert A: new (accepted, stored), then same (no callback, no prompt);
   chain server: new, then same.
2. `cert-2-changed` — cert B behind the same port: changed -> prompt -> approve -> connects.
3. `cert-3-rejected` — cert A again: changed -> prompt -> deny -> `certificateRejected`.

With `HARNESS_ENGINE=ironrdp` the same certificate scenarios run through IronRDP. IronRDP has
no known_hosts of its own, so a stored certificate reaches the app as a `same` callback (no
prompt) instead of no callback; runs state that with `expectByEngine`. That pass replaces the
FreeRDP-only interop pin with `i3-freerdp-then-ironrdp`: each B1 server is accepted through
FreeRDP first, then IronRDP must see `same` with 0 prompts (design I3).

`trustStringDigests` holds the SHA-256 of each raw trust string (before lowercasing) for a
byte-for-byte engine comparison; `trustStringCertificates` in the result lists the SHA-256 of each certificate inside each
trust string the engine produced, which is what design I3 needs to compare engines.

Scenario steps: `connect`, `waitConnected`, `waitFirstFrame`, `idle`, `tap`,
`inputLatency` (B2 probe: key press -> square colour change), `resize`, `shutdown`.
Passwords are never in JSON: a run names an environment variable (`passwordEnv`).

`interop-b2-autodetect-off` pins a gap found with this harness (2026-11-20): the FreeRDP
3.33.1 client with `networkAutoDetect` off — the app default — fails against the 3.33.1
shadow server during capability exchange (`MCS message channel id == 0`,
`ERRCONNECT_CONNECT_TRANSPORT_FAILED`, classified `networkUnreachable`). With auto-detect on
it connects, so `baseline-b2` turns it on. Windows servers were not tested here.

`Scripts/run-engine-harness.sh legacy-tls` runs B4 only (legacy TLS design, CNDF-Docs
`2026-11-21/ironrdp/legacy-tls-design.md` C5) and cleans up the same way. Scenarios live in
`b4-legacy-tls/scenarios/`: `legacy-tls-freerdp` expects every profile to connect (TLS 1.0/1.1
only through the bridge's automatic TLS ladder), `legacy-tls-ironrdp` expects TLS 1.0/1.1 to
fail with `tlsHandshakeFailed` (rustls has no TLS < 1.2) and TLS 1.2 to connect. The FreeRDP
ladder stage is not in the result JSON; the run copies the session logs to the results and
prints the stage each FreeRDP run reached (`default`, `previous`, `legacy`). xrdp runs without
sesman, so a session ends at xrdp's own login screen: B4 checks the TLS handshake and first
frame, not logon, and there is no NLA. 3DES/RC4-only servers (Windows 2003) cannot be
emulated: the server's OpenSSL 3 build has no such ciphers.

Baseline 2026-11-21 (`b4-legacy-tls/baselines/2026-11-21/`, cndf-rdp `cndf-retina-compatibility-2`,
Mac Studio, macOS 27.0.1):

| Server | FreeRDP | IronRDP |
|---|---|---|
| TLS 1.0 only | connects, first frame; ladder `default -> previous -> legacy` | `tlsHandshakeFailed` 0x49520006 "servers below TLS 1.2 are unsupported" |
| TLS 1.1 only | connects, first frame; ladder `default -> previous -> legacy` | `tlsHandshakeFailed` 0x49520006 (same) |
| TLS 1.2 + 1.3 | connects at `default` | connects, first frame |

The `previous` stage (TLS >= 1.0, SECLEVEL 1) fails against both legacy servers; only the
`legacy` stage (SECLEVEL 0) connects. FreeRDP's first frame takes ~17 s on every profile
against xrdp here (also at `default` on TLS 1.2), IronRDP ~0.55 s; cause not investigated.

### M3 channel checks

Run `HARNESS_BATCH=<batch8> Scripts/run-engine-harness.sh m3-b1` on the Docker host
after integrating the M3 Swift adapter. The optional second argument selects one engine
(`freerdp` or `ironrdp`). B1 starts afresh for each engine. The output directory contains
the client result, the server log and `b1-channels.json` per engine. The server records
static channel names from GCC and the audio bits from Client Info. For the two audio
DVCs it records replies to actual server Create requests. An absent reply is incomplete
evidence. The script diffs the two sets of observations when running both engines.

The [Linux baseline](baselines/2026-11-21-freerdp-linux/m3-b1-channels.json) ran the fork's
unchanged FreeRDP C bridge against FreeRDP 3.33.1 in a Linux container, with WinPR verbose
assertions disabled as in the macOS build. It establishes the observed advertising and
DVC responses for that build. It does not measure macOS playback or Windows behavior.

`HARNESS_BATCH=<batch8> Scripts/run-engine-harness.sh m3-b3` checks clipboard text in both directions and whether the xrdp
session can read a fixture via the redirected Home drive and write a file back. This
mode requires access to `/dev/fuse` and uses a fresh B3 container per engine. Its fixture
accepts only the harness token and provides fixed drive and xclip operations.

The [IronRDP Linux baseline](baselines/2026-11-21-ironrdp-linux/m3-b1-channels.json)
uses the merged branch's unchanged Rust ABI. Both engines advertised the same static
channels and sent the same audio flags in all six cases. With Home enabled and audio
off or remote, FreeRDP accepted the reliable audio DVC and IronRDP declined it. With
local audio, both accepted the reliable channel and only IronRDP accepted the lossy
channel. The B1 probe sends no audio over either DVC. The separate
[IronRDP ABI counter](baselines/2026-11-21-ironrdp-linux/m3-b1-audio-waves.json) recorded
142 waves in each local run and zero in the other modes.

The Mac Studio run matched the Linux channel observations and recorded zero callbacks
after shutdown in all 12 B1 sessions. The longest shutdown took 103.4 ms.
[FreeRDP Mac results](baselines/2026-11-21-freerdp-m3-macos/m3-b1-channels.json) ·
[IronRDP Mac results](baselines/2026-11-21-ironrdp-m3-macos/m3-b1-channels.json).

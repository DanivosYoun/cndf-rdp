# M4 H.264 acceptance harness (K3)

Design: CNDF-Docs `2026-11-21/ironrdp/m4-h264-design.md` A1/A2, implementation chunk K3.
Driver: `Scripts/run-m4-acceptance.sh` (Linux Docker host + Mac Studio, like
`Scripts/run-engine-harness.sh`).

| Case | Server | Size | Codec | Design |
|---|---|---|---|---|
| `b3-1280x720` | B3-GFX: xrdp 0.10.5 + xorgxrdp 0.10.5 with x264 (`b3-xrdp-gfx.Dockerfile`) | 1280×720 | AVC420 | A1 |

The M1 B3 image (`danielguerra/ubuntu-xrdp`, xrdp 0.9.5) has no RDPGFX and Debian 13's xrdp is
built without an H.264 encoder, so A1 uses its own image. Its session runs `animator.py` only.

The B3 server starts fresh and the IronRDP scenario runs five times. B2 is reproducible
from the historical harness revision.

1. connect, first frame, idle 3 s;
2. `cpuWindow` (9 s): presses `a`; the animator shows 97 full-screen colour fills, one every
   82 ms (the h264-result 0.611 s method). Client CPU = `getrusage` user + system over the
   window, no frame tap attached; frames received are counted;
3. `dumpFrame`: attaches the tap, presses `b` (the reference picture), keeps the last frame once
   none arrived for 2 s and writes it as PPM;
4. shutdown.

The driver captures the final server screen with `xwd -root`. The judge verifies
the IronRDP baseline JSON and frame with the tracked `SHA256SUMS` before reading
them. The comparison uses the five B3 autologon acceptance iterations from
`iron-autologon-raw/b3/b3-1280x720/ironrdp/result.json` in CNDF-Docs
(original SHA-256 `0cae95e82734ea33b3967f9502746755652c6f7768ff7ad18553aa4034a5132e`).
The B3-GFX fixture fixes AVC420. The five recorded final frame hashes match the
IronRDP frame retained by `int16-a1-login`, so the baseline stores a single gzip
copy of those PPM bytes.

| Check | Rule |
|---|---|
| `psnr` | PSNR of current and frozen IronRDP final frames ≥ 40 dB |
| `cpu` | Median current IronRDP window CPU ≤ 1.2 × frozen IronRDP median |
| `codec` | Each current session log identifies the requested codec with `H.264 codec=AVC420` for B3 |
| `frames` | At least 97 frames during each current CPU window and 97 decoded pictures in each summary |
| `hardware` | Each current H.264 summary reports `hardware=yes` |
| `failures` | Each current H.264 summary reports `failures=0` |

The judge compares client host identities and validates each frame against the
scenario resolution. A different comparison host or baseline codec/size leaves
the comparison incomplete. The current IronRDP runtime logs H.264 decoding and
summary data. It needs explicit AVC codec logging for real runs to pass this
gate.

When historical FreeRDP data is present, the judge verifies its JSON, frames and
session logs using the archive's `SHA256SUMS`, then reports them as diagnostics.
Exit status is 0 for pass, 3 for incomplete and 1 for failure.
`Scripts/run-m4-acceptance.sh selftest` exercises the offline judge with synthetic
data and checks that a changed frozen frame is rejected.

## FreeRDP baseline 2026-11-23 (`baselines/2026-11-23-freerdp/`)

cndf-rdp `cndf/m4-k3-harness` (base `ca0b565`), Mac Studio macOS 27.0.1, Xcode 27.2, FreeRDP
engine only (IronRDP needs K1). All 15 runs connected, 97 frames in every CPU window, the
final frame identical across the 5 runs of each case.

| Case | FreeRDP window CPU median (ms) | FreeRDP vs screen | Codec count (5 sessions) |
|---|---|---|---|
| b2-1280x800 | 3993 (user ≈ 0.85 s, system ≈ 3.1 s) | 40.18 dB | AVC444v2 495 |
| b2-1104x704 | 4022 | **18.81 dB** (Cr ≈ 18–19 dB both halves) | AVC444v2 495 |
| b3-1280x720 | 768 | 41.62 dB | AVC420 496 |

At 1104×704 FreeRDP's own picture differs from the server screen: chroma is displaced in the
16-pixel columns at every colour-block edge and the last 16 columns (1088–1103) are wrong
throughout; at 1280×800 no pixel differs by more than 40. Server and client are both FreeRDP
3.33.1, so this is between the shadow AVC444v2 encoder and the client (VideoToolbox) decode path,
not IronRDP. A2's "≥ 40 dB vs FreeRDP" at 1104 therefore only shows IronRDP matches FreeRDP.

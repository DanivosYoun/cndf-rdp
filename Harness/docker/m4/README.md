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

The driver captures the final server screen with `xwd -root`. The judge reads the
frozen reference via `M4_FREERDP_BASELINE`. Its full comparison requires the original
frame and log sidecars alongside the JSON. The judge checks:

| Check | Rule | Without K1 |
|---|---|---|
| `psnr` | PSNR(IronRDP last frame, FreeRDP last frame) ≥ 40 dB | not-run |
| `cpu` | median IronRDP window CPU ≤ 1.2 × median FreeRDP | not-run |
| `codec` | FreeRDP `Graphics: summary` counted the expected codec | runs |
| `hardware` | IronRDP log `H.264 decoder: VideoToolbox hardware` and summary `hardware=yes` | not-run |
| `failures` | IronRDP log `H.264 summary … failures=0` | not-run |

Diagnostics (not gating): each engine vs the xwd screen, the xwd screen vs the animator's
reference picture (checks the capture path, must be `inf`), FreeRDP run-to-run PSNR and
left/right-half Y/Cb/Cr PSNR. A warning is printed when FreeRDP itself is below 40 dB against
the screen. Exit status: 0 pass, 3 some check not run, 1 fail.
`judge.py selftest` (`Scripts/run-m4-acceptance.sh selftest`) runs the same readers and rules on
synthetic inputs: independent-encode noise, CPU 1.0×/1.2×/1.3×, right-half chroma shifted 16
columns, size mismatch, software decoder with failures, wrong codec, missing IronRDP, missing K1
log lines, FreeRDP reference off the screen.

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

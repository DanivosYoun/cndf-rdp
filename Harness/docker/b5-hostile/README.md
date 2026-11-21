# B5 — hostile RDP server (server-memory harness)

Design: CNDF-Docs `2026-11-21/ironrdp/server-memory-design.md`, K8 ("app level" item of the
verification section). Local harness only: the server attacks the client that connects to it.

| File | |
|---|---|
| `server/` | `b5-hostile` crate, built inside the IronRDP workspace at the pinned commit `15b4a03` (unpatched) |
| `cargo-lock.patch` | adds only the crate's own entry to the workspace `Cargo.lock` (build stays `--locked`) |
| `Dockerfile` | build + `debian:bookworm-slim` runtime |
| `judge.py` | Linux-side verdict from the harness result JSON |
| `../scenarios/mem-*.json` | one attack each: sizes, path budget, expected outcome |
| `../../../Scripts/run-hostile-harness.sh` | driver (`run`, `compare`, `down`) |

The server accepts TLS without NLA (IronRDP acceptor with `SecurityProtocol::SSL`, no
credentials checked), finishes the connection sequence with `ironrdp-acceptor`, then owns the
stream. Connections are counted once they reach the active phase (port probes do not count).
Connection 1 (warm-up) gets one 64x64 bitmap and idles. Connection 2 gets the bitmap,
after 2 s the attack as raw frames, one more bitmap, and stays open until the client leaves.

| Scenario | Attack | Size | Path budget (D1) | Expected with the fix |
|---|---|---|---|---|
| `mem-fp-mppc` | Fast-Path LargePointer First + MPPC-64K compressed Next, never Last | 128 MiB reassembled (1/8 of P2b) | 16 MiB | connected, warn event from `ironrdp-session/src/fast_path.rs` |
| `mem-pointer` | Large pointers 384x384 at cache indexes 0..511 | 512 pointers (1/2 of P3) | 32 MiB | connected |
| `mem-svc-cliprdr` | one cliprdr FormatDataResponse, 16 000-byte static chunks | 256 MiB (1/4 of P1) | 64 MiB | connected, warn event from `ironrdp-cliprdr/src/lib.rs` |
| `mem-svc-rdpsnd` | one rdpsnd message (static rdpsnd exists next to RDPDR, so `shareHome`) | 256 MiB | 2 MiB | session ends, classified |
| `mem-dvc-fanout` | AUDIO_PLAYBACK_DVC Create x4000, each + DataFirst declaring u32::MAX with 60 000 B | 4000 x 60 000 B | 4 MiB | session ends, classified |

Verdict (`judge.py`): growth = attack-run `physFootprintMaxBytes` - warm-up-run
`physFootprintMaxBytes` (the harness reports only a per-run maximum, so the warm-up run against
the same server stands in for the design's "first 5 s" baseline). PASS needs growth <= path
budget + 64 MiB, the warm-up run connected with a first frame, the expected outcome, and the
`logPattern` in the attack run's session log when one is set. The engine logs IronRDP events as
`event <file>:<line>` only (no message text), so a pattern names the source file of the warning. The harness's own `passed` is not
used for the attack run (it counts the expected session end as a failure).

Run on the Linux Docker host:

```
HARNESS_BATCH=<batch8> Scripts/run-hostile-harness.sh compare <control-tree> <fixed-tree>
```

`compare` builds `rdp-engine-harness` on the Mac from each cndf-rdp tree in one work dir
(FreeRDP once; IronRDP and `.build` again when `Rust/`, `Sources/` or `Package.swift` differ),
waits for `~/xcode-work/.swift.lock`, runs every scenario on IronRDP and passes when every
scenario exceeds its budget on the control tree and passes on the fixed tree. Teardown (also on
error): container (`docker rm -fv`), image, tunnel PID, Mac work dir and harness defaults domain,
one-time password and certificate. Results stay in `$HARNESS_WORK/results/{control,fixed}`.

Not covered here: egfx progressive (design: unit and e2e level only), `clip-loop` (needs the
0027 hooks, K5), the DesktopUpdate queue (K4).

Baseline 2026-11-21 (`baselines/2026-11-21/`, Mac Studio, macOS 27.0.1, IronRDP engine,
`compare` PASS). Control: `cndf-v0296-int-5` (10ab655). Fixed: a local merge of `cndf-mem-k1`
(3d14d4c, patch 0023) and `cndf-mem-k2` (5ec234c, patch 0024) on int-5, not pushed. Growth =
attack-run max footprint - warm-up-run max footprint.

| Scenario | Wire (attack) | Limit | int-5 growth | K1+K2 growth | K1+K2 outcome |
|---|---|---|---|---|---|
| `mem-fp-mppc` | 98 559 B (128 MiB reassembled) | 80 MiB | 138.7 MiB FAIL | 17.7 MiB PASS | connected, post-attack bitmap decoded (2 frames) |
| `mem-pointer` | 18.0 MiB | 96 MiB | 295.4 MiB FAIL | 25.8 MiB PASS | connected, 2 frames, 480 pointer warnings |
| `mem-svc-cliprdr` | 256.4 MiB | 128 MiB | 265.7 MiB FAIL | 4.8 MiB PASS | connected, warn from `ironrdp-cliprdr/src/lib.rs` |
| `mem-svc-rdpsnd` | 256.4 MiB on int-5, 5.2 MiB until the client closed | 66 MiB | 265.5 MiB FAIL | 3.0 MiB PASS | ended: `StaticVirtualChannel::process` decode error |
| `mem-dvc-fanout` | 229.4 MiB on int-5, 6.0 MiB until the client closed | 68 MiB | 260.4 MiB FAIL | 3.0 MiB PASS | ended: `DynamicVirtualChannel::process` decode error |

The int-5 client stayed connected through every attack (it holds the data). The fast-path log
check is not discriminating on its own: int-5 also warns from `fast_path.rs` (another line) when
the post-attack Single bitmap arrives inside the unfinished sequence; the budget is the verdict.
A session end reaches the app as disconnect `error` with the generic "decode error" text: the
limit's own message is not carried through `decode_err!`.

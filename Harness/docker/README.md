# RDP engine harness — test servers and scenarios

Design: CNDF-Docs `2026-11-20/ironrdp/design.md` D7 (H-A harness, H-B servers), D8 C5.

| Dir | Server | Port (run script) |
|---|---|---|
| `b1-ironrdp/` | IronRDP `examples/server` @ `15b4a03ff552`, `--sec hybrid` (TLS + CredSSP) | 33891 (cert A / B), 33892 (chain) |
| `b2-freerdp-shadow/` | FreeRDP 3.33.1 `freerdp-shadow-cli` on Xvfb, NTLM NLA via SAM file, Tk probe window | 33893 |
| (pulled) | xrdp `danielguerra/ubuntu-xrdp` pinned by digest, TLS | 33894 |
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

`trustStringCertificates` in the result lists the SHA-256 of each certificate inside each
trust string the engine produced, which is what design I3 needs to compare engines.

Scenario steps: `connect`, `waitConnected`, `waitFirstFrame`, `idle`, `tap`,
`inputLatency` (B2 probe: key press -> square colour change), `resize`, `shutdown`.
Passwords are never in JSON: a run names an environment variable (`passwordEnv`).

`interop-b2-autodetect-off` pins a gap found with this harness (2026-11-20): the FreeRDP
3.33.1 client with `networkAutoDetect` off — the app default — fails against the 3.33.1
shadow server during capability exchange (`MCS message channel id == 0`,
`ERRCONNECT_CONNECT_TRANSPORT_FAILED`, classified `networkUnreachable`). With auto-detect on
it connects, so `baseline-b2` turns it on. Windows servers were not tested here.

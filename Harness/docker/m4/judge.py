#!/usr/bin/env python3
"""M4 H.264 acceptance judge (design m4-h264-design A1/A2). Standard library only.

  judge.py evaluate --case NAME --codec AVC420|AVC444v2 \
      --freerdp DIR/RESULT.json [--ironrdp DIR/RESULT.json] [--truth SCREEN.xwd] [--out VERDICT.json]
  judge.py selftest

Inputs are the harness result JSON per engine (cpuWindows, finalFrame) with the PPM frames and
session logs the run copied next to it (one directory per engine), and the server's xwd
capture of the same screen.

Checks (each pass / fail / not-run; the verdict passes only when every check passes):
  psnr      PSNR(IronRDP last frame, FreeRDP last frame) >= 40 dB (RGB, 8 bit)
  cpu       median IronRDP window CPU (user + system) <= 1.2 x median FreeRDP window CPU
  codec     the FreeRDP session log's Graphics summary counted the expected codec (> 0), so
            the comparison is really about that codec
  hardware  IronRDP log: "H.264 decoder: VideoToolbox hardware" and summary hardware=yes
  failures  IronRDP log: H.264 summary failures=0
Diagnostics (not gating): each engine vs the xwd screen, xwd vs the animator's reference
picture, FreeRDP run-to-run PSNR (encoder noise floor), per-half Y/Cb/Cr PSNR so a chroma
error confined to the right half (the design's first falsification point) is visible.
"""
import argparse
import json
import math
import os
import re
import statistics
import struct
import sys
import tempfile

PSNR_MIN_DB = 40.0
CPU_RATIO_MAX = 1.2


# ---- images ---------------------------------------------------------------------------

class Image:
    def __init__(self, width, height, rgb):
        if len(rgb) != width * height * 3:
            raise ValueError(f"{width}x{height} needs {width * height * 3} bytes, got {len(rgb)}")
        self.width, self.height, self.rgb = width, height, bytes(rgb)


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    tokens, pos = [], 0
    while len(tokens) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        tokens.append(data[pos:end])
        pos = end
    if tokens[0] != b"P6" or tokens[3] != b"255":
        raise ValueError(f"{path}: not an 8-bit P6 PPM")
    width, height = int(tokens[1]), int(tokens[2])
    pos += 1  # single whitespace after maxval
    return Image(width, height, data[pos:pos + width * height * 3])


def write_ppm(path, image):
    with open(path, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (image.width, image.height) + image.rgb)


XWD_FIELDS = ("header_size file_version pixmap_format pixmap_depth width height xoffset byte_order "
              "bitmap_unit bitmap_bit_order bitmap_pad bits_per_pixel bytes_per_line visual_class "
              "red_mask green_mask blue_mask bits_per_rgb colormap_entries ncolors window_width "
              "window_height window_x window_y window_bdrwidth").split()


def read_xwd(path):
    """TrueColor ZPixmap XWD at 24/32 bits per pixel (what xwd -root gives on Xvfb/Xorg)."""
    with open(path, "rb") as f:
        data = f.read()
    h = dict(zip(XWD_FIELDS, struct.unpack(">25I", data[:100])))
    if h["file_version"] != 7 or h["pixmap_format"] != 2 or h["bits_per_pixel"] not in (24, 32):
        raise ValueError(f"{path}: unsupported XWD {h}")
    pos = h["header_size"] + h["ncolors"] * 12
    width, height, bpl, bpp = h["width"], h["height"], h["bytes_per_line"], h["bits_per_pixel"] // 8
    order = "little" if h["byte_order"] == 0 else "big"
    masks = [h["red_mask"], h["green_mask"], h["blue_mask"]]
    shifts = [(m & -m).bit_length() - 1 for m in masks]
    out = bytearray(width * height * 3)
    o = 0
    for y in range(height):
        row = data[pos + y * bpl:pos + y * bpl + width * bpp]
        for x in range(0, width * bpp, bpp):
            v = int.from_bytes(row[x:x + bpp], order)
            out[o] = (v & masks[0]) >> shifts[0]
            out[o + 1] = (v & masks[1]) >> shifts[1]
            out[o + 2] = (v & masks[2]) >> shifts[2]
            o += 3
    return Image(width, height, out)


def write_xwd(path, image):
    """Little-endian 32 bpp XWD like Xvfb's; only the self-test needs it."""
    name = b"m4\0"
    values = dict(header_size=100 + len(name), file_version=7, pixmap_format=2, pixmap_depth=24,
                  width=image.width, height=image.height, xoffset=0, byte_order=0, bitmap_unit=32,
                  bitmap_bit_order=0, bitmap_pad=32, bits_per_pixel=32, bytes_per_line=image.width * 4,
                  visual_class=4, red_mask=0xFF0000, green_mask=0xFF00, blue_mask=0xFF, bits_per_rgb=8,
                  colormap_entries=256, ncolors=0, window_width=image.width, window_height=image.height,
                  window_x=0, window_y=0, window_bdrwidth=0)
    pixels = bytearray()
    rgb = image.rgb
    for i in range(0, len(rgb), 3):
        pixels += bytes((rgb[i + 2], rgb[i + 1], rgb[i], 0))
    with open(path, "wb") as f:
        f.write(struct.pack(">25I", *[values[k] for k in XWD_FIELDS]) + name + pixels)


# ---- metrics --------------------------------------------------------------------------

def psnr_bytes(a, b):
    if len(a) != len(b) or not a:
        return None
    sse = sum((x - y) * (x - y) for x, y in zip(a, b))
    return math.inf if sse == 0 else 10 * math.log10(255 * 255 * len(a) / sse)


def psnr(a, b):
    """RGB PSNR in dB; None when the sizes differ (that alone fails the check)."""
    if (a.width, a.height) != (b.width, b.height):
        return None
    return psnr_bytes(a.rgb, b.rgb)


def ycbcr_planes(image, x0, x1):
    """BT.601 full-range Y/Cb/Cr (rounded to 8 bit) of columns [x0, x1)."""
    planes = (bytearray(), bytearray(), bytearray())
    rgb, w = image.rgb, image.width
    for y in range(image.height):
        base = y * w * 3
        for x in range(x0, x1):
            r, g, b = rgb[base + x * 3], rgb[base + x * 3 + 1], rgb[base + x * 3 + 2]
            planes[0].append(min(255, max(0, round(0.299 * r + 0.587 * g + 0.114 * b))))
            planes[1].append(min(255, max(0, round(128 - 0.168736 * r - 0.331264 * g + 0.5 * b))))
            planes[2].append(min(255, max(0, round(128 + 0.5 * r - 0.418688 * g - 0.081312 * b))))
    return planes


def region_psnr(a, b):
    """{left|right: {Y, Cb, Cr}} PSNR, None when the sizes differ."""
    if (a.width, a.height) != (b.width, b.height):
        return None
    half = a.width // 2
    out = {}
    for label, x0, x1 in (("left", 0, half), ("right", half, a.width)):
        pa, pb = ycbcr_planes(a, x0, x1), ycbcr_planes(b, x0, x1)
        out[label] = {name: rounded(psnr_bytes(pa[i], pb[i])) for i, name in enumerate(("Y", "Cb", "Cr"))}
    return out


def rounded(value):
    if value is None:
        return None
    return "inf" if value == math.inf else round(value, 2)


# ---- inputs ---------------------------------------------------------------------------

def load_engine(result_path):
    frames_dir = os.path.dirname(os.path.abspath(result_path))
    with open(result_path) as f:
        result = json.load(f)
    iterations = [it for run in result["runs"] for it in run["iterations"]]
    cpu = [w["userMs"] + w["systemMs"] for it in iterations for w in it.get("cpuWindows", [])[:1]]
    frames = []
    for it in iterations:
        final = it.get("finalFrame")
        if final:
            frames.append((it["iteration"], read_ppm(os.path.join(frames_dir, final["file"]))))
    logs = []
    for run in result["runs"]:
        for it in run["iterations"]:
            path = os.path.join(frames_dir, f"{run['id']}-{it['iteration']}.session.log")
            if os.path.exists(path):
                with open(path, errors="replace") as f:
                    logs.append(f.read())
    return {
        "engine": result.get("engine"),
        "passed": result.get("passed"),
        "iterations": len(iterations),
        "cpuWindowMs": [round(v, 3) for v in cpu],
        "framesInWindow": [w["framesReceived"] for it in iterations for w in it.get("cpuWindows", [])[:1]],
        "frames": frames,
        "logs": logs,
    }


SUMMARY_FREERDP = re.compile(r"Graphics: summary .*?AVC420=(\d+) AVC444=(\d+) AVC444v2=(\d+)")
SUMMARY_IRON = re.compile(r"H\.264 summary pictures=(\d+) failures=(\d+) idr_waits=(\d+) sessions=(\d+) hardware=(\w+)")
DECODER_IRON = re.compile(r"H\.264 decoder: VideoToolbox (hardware|software)")


def freerdp_codec_counts(logs):
    totals = {"AVC420": 0, "AVC444": 0, "AVC444v2": 0}
    seen = 0
    for log in logs:
        for m in SUMMARY_FREERDP.finditer(log):
            seen += 1
            for key, value in zip(totals, m.groups()):
                totals[key] += int(value)
    return totals if seen else None


def ironrdp_h264(logs):
    summaries = [m.groups() for log in logs for m in SUMMARY_IRON.finditer(log)]
    decoders = [m.group(1) for log in logs for m in DECODER_IRON.finditer(log)]
    if not summaries and not decoders:
        return None
    return {
        "pictures": sum(int(s[0]) for s in summaries),
        "failures": sum(int(s[1]) for s in summaries),
        "summaries": len(summaries),
        "summaryHardware": sorted({s[4] for s in summaries}),
        "decoderLines": sorted(set(decoders)),
    }


# ---- verdict --------------------------------------------------------------------------

def check(status, detail):
    return {"status": status, "detail": detail}


def evaluate(case, codec, freerdp, ironrdp, truth=None, reference=None):
    report = {"case": case, "codec": codec, "thresholds": {"psnrMinDb": PSNR_MIN_DB, "cpuRatioMax": CPU_RATIO_MAX}}
    checks = {}
    engines = {"freerdp": freerdp, "ironrdp": ironrdp}
    report["engines"] = {
        name: None if e is None else {k: e[k] for k in ("engine", "passed", "iterations", "cpuWindowMs", "framesInWindow")}
        | {"framesDumped": len(e["frames"])}
        for name, e in engines.items()
    }

    last = {name: (e["frames"][-1][1] if e and e["frames"] else None) for name, e in engines.items()}
    if last["freerdp"] is None:
        checks["psnr"] = check("fail", "no FreeRDP final frame")
    elif last["ironrdp"] is None:
        checks["psnr"] = check("not-run", "no IronRDP final frame")
    else:
        value = psnr(last["ironrdp"], last["freerdp"])
        report["psnrEnginesDb"] = rounded(value)
        report["regionPsnrEngines"] = region_psnr(last["ironrdp"], last["freerdp"])
        if value is None:
            checks["psnr"] = check("fail", f"frame sizes differ: IronRDP {last['ironrdp'].width}x{last['ironrdp'].height}, "
                                           f"FreeRDP {last['freerdp'].width}x{last['freerdp'].height}")
        else:
            checks["psnr"] = check("pass" if value >= PSNR_MIN_DB else "fail", f"{rounded(value)} dB")

    cpu_free = statistics.median(freerdp["cpuWindowMs"]) if freerdp and freerdp["cpuWindowMs"] else None
    cpu_iron = statistics.median(ironrdp["cpuWindowMs"]) if ironrdp and ironrdp["cpuWindowMs"] else None
    report["cpuMedianMs"] = {"freerdp": cpu_free, "ironrdp": cpu_iron}
    if cpu_free is None:
        checks["cpu"] = check("fail", "no FreeRDP cpuWindow")
    elif cpu_iron is None:
        checks["cpu"] = check("not-run", "no IronRDP cpuWindow")
    else:
        ratio = cpu_iron / cpu_free if cpu_free > 0 else math.inf
        report["cpuRatio"] = round(ratio, 3)
        checks["cpu"] = check("pass" if ratio <= CPU_RATIO_MAX else "fail", f"{ratio:.3f}x")

    counts = freerdp_codec_counts(freerdp["logs"]) if freerdp else None
    report["freerdpCodecCounts"] = counts
    if counts is None:
        checks["codec"] = check("fail", "no FreeRDP Graphics summary in the session logs")
    else:
        checks["codec"] = check("pass" if counts.get(codec, 0) > 0 else "fail", f"{codec}={counts.get(codec, 0)}")

    h264 = ironrdp_h264(ironrdp["logs"]) if ironrdp else None
    report["ironrdpH264"] = h264
    if h264 is None:
        reason = "no IronRDP run" if ironrdp is None else "no H.264 decoder/summary lines in the IronRDP logs (needs K1)"
        checks["hardware"] = check("not-run", reason)
        checks["failures"] = check("not-run", reason)
    else:
        hw_ok = h264["decoderLines"] == ["hardware"] and h264["summaryHardware"] == ["yes"]
        checks["hardware"] = check("pass" if hw_ok else "fail",
                                   f"decoder={h264['decoderLines']} summary={h264['summaryHardware']}")
        checks["failures"] = check("pass" if h264["failures"] == 0 else "fail", f"failures={h264['failures']}")

    diagnostics = {}
    if truth is not None:
        for name, image in last.items():
            if image is not None:
                diagnostics[f"{name}VsScreenDb"] = rounded(psnr(image, truth))
                diagnostics[f"{name}VsScreenRegions"] = region_psnr(image, truth)
        if reference is not None:
            diagnostics["screenVsReferenceDb"] = rounded(psnr(truth, reference))
    if freerdp and len(freerdp["frames"]) > 1:
        first = freerdp["frames"][0][1]
        diagnostics["freerdpRunToRunDb"] = [rounded(psnr(first, img)) for _, img in freerdp["frames"][1:]]
    report["diagnostics"] = diagnostics
    # Not gating (the design gates on IronRDP vs FreeRDP): when FreeRDP itself is below the
    # threshold against the server screen, a psnr pass only means IronRDP matches FreeRDP.
    reference_db = diagnostics.get("freerdpVsScreenDb")
    if isinstance(reference_db, (int, float)) and reference_db < PSNR_MIN_DB:
        report["warnings"] = [f"FreeRDP vs server screen {reference_db} dB < {PSNR_MIN_DB} dB: "
                              "the FreeRDP reference itself differs from the screen"]

    report["checks"] = checks
    statuses = {c["status"] for c in checks.values()}
    report["verdict"] = "fail" if "fail" in statuses else ("incomplete" if "not-run" in statuses else "pass")
    return report


# ---- self-test ------------------------------------------------------------------------

def reference_image(width, height):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from animator import reference_ppm  # noqa: E402  (no Tk needed for the pattern)
    data = reference_ppm(width, height)
    header_end = data.index(b"255\n") + 4
    return Image(width, height, data[header_end:])


def perturbed(image, seed, amplitude):
    """Deterministic ±amplitude noise on every byte (stand-in for an independent encode)."""
    state = seed
    out = bytearray(image.rgb)
    for i in range(len(out)):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        out[i] = min(255, max(0, out[i] + (state >> 16) % (2 * amplitude + 1) - amplitude))
    return Image(image.width, image.height, out)


def right_half_chroma_shift(image, shift):
    """Moves each right-half pixel's chroma `shift` columns (wrong V position), keeps luma."""
    w, h, rgb = image.width, image.height, image.rgb
    out = bytearray(rgb)
    y_planes = ycbcr_planes(image, 0, w)
    for y in range(h):
        for x in range(w // 2, w):
            src = y * w + min(w - 1, x + shift)
            yy = y_planes[0][y * w + x]
            cb, cr = y_planes[1][src] - 128, y_planes[2][src] - 128
            r = yy + 1.402 * cr
            g = yy - 0.344136 * cb - 0.714136 * cr
            b = yy + 1.772 * cb
            o = (y * w + x) * 3
            out[o:o + 3] = bytes(min(255, max(0, round(v))) for v in (r, g, b))
    return Image(w, h, out)


def write_case(root, engine, run_id, frames, cpu_ms, log_lines):
    directory = os.path.join(root, engine)
    os.makedirs(directory)
    iterations = []
    for i, (image, cpu) in enumerate(zip(frames, cpu_ms), start=1):
        name = f"{run_id}-{i}.final.ppm"
        write_ppm(os.path.join(directory, name), image)
        with open(os.path.join(directory, f"{run_id}-{i}.session.log"), "w") as f:
            f.write("\n".join(log_lines) + "\n")
        iterations.append({"iteration": i, "cpuWindows": [{"seconds": 9, "userMs": cpu * 0.8, "systemMs": cpu * 0.2,
                                                           "framesReceived": 97}],
                           "finalFrame": {"file": name, "size": [image.width, image.height], "sha256": ""}})
    path = os.path.join(directory, f"{engine}.json")
    with open(path, "w") as f:
        json.dump({"engine": engine, "passed": True, "runs": [{"id": run_id, "iterations": iterations}]}, f)
    return path


def selftest():
    """Synthetic inputs through the same file readers and evaluate(); prints one line per case."""
    width, height = 256, 128
    ref = reference_image(width, height)
    free_log = ["Graphics: summary rdpgfx=10.7 mode=auto AVC420=0 AVC444=0 AVC444v2=97 surfaceCommands:x."]
    iron_ok = ["H.264 decoder: VideoToolbox hardware 256x128 range=full",
               "H.264 summary pictures=97 failures=0 idr_waits=0 sessions=1 hardware=yes"]
    cases = [
        # name, iron frames, iron cpu, iron log, codec, expected verdict, expected failing checks
        ("pass: independent encodes, cpu 1.0x", [perturbed(ref, s, 1) for s in (7, 8, 9)], 100, iron_ok, "AVC444v2", "pass", set()),
        ("pass: cpu exactly 1.2x", [perturbed(ref, s, 1) for s in (7, 8, 9)], 120, iron_ok, "AVC444v2", "pass", set()),
        ("fail: cpu 1.3x", [perturbed(ref, s, 1) for s in (7, 8, 9)], 130, iron_ok, "AVC444v2", "fail", {"cpu"}),
        ("fail: right-half chroma shifted 16", [right_half_chroma_shift(ref, 16)] * 3, 100, iron_ok, "AVC444v2", "fail", {"psnr"}),
        ("fail: frame size differs", [Image(width - 16, height, ref.rgb[:(width - 16) * height * 3])] * 3, 100, iron_ok,
         "AVC444v2", "fail", {"psnr"}),
        ("fail: software decoder, 2 failures", [perturbed(ref, s, 1) for s in (7, 8, 9)], 100,
         ["H.264 decoder: VideoToolbox software 256x128 range=full",
          "H.264 summary pictures=95 failures=2 idr_waits=1 sessions=2 hardware=no"], "AVC444v2", "fail",
         {"hardware", "failures"}),
        ("fail: expected codec not used", [perturbed(ref, s, 1) for s in (7, 8, 9)], 100, iron_ok, "AVC420", "fail", {"codec"}),
        ("incomplete: no IronRDP run", None, None, None, "AVC444v2", "incomplete", set()),
        ("incomplete: IronRDP without K1 log lines", [perturbed(ref, s, 1) for s in (7, 8, 9)], 100, [], "AVC444v2",
         "incomplete", set()),
    ]
    failures = 0
    for name, iron_frames, iron_cpu, iron_log, codec, want, want_failing in cases:
        with tempfile.TemporaryDirectory() as d:
            free = write_case(d, "freerdp", "case", [perturbed(ref, s, 1) for s in (1, 2, 3)], [100, 90, 110], free_log)
            iron = None if iron_frames is None else write_case(d, "ironrdp", "case", iron_frames,
                                                                [iron_cpu] * 3, iron_log)
            truth_path = os.path.join(d, "screen.xwd")
            write_xwd(truth_path, ref)
            truth = read_xwd(truth_path)
            report = evaluate(name, codec, load_engine(free), None if iron is None else load_engine(iron),
                              truth=truth, reference=ref)
        failing = {k for k, c in report["checks"].items() if c["status"] == "fail"}
        ok = (report["verdict"] == want and failing == want_failing and "warnings" not in report
              and report["diagnostics"]["screenVsReferenceDb"] == "inf")
        failures += not ok
        extra = ""
        if "regionPsnrEngines" in report and report["regionPsnrEngines"]:
            r = report["regionPsnrEngines"]
            extra = f" left Cb/Cr {r['left']['Cb']}/{r['left']['Cr']} right Cb/Cr {r['right']['Cb']}/{r['right']['Cr']}"
        print(f"{'ok  ' if ok else 'FAIL'} {name}: verdict={report['verdict']} failing={sorted(failing)} "
              f"psnr={report.get('psnrEnginesDb')} cpuRatio={report.get('cpuRatio')}{extra}")
    # The FreeRDP reference itself off the screen (seen on B2 1104x704): verdict unchanged, warning set.
    with tempfile.TemporaryDirectory() as d:
        shifted = right_half_chroma_shift(ref, 16)
        free = write_case(d, "freerdp", "case", [shifted] * 3, [100] * 3, free_log)
        iron = write_case(d, "ironrdp", "case", [shifted] * 3, [100] * 3, iron_ok)
        truth_path = os.path.join(d, "screen.xwd")
        write_xwd(truth_path, ref)
        report = evaluate("pass + warning: FreeRDP reference off the screen", "AVC444v2", load_engine(free),
                          load_engine(iron), truth=read_xwd(truth_path), reference=ref)
    ok = report["verdict"] == "pass" and len(report.get("warnings", [])) == 1
    failures += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {report['case']}: verdict={report['verdict']} warnings={report.get('warnings')}")
    total = len(cases) + 1
    print(f"selftest: {total - failures}/{total} cases as expected")
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    ev = sub.add_parser("evaluate")
    ev.add_argument("--case", required=True)
    ev.add_argument("--codec", required=True, choices=["AVC420", "AVC444", "AVC444v2"])
    ev.add_argument("--freerdp", required=True)
    ev.add_argument("--ironrdp")
    ev.add_argument("--truth", help="server xwd capture of the final screen")
    ev.add_argument("--out")
    sub.add_parser("selftest")
    args = parser.parse_args()
    if args.command == "selftest":
        return selftest()
    freerdp = load_engine(args.freerdp)
    ironrdp = load_engine(args.ironrdp) if args.ironrdp and os.path.exists(args.ironrdp) else None
    truth = read_xwd(args.truth) if args.truth else None
    reference = reference_image(truth.width, truth.height) if truth else None
    report = evaluate(args.case, args.codec, freerdp, ironrdp, truth=truth, reference=reference)
    text = json.dumps(report, indent=2, ensure_ascii=False)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")
    checks = " ".join(f"{k}={c['status']}({c['detail']})" for k, c in report["checks"].items())
    print(f"{args.case}: verdict={report['verdict']} {checks}")
    for warning in report.get("warnings", []):
        print(f"{args.case}: warning: {warning}")
    return {"pass": 0, "incomplete": 3}.get(report["verdict"], 1)


if __name__ == "__main__":
    sys.exit(main())

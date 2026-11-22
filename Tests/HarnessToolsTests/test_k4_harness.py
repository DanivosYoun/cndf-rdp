#!/usr/bin/env python3
"""Unit tests and dry-run checks for K4 clip-lock harness tools (no Windows connection)."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HARNESS_DIR = os.path.join(REPO_ROOT, "Harness", "windows-i8")
SCENARIOS_LOCK = os.path.join(HARNESS_DIR, "scenarios_lock.py")
RDPCLIP_MEM = os.path.join(HARNESS_DIR, "rdpclip-mem.py")
CAN_LOCK_OFF = os.path.join(HARNESS_DIR, "can-lock-off.py")
I8_PROBE = os.path.join(HARNESS_DIR, "i8probe.ps1")

VALID_OPS = {
    "connect",
    "waitConnected",
    "waitFirstFrame",
    "idle",
    "tap",
    "inputLatency",
    "resize",
    "scroll",
    "clipboardSetRemote",
    "clipboardExpectRemote",
    "clipboardSetLocal",
    "clipboardExpectLocal",
    "driveExpect",
    "audioExpectWaves",
    "clipboardSetLocalFiles",
    "clipboardExpectLocalFiles",
    "clipboardWaitLocalPrefix",
    "keys",
    "sharedKeys",
    "watch",
    "stagingWait",
    "waitDisconnected",
    "reconnect",
    "clipboardSnapshotLocal",
    "shutdown",
}

VALID_STEP_KEYS = {
    "op",
    "timeout",
    "text",
    "minWaves",
    "seconds",
    "width",
    "height",
    "samples",
    "probeX",
    "probeY",
    "scanCode",
    "scrollUnit",
    "scrollDeltas",
    "scrollDeltasX",
    "intervalMs",
    "pointerX",
    "pointerY",
    "paths",
    "count",
    "prefix",
}


def read_text(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def read_json(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def load_module(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(mod)
    return mod


class TestScenariosLock(unittest.TestCase):
    def test_generates_valid_scenarios_with_burst_watch_at_least_6s(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = subprocess.run(
                [sys.executable, SCENARIOS_LOCK, tmp, "/Users/danivosy/src"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)

            expected_files = {
                "gw1-mix20.json",
                "gw1-mixc20.json",
                "gw1-burst60.json",
                "lw6-m2w-recopy.json",
                "lw7-lock-reconnect.json",
                "norm40.json",
            }
            self.assertEqual(set(os.listdir(tmp)), expected_files)

            # Every generated scenario must conform to Scenario.swift ops and keys.
            for fname in expected_files:
                data = read_json(os.path.join(tmp, fname))
                self.assertIn("name", data)
                self.assertEqual(len(data["runs"]), 1)
                for step in data["runs"][0]["steps"]:
                    self.assertIn(step["op"], VALID_OPS, f"unknown op in {fname}: {step}")
                    self.assertTrue(
                        set(step.keys()).issubset(VALID_STEP_KEYS),
                        f"unknown step keys in {fname}: {set(step.keys()) - VALID_STEP_KEYS}",
                    )

            # Burst scenario: 60 trials, every watch >= 6s (fixes trace §3.5 2.4s bug).
            burst = read_json(os.path.join(tmp, "gw1-burst60.json"))
            burst_steps = burst["runs"][0]["steps"]
            watches = [s for s in burst_steps if s["op"] == "watch"]
            snaps = [s for s in burst_steps if s["op"] == "clipboardSnapshotLocal"]
            self.assertEqual(len(watches), 60)
            self.assertEqual(len(snaps), 60)
            self.assertTrue(all(s["seconds"] >= 6.0 for s in watches))

            # G-W1 mix20 / mixc20: 20 trials each, watch >= 6s.
            for mix_name in ("gw1-mix20.json", "gw1-mixc20.json"):
                mix = read_json(os.path.join(tmp, mix_name))
                steps = mix["runs"][0]["steps"]
                self.assertEqual(sum(1 for s in steps if s["op"] == "clipboardSnapshotLocal"), 20)
                self.assertTrue(all(s["seconds"] >= 6.0 for s in steps if s["op"] == "watch"))

            # L-W6: Mac->Windows 1 GiB paste interrupted by Mac re-copy of a different file.
            recopy = read_json(os.path.join(tmp, "lw6-m2w-recopy.json"))
            rsteps = recopy["runs"][0]["steps"]
            file_sets = [s["paths"] for s in rsteps if s["op"] == "clipboardSetLocalFiles"]
            self.assertEqual(len(file_sets), 2)
            self.assertEqual(file_sets[0], ["/Users/danivosy/src/big-m.bin"])
            self.assertEqual(file_sets[1], ["/Users/danivosy/src/multi/mid.bin"])
            self.assertNotEqual(file_sets[0], file_sets[1])
            done_waits = [s for s in rsteps if s["op"] == "clipboardWaitLocalPrefix" and s.get("prefix") == "I8DONE"]
            self.assertEqual(len(done_waits), 1)

    def test_rejects_burst_watch_under_6_seconds(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = subprocess.run(
                [sys.executable, SCENARIOS_LOCK, tmp, "/Users/danivosy/src", "--burst-watch-seconds", "2.4"],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("6.0", proc.stderr)
            self.assertEqual(os.listdir(tmp), [])


class TestRdpclipMem(unittest.TestCase):
    def test_dry_run_does_not_connect_and_prints_query(self):
        proc = subprocess.run(
            [sys.executable, RDPCLIP_MEM, "--dry-run", "--interval", "5", "--count", "3"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("DRY-RUN", proc.stdout)
        self.assertIn("KST", proc.stdout)
        self.assertIn("Get-Process rdpclip", proc.stdout)

    def test_collect_and_summarize_with_stub_run_i8(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = os.path.join(tmp, "stub-run-i8.sh")
            counter = os.path.join(tmp, "count")
            with open(stub, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    "cat >/dev/null\n"
                    f"n=$(cat {counter} 2>/dev/null || echo 0)\n"
                    "n=$((n + 1))\n"
                    f"echo $n > {counter}\n"
                    "if [ $n -eq 1 ]; then\n"
                    "  printf 'rdpclip pid=4100 sess=2 privKB=2720 wsKB=8100 handles=320\\r\\n'\n"
                    "else\n"
                    "  printf 'rdpclip pid=4100 sess=2 privKB=2760 wsKB=8140 handles=320\\r\\n'\n"
                    "fi\n"
                )
            os.chmod(stub, 0o755)
            log_path = os.path.join(tmp, "mem.log")
            proc = subprocess.run(
                [sys.executable, RDPCLIP_MEM, "--run-i8", stub, "--interval", "0", "--count", "2", "--out", log_path],
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            lines = read_text(log_path).splitlines()
            self.assertEqual(len(lines), 2)
            self.assertTrue(all(" KST rdpclip pid=4100 " in l for l in lines))

            # Summarize within 100 KB threshold -> pass
            s_ok = subprocess.run(
                [sys.executable, RDPCLIP_MEM, "--summarize", log_path, "--max-delta-kb", "100", "--json"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(s_ok.returncode, 0, s_ok.stderr)
            summary = json.loads(s_ok.stdout)
            self.assertEqual(summary["totalSamples"], 2)
            self.assertEqual(summary["uniquePids"], 1)
            self.assertEqual(summary["maxDeltaKB"], 40)

            # Summarize with tighter threshold (20 KB) -> fail
            s_fail = subprocess.run(
                [sys.executable, RDPCLIP_MEM, "--summarize", log_path, "--max-delta-kb", "20"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(s_fail.returncode, 1)

    def test_summarize_tracks_pid_restart_across_reconnects(self):
        mod = load_module("rdpclip_mem", RDPCLIP_MEM)
        lines = [
            "2026-11-22 15:00:00 KST rdpclip pid=100 sess=2 privKB=2700 wsKB=8000 handles=320",
            "2026-11-22 15:00:05 KST rdpclip pid=100 sess=2 privKB=2740 wsKB=8040 handles=320",
            "2026-11-22 15:00:10 KST rdpclip none",
            "2026-11-22 15:00:15 KST rdpclip pid=205 sess=3 privKB=2680 wsKB=7900 handles=318",
            "2026-11-22 15:00:20 KST rdpclip pid=205 sess=3 privKB=2710 wsKB=7920 handles=318",
        ]
        summary = mod.summarize_samples(mod.parse_samples(lines))
        self.assertEqual(summary["totalSamples"], 4)
        self.assertEqual(summary["uniquePids"], 2)
        self.assertEqual(summary["maxDeltaKB"], 40)
        self.assertEqual([p["pid"] for p in summary["pids"]], [100, 205])


class TestCanLockOffScratch(unittest.TestCase):
    def _make_int13_fixture(self, root: str, rust_variant: str = "tail", c_variant: str = "tail"):
        rust_path = os.path.join(root, "Rust", "cndf-ironrdp", "src", "clipboard.rs")
        c_path = os.path.join(root, "Sources", "FreeRDPBridge", "FreeRDPBridge.c")
        os.makedirs(os.path.dirname(rust_path), exist_ok=True)
        os.makedirs(os.path.dirname(c_path), exist_ok=True)

        if rust_variant == "tail":
            rust_flags = (
                "            Capabilities::USE_LONG_FORMAT_NAMES\n"
                "                | Capabilities::STREAM_FILECLIP_ENABLED\n"
                "                | Capabilities::FILECLIP_NO_FILE_PATHS\n"
                "                | Capabilities::HUGE_FILE_SUPPORT_ENABLED\n"
                "                | Capabilities::CAN_LOCK_CLIPDATA\n"
            )
        else:
            rust_flags = (
                "            Capabilities::CAN_LOCK_CLIPDATA\n"
                "                | Capabilities::USE_LONG_FORMAT_NAMES\n"
                "                | Capabilities::STREAM_FILECLIP_ENABLED\n"
            )
        with open(rust_path, "w", encoding="utf-8") as fh:
            fh.write(
                "impl CliprdrBackend for CndfCliprdrBackend {\n"
                "    fn client_capabilities(&self) -> Capabilities {\n"
                + rust_flags
                + "    }\n"
                "}\n"
            )

        if c_variant == "tail":
            c_flags = (
                "    general.generalFlags = CB_USE_LONG_FORMAT_NAMES |\n"
                "                           CB_STREAM_FILECLIP_ENABLED |\n"
                "                           CB_FILECLIP_NO_FILE_PATHS |\n"
                "                           CB_HUGE_FILE_SUPPORT_ENABLED |\n"
                "                           CB_CAN_LOCK_CLIPDATA;\n"
            )
        else:
            c_flags = (
                "    general.generalFlags = CB_CAN_LOCK_CLIPDATA |\n"
                "                           CB_USE_LONG_FORMAT_NAMES |\n"
                "                           CB_STREAM_FILECLIP_ENABLED;\n"
            )
        with open(c_path, "w", encoding="utf-8") as fh:
            fh.write("static UINT monitor_ready(void) {\n" + c_flags + "    return 0;\n}\n")

    def test_dry_run_and_scratch_copy_strip_only_can_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "int13")
            dest = os.path.join(tmp, "scratch-off")
            self._make_int13_fixture(src)

            # --check must fail on CAN_LOCK-on source tree
            chk_before = subprocess.run([sys.executable, CAN_LOCK_OFF, "--check", src], capture_output=True, text=True)
            self.assertEqual(chk_before.returncode, 1)

            # --dry-run prints unified diff and does not create dest
            dry = subprocess.run([sys.executable, CAN_LOCK_OFF, "--src", src, "--dry-run"], capture_output=True, text=True)
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertIn("-                | Capabilities::CAN_LOCK_CLIPDATA", dry.stdout)
            self.assertIn("CB_CAN_LOCK_CLIPDATA", dry.stdout)
            self.assertFalse(os.path.exists(dest))

            # Create scratch copy
            build = subprocess.run(
                [sys.executable, CAN_LOCK_OFF, "--src", src, "--dest", dest],
                capture_output=True,
                text=True,
            )
            self.assertEqual(build.returncode, 0, build.stderr)
            self.assertTrue(os.path.isfile(os.path.join(dest, ".CAN_LOCK_OFF_SCRATCH_DO_NOT_SHIP")))

            # Scratch copy passes --check and preserves remaining flags; source is untouched
            chk_after = subprocess.run([sys.executable, CAN_LOCK_OFF, "--check", dest], capture_output=True, text=True)
            self.assertEqual(chk_after.returncode, 0, chk_after.stderr)
            rust_after = read_text(os.path.join(dest, "Rust/cndf-ironrdp/src/clipboard.rs"))
            c_after = read_text(os.path.join(dest, "Sources/FreeRDPBridge/FreeRDPBridge.c"))
            self.assertNotIn("CAN_LOCK_CLIPDATA", rust_after)
            self.assertIn("HUGE_FILE_SUPPORT_ENABLED", rust_after)
            self.assertNotIn("CB_CAN_LOCK_CLIPDATA", c_after)
            self.assertIn("CB_HUGE_FILE_SUPPORT_ENABLED;", c_after)
            self.assertIn("CAN_LOCK_CLIPDATA", read_text(os.path.join(src, "Rust/cndf-ironrdp/src/clipboard.rs")))

    def test_leading_flag_variant_also_strips_cleanly(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "int13-head")
            dest = os.path.join(tmp, "scratch-head")
            self._make_int13_fixture(src, rust_variant="head", c_variant="head")
            proc = subprocess.run([sys.executable, CAN_LOCK_OFF, "--src", src, "--dest", dest], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            rust_after = read_text(os.path.join(dest, "Rust/cndf-ironrdp/src/clipboard.rs"))
            c_after = read_text(os.path.join(dest, "Sources/FreeRDPBridge/FreeRDPBridge.c"))
            self.assertNotIn("CAN_LOCK_CLIPDATA", rust_after)
            self.assertIn("Capabilities::USE_LONG_FORMAT_NAMES", rust_after)
            self.assertNotIn("CB_CAN_LOCK_CLIPDATA", c_after)
            self.assertIn("CB_USE_LONG_FORMAT_NAMES", c_after)

    def test_recognizes_the_int13_repo_where_can_lock_is_advertised(self):
        # This harness branch is int-13 (CAN_LOCK advertised by both engines): the dry run must
        # find exactly the two advertisements it would strip.
        proc = subprocess.run(
            [sys.executable, CAN_LOCK_OFF, "--src", REPO_ROOT, "--dry-run"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("-                | Capabilities::CAN_LOCK_CLIPDATA", proc.stdout)
        self.assertIn("-                           CB_CAN_LOCK_CLIPDATA |", proc.stdout)


class TestI8ProbeScript(unittest.TestCase):
    def test_ascii_only_and_dialog_early_finish(self):
        with open(I8_PROBE, "rb") as fh:
            raw = fh.read()
        # PowerShell 5.1 reads BOM-less scripts as ANSI; keep i8probe.ps1 strictly ASCII.
        self.assertTrue(all(b < 128 for b in raw), "i8probe.ps1 contains non-ASCII bytes")
        text = raw.decode("ascii")
        self.assertEqual(text.count("{"), text.count("}"))
        self.assertIn('bool hasDialog = Dialogs() != "none";', text)
        self.assertIn("hasDialog && now - stateSince > 10000 && now - lastChange > 8000", text)


if __name__ == "__main__":
    unittest.main()

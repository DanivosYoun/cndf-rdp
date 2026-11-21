"""Two fixed test fixtures for a disposable xrdp session."""
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import os
from pathlib import Path
import pwd
import subprocess

USER = pwd.getpwnam("harness")
TOKEN = os.environ["HARNESS_B3_FIXTURE_TOKEN"]


def xclip(selection, data=None):
    env = os.environ.copy()
    for process in Path("/proc").glob("[0-9]*/environ"):
        try:
            if process.stat().st_uid != USER.pw_uid:
                continue
            environment = dict(
                variable.split(b"=", 1) for variable in process.read_bytes().split(b"\0") if b"=" in variable
            )
        except OSError:
            continue
        if not environment.get(b"DISPLAY", b"").startswith(b":"):
            continue
        env.update(
            DISPLAY=environment[b"DISPLAY"].decode(),
            XAUTHORITY=os.fsdecode(environment.get(b"XAUTHORITY", os.fsencode(USER.pw_dir + "/.Xauthority"))),
            HOME=USER.pw_dir,
        )
        return subprocess.run(
            ["runuser", "-u", USER.pw_name, "--", "xclip", "-selection", "clipboard", selection],
            input=data,
            stdout=subprocess.PIPE if data is None else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
            timeout=3,
            env=env,
        ).stdout
    raise RuntimeError("xrdp desktop is not running")


class Fixture(BaseHTTPRequestHandler):
    def handle_fixture(self, write):
        if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + TOKEN):
            self.send_error(403)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= 4 * 1024 * 1024:
                self.send_error(413)
                return
            if self.path == "/clipboard":
                if write:
                    xclip("-in", self.rfile.read(length))
                    body = b""
                else:
                    body = xclip("-out")
            elif self.path == "/drive" and write:
                body = subprocess.check_output(
                    ["runuser", "-u", USER.pw_name, "--", "sh", "-c",
                     'cd "$1/thinclient_drives/Home" && cat k3-read.txt && printf k3-write > k3-write.txt',
                     "sh", USER.pw_dir],
                    timeout=3,
                    stderr=subprocess.DEVNULL,
                )
            else:
                self.send_error(404)
                return
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
            self.send_error(503)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.handle_fixture(False)

    def do_POST(self):
        self.handle_fixture(True)


HTTPServer(("0.0.0.0", 8080), Fixture).serve_forever()

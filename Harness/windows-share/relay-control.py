#!/usr/bin/env python3
"""Loopback control endpoint for iron-share-verify: POST /restart-relay?mode=term|kill restarts the isolated relay
container (name from argv[2]) and answers once its /healthz is ok again. Listens on 127.0.0.1:argv[1]."""
import http.server, json, subprocess, sys, time, urllib.request

PORT, CONTAINER, HEALTH = int(sys.argv[1]), sys.argv[2], sys.argv[3]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        # /restart-relay?mode=term: docker restart (SIGTERM, the relay shuts down gracefully)
        # /restart-relay?mode=kill: SIGKILL, then start again (a crash)
        path, _, query = self.path.partition("?")
        if path != "/restart-relay":
            self.send_response(404); self.end_headers(); return
        mode = "kill" if "mode=kill" in query else "term"
        t0 = time.time()
        if mode == "kill":
            rc = subprocess.run(["docker", "kill", "-s", "KILL", CONTAINER], capture_output=True).returncode
            rc |= subprocess.run(["docker", "start", CONTAINER], capture_output=True).returncode
        else:
            rc = subprocess.run(["docker", "restart", "-t", "10", CONTAINER], capture_output=True).returncode
        t1 = time.time()
        healthy = False
        while time.time() - t1 < 60 and not healthy:
            try:
                healthy = json.load(urllib.request.urlopen(HEALTH, timeout=2)).get("ok") is True
            except Exception:
                time.sleep(0.2)
        body = json.dumps({"mode": mode, "rc": rc, "restartS": round(t1 - t0, 3), "healthyS": round(time.time() - t0, 3),
                           "healthy": healthy, "utc": time.strftime("%H:%M:%S", time.gmtime(t0))}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

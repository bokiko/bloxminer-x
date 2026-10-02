#!/usr/bin/env python3
"""Serves XMRig's real JSON HTTP API (GET /2/summary, GET /2/backends) from a config file, for h-stats.sh tests.
Config file (JSON), re-read on every request so a test can change it between calls:
  {"summary": <json object or null>, "backends": <json array or null>, "delay": <seconds, optional>}
A null body answers with HTTP 500 (stands in for a down/erroring miner)."""
import http.server
import json
import socketserver
import sys
import time

port, cfg_path = int(sys.argv[1]), sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):  # noqa: N802 (BaseHTTPRequestHandler's naming)
        with open(cfg_path) as f:
            cfg = json.load(f)
        time.sleep(cfg.get("delay", 0))
        body = None
        if self.path == "/2/summary":
            body = cfg.get("summary")
        elif self.path == "/2/backends":
            body = cfg.get("backends")
        if body is None:
            self.send_response(500)
            self.end_headers()
            return
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


# ThreadingMixIn, not plain http.server.HTTPServer: a bug this test harness itself had, found while chasing a
# false-zero pattern in a taskset -c 0 + delayed-summary test - a PLAIN HTTPServer handles exactly one
# connection at a time, serially, inside serve_forever(); when a poll's own curl --max-time gives up and
# disconnects while this handler is still mid-self.wfile.write() for that SAME (already-abandoned) connection,
# that write can itself stall for a while before the OS finally reports the broken pipe - and until it does,
# this single-threaded server cannot accept ANY new connection, including the very next poll's. That produced
# an exact, reproducible every-OTHER-poll false zero (poll N's own slow/abandoned write blocking poll N+1's
# connection) that had nothing to do with h-stats.sh itself - confirmed by reproducing it with a bare curl loop
# against this exact (unthreaded) server under the same taskset+load conditions, and by it disappearing
# entirely once threaded. A real XMRig instance's own HTTP API does not serialize unrelated requests behind a
# stuck write this way, so a threaded fixture is also the MORE realistic stand-in, not just the fix.
class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True   # a thread stuck on a slow/abandoned write must never block process exit at test end


srv = ThreadingServer(("127.0.0.1", port), Handler)
print("ready", flush=True)
srv.serve_forever()

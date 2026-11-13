#!/usr/bin/env python3
"""Run native transfer integration tests against a deterministic local HTTP server."""
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA = (bytes(range(251)) * ((2 * 1024 * 1024 + 2000) // 251 + 1))[:2 * 1024 * 1024 + 2000]
STALE = bytes(value ^ 0x55 for value in DATA)


def main(binary):
    calls = []
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            header = self.headers.get("Range", "")
            with lock:
                calls.append((path, header, self.headers.get("If-Range", "")))
            payload = STALE if path == "/stale" else DATA
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", header)
            if header and not match:
                self.send_error(400)
                return
            first = int(match.group(1)) if match else 0
            last = int(match.group(2)) if match and match.group(2) else len(payload) - 1
            last = min(last, len(payload) - 1)
            if first > last:
                self.send_error(416)
                return
            probe = header == "bytes=0-0"
            ranged = bool(match)
            if path == "/ignore" or path == "/stream-ignored" or (path == "/collapse" and not probe):
                ranged = False
                first, last = 0, len(payload) - 1
            if path == "/stream-unsolicited" and not header:
                ranged = True
                first, last = 0, 9
            body = payload[first:last + 1]
            self.send_response(206 if ranged else 200)
            if ranged:
                if path == "/badprobe" or path == "/stream-bad":
                    content_range = f"bytes {first}-{last}/not-a-size"
                elif path == "/wrong" and not probe:
                    content_range = f"bytes {first + 1}-{last}/{len(payload)}"
                else:
                    content_range = f"bytes {first}-{last}/{len(payload)}"
                self.send_header("Content-Range", content_range)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("ETag", '"stale"' if path == "/stale" else '"v1"')
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                if path in {"/slow", "/stale"} and len(body) > 1:
                    for offset in range(0, len(body), 16384):
                        self.wfile.write(body[offset:offset + 16384])
                        self.wfile.flush()
                        time.sleep(0.008)
                else:
                    self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass  # probes, cancellation and pause intentionally close early

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="moodyvid-transfer-test-") as directory:
            env = dict(os.environ, MV_TRANSFER_TEST_DIR=directory)
            result = subprocess.run([binary, f"http://127.0.0.1:{server.server_port}"],
                                    env=env, check=False, timeout=90)
        if result.returncode:
            return result.returncode
        with lock:
            snapshot = list(calls)
        ranged = [item for item in snapshot if item[0] == "/normal" and item[1] != "bytes=0-0"]
        resumed = [item for item in snapshot if item[0] == "/slow" and item[1].startswith("bytes=")
                   and not item[1].startswith("bytes=0-") and item[2] == '"v1"']
        if len(ranged) < 4:
            print(f"FAIL: expected multiple bounded direct ranges, got {ranged!r}", file=sys.stderr)
            return 1
        if not resumed:
            print(f"FAIL: pause/resume did not request a validated nonzero range: {snapshot!r}", file=sys.stderr)
            return 1
        return 0
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: transfer_server.py PATH_TO_TEST_BINARY")
    raise SystemExit(main(sys.argv[1]))

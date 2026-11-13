#!/usr/bin/env python3
"""Run the Foundation redirect integration binary against two loopback ports."""
import json
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main(binary):
    requests = {}
    servers = []

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_GET(self):
            kind = self.path.rsplit("-", 1)[-1]
            headers = {key.lower(): value for key, value in self.headers.items()}
            if self.path.startswith("/start-") and kind in {"same", "cross", "tracker"}:
                requests[kind] = headers
                port = servers[1 if kind == "cross" else 0].server_port
                location = f"http://127.0.0.1:{port}/destination-{kind}"
                self.send_response(302)
                self.send_header("Location", location)
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
            elif self.path.startswith("/destination-") and kind in requests:
                body = json.dumps({"initial": requests[kind], "final": headers}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_error(404)

    for _ in range(2):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        servers.append(server)
    threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in servers]
    for thread in threads:
        thread.start()
    try:
        urls = [f"http://127.0.0.1:{server.server_port}" for server in servers]
        return subprocess.run([binary, *urls], check=False, timeout=35).returncode
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: redirect_server.py PATH_TO_TEST_BINARY")
    raise SystemExit(main(sys.argv[1]))

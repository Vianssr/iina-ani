"""Loopback-only media fixture for download resume and credential-boundary regressions."""
import hashlib
import http.server
import json
import pathlib
import sys
import threading
import time
import urllib.parse

root = pathlib.Path(sys.argv[1]).resolve()
log_lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        mode = query.get("mode", [""])[0]
        with log_lock:
            with (root / "requests.jsonl").open("a") as log:
                log.write(json.dumps({"path": parsed.path, "range": self.headers.get("Range"),
                                      "referer": self.headers.get("Referer"),
                                      "cookie": self.headers.get("Cookie"),
                                      "host": self.headers.get("Host")}) + "\n")
        if parsed.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{self.server.server_port}/blob")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if mode == "auth":
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        file = (root / urllib.parse.unquote(parsed.path).lstrip("/")).resolve()
        if root not in file.parents or not file.is_file():
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        total = file.stat().st_size
        etag = '"' + hashlib.sha256(file.read_bytes()).hexdigest() + '"'
        start, end = 0, total - 1
        requested = self.headers.get("Range")
        status = 200
        if requested and mode != "ignore" and self.headers.get("If-Range", etag) == etag:
            bounds = requested.removeprefix("bytes=").split("-", 1)
            start = int(bounds[0])
            end = min(int(bounds[1]) if bounds[1] else end, end)
            if start >= total:
                self.send_response(416)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206
        self.send_response(status)
        self.send_header("ETag", etag)
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
        if mode != "unknown":
            self.send_header("Content-Length", str(end - start + 1))
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        try:
            with file.open("rb") as source:
                source.seek(start)
                remaining = end - start + 1
                while remaining:
                    chunk = source.read(min(32768, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    remaining -= len(chunk)
                    if mode in ("slow", "unknown"):
                        time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(server.server_port, flush=True)
server.serve_forever()

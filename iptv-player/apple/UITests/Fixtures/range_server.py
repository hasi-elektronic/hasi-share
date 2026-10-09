# Minimal HTTP server with Range support (VLC seeks in MKV over HTTP).
import http.server, os, re, sys, urllib.parse
class H(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        # Fake Xtream panel (people/category search UI tests): /player_api.php?…&action=X → xtream/X.json
        # (no action → xtream/auth.json); unknown actions → 404.
        u = urllib.parse.urlparse(self.path)
        if u.path == "/player_api.php":
            action = urllib.parse.parse_qs(u.query).get("action", ["auth"])[0]
            self.path = "/xtream/" + re.sub(r"[^a-z_]", "", action) + ".json"
        # /status/<code>/<anything>: answer with that HTTP status (error-card tests, e.g. 403).
        m = re.match(r"/status/(\d{3})/", self.path)
        if m:
            self.send_error(int(m.group(1))); return None
        path = self.translate_path(self.path)
        if os.path.isdir(path) or not os.path.exists(path):
            return super().send_head()
        size = os.path.getsize(path)
        m = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        f = open(path, "rb")
        ctype = self.guess_type(path)
        if not m:
            self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(size))
            self.send_header("Accept-Ranges", "bytes"); self.end_headers(); return f
        start = int(m.group(1)) if m.group(1) else max(0, size - int(m.group(2)))
        end = int(m.group(2)) if m.group(1) and m.group(2) else size - 1
        end = min(end, size - 1)
        self.send_response(206); self.send_header("Content-Type", ctype)
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}"); self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes"); self.end_headers()
        f.seek(start); self._remaining = end - start + 1; return f
    def copyfile(self, src, dst):
        n = getattr(self, "_remaining", None)
        if n is None: return super().copyfile(src, dst)
        try:
            while n > 0:
                b = src.read(min(65536, n))
                if not b: break
                dst.write(b); n -= len(b)
        except (BrokenPipeError, ConnectionResetError): pass
H.extensions_map.update({".mkv": "video/x-matroska", ".ts": "video/mp2t", ".m3u": "audio/x-mpegurl"})
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()

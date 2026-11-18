#!/usr/bin/env python3
"""Minimal fake of the GitHub API endpoints the app's update checker uses. Usage: fake_github.py PORT BINARY SHA40 [corrupt]"""
import hashlib, http.server, json, sys

port, binpath, sha40 = int(sys.argv[1]), sys.argv[2], sys.argv[3]
corrupt = len(sys.argv) > 4 and sys.argv[4] == "corrupt"
data = open(binpath, "rb").read()
digest = hashlib.sha256(data).hexdigest()
if corrupt:
    digest = "0" * 64
base = f"http://127.0.0.1:{port}"
NAME = "SeeedJiggler-macos-arm64"

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, body, ctype="application/json", code=200):
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.endswith("/releases/tags/latest"):
            self.send(json.dumps({"body": f"commit: {sha40}\n", "assets": [
                {"name": NAME, "browser_download_url": f"{base}/dl/{NAME}"},
                {"name": NAME + ".sha256", "browser_download_url": f"{base}/dl/{NAME}.sha256"}]}).encode())
        elif "/compare/" in self.path:
            self.send(json.dumps({"status": "ahead"}).encode())
        elif self.path == f"/dl/{NAME}":
            self.send(data, "application/octet-stream")
        elif self.path == f"/dl/{NAME}.sha256":
            self.send(f"{digest}  {NAME}\n".encode(), "text/plain")
        else:
            self.send(b"{}", code=404)

http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()

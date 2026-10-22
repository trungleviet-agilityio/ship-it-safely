"""Ship-it Board: tiny stdlib HTTP app for the ship-it-safely lab."""
import hashlib
import hmac
import html
import json
import os
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STARTED = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())


def image_digest():
    """Image digest from the ECS task metadata endpoint, or n/a on any error."""
    uri = os.environ.get("ECS_CONTAINER_METADATA_URI_V4")
    if not uri:
        return "n/a"
    try:
        with urllib.request.urlopen(uri, timeout=1) as r:
            return json.loads(r.read()).get("ImageID") or "n/a"
    except Exception:
        return "n/a"


def color():
    explicit = os.environ.get("APP_COLOR")
    if explicit:
        return explicit
    hue = int(hashlib.sha256(os.environ.get("GIT_SHA", "local").encode()).hexdigest(), 16) % 360
    return "hsl(%d, 60%%, 85%%)" % hue


def page():
    key_set = "yes" if os.environ.get("APP_API_KEY") else "no"
    rows = [
        ("APP_ENV", os.environ.get("APP_ENV", "unknown")),
        ("GIT_SHA", os.environ.get("GIT_SHA", "unknown")),
        ("started", STARTED),
        ("image digest", image_digest()),
        ("secret_loaded: " + key_set, ""),
    ]
    body = "".join("<p>%s</p>" % html.escape(": ".join(r) if r[1] else r[0]) for r in rows)
    return ('<!doctype html><html><head><meta charset="utf-8"><title>Ship-it Board</title></head>'
            '<body style="font-family:sans-serif;background:%s"><h1>Ship-it Board</h1>%s</body></html>'
            % (html.escape(color(), quote=True), body))


class Handler(BaseHTTPRequestHandler):
    def send(self, status, body, ctype="application/json"):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            self.send(200, page(), "text/html")
        elif path == "/health":
            broken = os.environ.get("BREAK", "").lower() == "true"
            self.send(500 if broken else 200, json.dumps({"status": "error" if broken else "ok"}))
        elif path == "/version":
            self.send(200, json.dumps({"env": os.environ.get("APP_ENV", "unknown"),
                                       "git_sha": os.environ.get("GIT_SHA", "unknown"),
                                       "image_digest": image_digest()}))
        elif path == "/admin":
            expected = os.environ.get("APP_API_KEY", "").encode()
            given = self.headers.get("X-API-Key", "").encode()
            if expected and hmac.compare_digest(given, expected):
                self.send(200, json.dumps({"admin": "ok"}))
            else:
                self.send(401, json.dumps({"error": "unauthorized"}))
        else:
            self.send(404, json.dumps({"error": "not found"}))

    def log_message(self, fmt, *args):
        # Log only method, path and status. Never headers (X-API-Key).
        print("%s %s" % (self.client_address[0],fmt % args), flush=True)


def make_server(port):
    return ThreadingHTTPServer(("0.0.0.0", port), Handler)


if __name__ == "__main__":
    make_server(int(os.environ.get("PORT", "8080"))).serve_forever()

"""Tests for the Ship-it Board. Run from app/: python -m unittest discover -s tests"""
import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
import board  # noqa: E402

KEY = "fake-test-key-123"
REAL_URLOPEN = urllib.request.urlopen


def get(port, path, headers=None):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), headers=headers or {})
    try:
        with REAL_URLOPEN(req, timeout=5) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


class BoardTest(unittest.TestCase):
    env = {"APP_ENV": "test", "GIT_SHA": "abc1234", "APP_API_KEY": KEY}

    def setUp(self):
        patcher = mock.patch.dict(os.environ, self.env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.server = board.make_server(0)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def test_index(self):
        status, body = get(self.port, "/")
        self.assertEqual(status, 200)
        for text in ("test", "abc1234", "secret_loaded: yes", "n/a"):
            self.assertIn(text, body)
        self.assertNotIn(KEY, body)

    def test_index_secret_not_loaded(self):
        with mock.patch.dict(os.environ, {"APP_API_KEY": ""}):
            self.assertIn("secret_loaded: no", get(self.port, "/")[1])

    def test_index_escapes_html(self):
        with mock.patch.dict(os.environ, {"APP_ENV": "<script>x</script>"}):
            body = get(self.port, "/")[1]
        self.assertNotIn("<script>x", body)
        self.assertIn("&lt;script&gt;", body)

    def test_color_override_and_derived(self):
        with mock.patch.dict(os.environ, {"APP_COLOR": "#123456"}):
            self.assertIn("#123456", get(self.port, "/")[1])
        self.assertIn("hsl(", get(self.port, "/")[1])

    def test_health_ok(self):
        status, body = get(self.port, "/health")
        self.assertEqual((status, json.loads(body)), (200, {"status": "ok"}))

    def test_health_break(self):
        with mock.patch.dict(os.environ, {"BREAK": "true"}):
            self.assertEqual(get(self.port, "/health")[0], 500)

    def test_version(self):
        status, body = get(self.port, "/version")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body),
                         {"env": "test", "git_sha": "abc1234", "image_digest": "n/a"})

    def test_admin_with_key(self):
        status, body = get(self.port, "/admin", {"X-API-Key": KEY})
        self.assertEqual(status, 200)
        self.assertNotIn(KEY, body)

    def test_admin_without_or_wrong_key(self):
        self.assertEqual(get(self.port, "/admin")[0], 401)
        status, body = get(self.port, "/admin", {"X-API-Key": "wrong"})
        self.assertEqual(status, 401)
        self.assertNotIn(KEY, body)

    def test_admin_unset_or_empty_key_never_matches(self):
        with mock.patch.dict(os.environ, {"APP_API_KEY": ""}):
            self.assertEqual(get(self.port, "/admin", {"X-API-Key": ""})[0], 401)
        with mock.patch.dict(os.environ):
            del os.environ["APP_API_KEY"]
            self.assertEqual(get(self.port, "/admin", {"X-API-Key": ""})[0], 401)

    def test_unknown_path(self):
        self.assertEqual(get(self.port, "/nope")[0], 404)

    def test_digest_from_metadata(self):
        class Resp:
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def read(self): return b'{"ImageID": "sha256:deadbeef"}'
        with mock.patch.dict(os.environ, {"ECS_CONTAINER_METADATA_URI_V4": "http://x"}), \
                mock.patch("urllib.request.urlopen", return_value=Resp()):
            self.assertEqual(board.image_digest(), "sha256:deadbeef")

    def test_digest_error_is_na(self):
        with mock.patch.dict(os.environ, {"ECS_CONTAINER_METADATA_URI_V4": "http://x"}), \
                mock.patch("urllib.request.urlopen", side_effect=OSError):
            self.assertEqual(board.image_digest(), "n/a")


if __name__ == "__main__":
    unittest.main()

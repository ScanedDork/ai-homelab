"""Tests for dashboard/server.py against stub upstream services.

Run: python3 -m unittest discover -s dashboard/tests -v   (or `make test`)
Standard library only; every upstream is a local stub on a random port.
"""

import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server  # noqa: E402

TOKEN = "test-token-0123456789abcdef"
LITELLM_KEY = "sk-test-litellm-key"


class Stub(BaseHTTPRequestHandler):
    """One stub process serving n8n, Ollama, LiteLLM and OpenClaw routes."""
    seen_auth = []
    fail_chat = False

    def log_message(self, *a):
        pass

    def _json(self, code, obj, headers=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        routes = {
            "/healthz": {"status": "ok"},
            "/api/version": {"version": "0.12.3"},
            "/api/tags": {"models": [
                {"name": "qwen3.5:4b", "size": 3_400_000_000, "modified_at": "2026-10-01T00:00:00Z",
                 "details": {"family": "qwen3", "parameter_size": "4B", "quantization_level": "Q4_K_M"}},
                {"name": "llama3.2:3b", "size": 2_000_000_000, "details": {"parameter_size": "3.2B"}},
            ]},
            "/api/ps": {"models": [{"name": "qwen3.5:4b"}]},
            "/health/liveliness": "I'm alive!",
        }
        if self.path == "/v1/models":
            Stub.seen_auth.append(self.headers.get("Authorization"))
            return self._json(200, {"data": [{"id": "local-chat"}, {"id": "groq-llama"}]})
        if self.path in routes:
            return self._json(200, routes[self.path])
        return self._json(404, {})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Stub.seen_auth.append(self.headers.get("Authorization"))
        if self.path != "/v1/chat/completions":
            return self._json(404, {})
        if Stub.fail_chat:
            return self._json(429, {"error": {"message": "No deployments available"}})
        hdrs = {"x-litellm-model-group": "gemini-flash", "x-litellm-attempted-fallbacks": "1"}
        if not body.get("stream"):
            return self._json(200, {"choices": [{"message": {"content": "pong"}}]}, hdrs)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        for k, v in hdrs.items():
            self.send_header(k, v)
        self.end_headers()
        for piece in ("po", "ng"):
            chunk = {"choices": [{"delta": {"content": piece}}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")


def start(server_obj):
    t = threading.Thread(target=server_obj.serve_forever, daemon=True)
    t.start()
    return f"http://127.0.0.1:{server_obj.server_address[1]}"


class DashboardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.stub = ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        stub_url = start(cls.stub)
        cls.tmp = tempfile.TemporaryDirectory()
        cls.status_file = Path(cls.tmp.name) / "status.json"
        env = {
            "DASHBOARD_TOKEN": TOKEN,
            "DASHBOARD_N8N_URL": stub_url,
            "N8N_URL": "http://n8npi:5678",
            "OLLAMA_URL": stub_url,
            "LITELLM_URL": stub_url,
            "LITELLM_MASTER_KEY": LITELLM_KEY,
            "OPENCLAW_URL": "",
            "HEALTHCHECK_REQUIRED_MODELS": "qwen3.5:4b",
            "BACKUP_STATUS_FILE": str(cls.status_file),
            "DASHBOARD_CACHE_SECONDS": "0",
            "DASHBOARD_ACCESS_LOG": "0",
        }
        cls.cfg = server.Config(env)
        cls.app = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(cls.cfg))
        cls.url = start(cls.app)

    @classmethod
    def tearDownClass(cls):
        cls.app.shutdown()
        cls.stub.shutdown()
        cls.tmp.cleanup()

    def setUp(self):
        Stub.seen_auth = []
        Stub.fail_chat = False
        self.write_status(hours_ago=2)

    # -- helpers --------------------------------------------------------------
    def write_status(self, hours_ago=2.0, result="ok"):
        last = (datetime.now(timezone.utc) - timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.status_file.write_text(json.dumps({
            "last_run": last, "result": result, "message": "backup completed",
            "archive": "n8n-data-20261104-031500.tar.gz", "size_bytes": 1048576,
            "sha256": "ab" * 32, "archive_count": 3, "retention": 14,
        }))

    def request(self, path, token=TOKEN, method="GET", body=None):
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.url + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, r.headers, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()

    def json(self, path, **kw):
        status, headers, body = self.request(path, **kw)
        return status, headers, json.loads(body)

    # -- tests ----------------------------------------------------------------
    def test_healthz_needs_no_token(self):
        status, _, body = self.json("/healthz", token=None)
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")

    def test_api_requires_valid_token(self):
        for token in (None, "wrong-token-0123456789"):
            status, headers, _ = self.json("/api/status", token=token)
            self.assertEqual(status, 401)
            self.assertIn("Bearer", headers["WWW-Authenticate"])

    def test_config_has_no_secrets(self):
        status, _, body = self.json("/api/config")
        self.assertEqual(status, 200)
        blob = json.dumps(body)
        self.assertNotIn(LITELLM_KEY, blob)
        self.assertNotIn(TOKEN, blob)
        self.assertEqual(body["links"]["n8n"], "http://n8npi:5678")
        self.assertIsNone(body["links"]["openclaw"])

    def test_status_groups_checks_by_device(self):
        status, _, body = self.json("/api/status")
        self.assertEqual(status, 200)
        by_name = {c["name"]: c for c in body["checks"]}
        self.assertEqual(by_name["n8n"]["status"], "OK")
        self.assertEqual(by_name["ollama"]["status"], "OK")
        self.assertEqual(by_name["ollama"]["detail"], "v0.12.3")
        self.assertEqual(by_name["ollama-models"]["status"], "OK")
        self.assertEqual(by_name["litellm"]["status"], "OK")
        self.assertEqual(by_name["openclaw"]["status"], "SKIP")
        self.assertEqual(by_name["backups"]["status"], "OK")
        self.assertEqual(by_name["ollama"]["device"], "dorkmini")
        self.assertEqual(by_name["n8n"]["device"], "n8npi")
        self.assertEqual(body["overall"], "OK")

    def test_status_flags_stale_and_failed_backups(self):
        self.write_status(hours_ago=50)
        _, _, body = self.json("/api/status")
        self.assertEqual({c["name"]: c for c in body["checks"]}["backups"]["status"], "WARN")
        self.assertEqual(body["overall"], "WARN")
        self.write_status(hours_ago=1, result="failed")
        _, _, body = self.json("/api/status")
        self.assertEqual({c["name"]: c for c in body["checks"]}["backups"]["status"], "FAIL")

    def test_missing_status_file_is_warn_not_crash(self):
        self.status_file.unlink()
        _, _, body = self.json("/api/backups")
        self.assertFalse(body["available"])
        _, _, body = self.json("/api/status")
        self.assertEqual({c["name"]: c for c in body["checks"]}["backups"]["status"], "WARN")

    def test_unreachable_upstream_reports_fail(self):
        cfg = server.Config({"DASHBOARD_TOKEN": TOKEN, "OLLAMA_URL": "http://127.0.0.1:9",
                             "DASHBOARD_CHECK_TIMEOUT": "1"})
        results = server.check_ollama(cfg)
        self.assertEqual(results[0]["status"], "FAIL")
        self.assertEqual(results[1]["status"], "SKIP")

    def test_models(self):
        status, _, body = self.json("/api/models")
        self.assertEqual(status, 200)
        installed = {m["name"]: m for m in body["ollama"]["installed"]}
        self.assertTrue(installed["qwen3.5:4b"]["loaded"])
        self.assertTrue(installed["qwen3.5:4b"]["required"])
        self.assertFalse(installed["llama3.2:3b"]["loaded"])
        self.assertEqual(body["ollama"]["missing_required"], [])
        self.assertEqual([g["id"] for g in body["litellm"]["groups"]], ["groq-llama", "local-chat"])
        self.assertEqual(Stub.seen_auth, [f"Bearer {LITELLM_KEY}"])

    def test_chat_streams_and_forwards_routing_headers(self):
        status, headers, body = self.request("/api/chat", method="POST", body={
            "model": "local-chat", "messages": [{"role": "user", "content": "ping"}]})
        self.assertEqual(status, 200)
        self.assertTrue(headers["Content-Type"].startswith("text/event-stream"))
        self.assertEqual(headers["X-Model-Group"], "gemini-flash")
        self.assertEqual(headers["X-Attempted-Fallbacks"], "1")
        text = "".join(json.loads(line[5:])["choices"][0]["delta"]["content"]
                       for line in body.decode().splitlines()
                       if line.startswith("data: {"))
        self.assertEqual(text, "pong")
        self.assertEqual(Stub.seen_auth[-1], f"Bearer {LITELLM_KEY}")

    def test_chat_non_stream(self):
        status, _, body = self.json("/api/chat", method="POST", body={
            "model": "local-chat", "stream": False, "messages": [{"role": "user", "content": "ping"}]})
        self.assertEqual(status, 200)
        self.assertEqual(body["choices"][0]["message"]["content"], "pong")

    def test_chat_validation(self):
        bad = [
            {"model": "local chat!", "messages": [{"role": "user", "content": "x"}]},
            {"model": "local-chat", "messages": []},
            {"model": "local-chat", "messages": [{"role": "tool", "content": "x"}]},
            {"model": "local-chat", "messages": [{"role": "assistant", "content": "x"}]},
            {"model": "local-chat", "messages": [{"role": "user", "content": "x" * 40_000}]},
            {"model": "local-chat", "temperature": 5, "messages": [{"role": "user", "content": "x"}]},
        ]
        for payload in bad:
            status, _, body = self.json("/api/chat", method="POST", body=payload)
            self.assertEqual(status, 400, payload)
            self.assertIn("error", body)
        status, _, _ = self.request("/api/chat", method="POST", body=b"{not json")
        self.assertEqual(status, 400)
        self.assertEqual(Stub.seen_auth, [], "invalid requests must not reach LiteLLM")

    def test_chat_requires_token(self):
        status, _, _ = self.request("/api/chat", token=None, method="POST",
                                    body={"model": "local-chat", "messages": [{"role": "user", "content": "x"}]})
        self.assertEqual(status, 401)
        self.assertEqual(Stub.seen_auth, [])

    def test_chat_upstream_error_is_relayed(self):
        Stub.fail_chat = True
        status, _, body = self.json("/api/chat", method="POST", body={
            "model": "local-chat", "messages": [{"role": "user", "content": "x"}]})
        self.assertEqual(status, 429)
        self.assertIn("No deployments available", body["error"])

    def test_static_files_and_security_headers(self):
        status, headers, body = self.request("/", token=None)
        self.assertEqual(status, 200)
        self.assertIn(b"<title>Homelab Dashboard</title>", body)
        self.assertIn("default-src 'self'", headers["Content-Security-Policy"])
        self.assertEqual(headers["X-Frame-Options"], "DENY")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        status, headers, _ = self.request("/app.js", token=None)
        self.assertEqual(status, 200)
        self.assertIn("javascript", headers["Content-Type"])

    def test_path_traversal_blocked(self):
        for path in ("/../server.py", "/%2e%2e/server.py", "/static/../../server.py", "/nope.html"):
            status, _, _ = self.request(path, token=None)
            self.assertEqual(status, 404, path)

    def test_config_validation_rejects_placeholder_token(self):
        for token in ("", "short", "replace-with-openssl-rand-hex-32"):
            self.assertTrue(server.Config({"DASHBOARD_TOKEN": token}).validate(), token)
        self.assertEqual(server.Config({"DASHBOARD_TOKEN": TOKEN}).validate(), [])

    def test_check_config_cli(self):
        old = dict(os.environ)
        try:
            os.environ["DASHBOARD_TOKEN"] = "replace-with-openssl-rand-hex-32"
            self.assertEqual(server.main(["--check-config"]), 2)
            os.environ["DASHBOARD_TOKEN"] = TOKEN
            self.assertEqual(server.main(["--check-config"]), 0)
        finally:
            os.environ.clear()
            os.environ.update(old)


if __name__ == "__main__":
    unittest.main()

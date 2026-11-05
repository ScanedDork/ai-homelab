#!/usr/bin/env python3
"""Homelab dashboard server (Python standard library only).

Serves the static frontend in ./static and a small JSON API that aggregates
the homelab services server-side, so the browser never talks to Ollama or
LiteLLM directly and never sees the LiteLLM key.

API (all /api/* routes need `Authorization: Bearer $DASHBOARD_TOKEN`):
  GET  /healthz        liveness for Docker / scripts/healthcheck.sh (no auth)
  GET  /api/config     non-secret UI config (links, refresh interval)
  GET  /api/status     service checks grouped by device (cached briefly)
  GET  /api/models     Ollama installed/loaded/required + LiteLLM model groups
  GET  /api/backups    BACKUP_DIR/status/status.json written by backup-n8n.sh
  POST /api/chat       chat via LiteLLM; streams Server-Sent Events

Configuration comes from environment variables (see dashboard/README.md).
Run `python3 server.py --help` for CLI options.
"""

from __future__ import annotations

import argparse
import hmac
import json
import mimetypes
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

VERSION = "1.0.0"
STATIC_DIR = Path(__file__).resolve().parent / "static"

MAX_BODY_BYTES = 256 * 1024
MAX_MESSAGES = 50
MAX_TOTAL_CHARS = 32_000
MODEL_RE = re.compile(r"^[A-Za-z0-9._:/@-]{1,100}$")
ROLES = {"system", "user", "assistant"}
FORWARDED_LITELLM_HEADERS = {
    "x-litellm-model-group": "X-Model-Group",
    "x-litellm-attempted-fallbacks": "X-Attempted-Fallbacks",
    "x-litellm-attempted-retries": "X-Attempted-Retries",
    "x-litellm-model-id": "X-Model-Id",
}
PLACEHOLDER_PREFIXES = ("replace-with", "changeme", "change-me")


class Config:
    """Settings read once from the environment."""

    def __init__(self, env: dict[str, str]):
        get = lambda k, d="": env.get(k, d).strip()  # noqa: E731
        self.token = get("DASHBOARD_TOKEN")
        self.n8n_url = get("DASHBOARD_N8N_URL", get("N8N_URL", "http://n8n:5678")).rstrip("/")
        self.n8n_public_url = get("N8N_URL", "http://n8npi:5678").rstrip("/")
        self.ollama_url = get("OLLAMA_URL", "http://dorkmini:11434").rstrip("/")
        self.litellm_url = get("LITELLM_URL", "http://n8npi:4000").rstrip("/")
        self.litellm_key = get("LITELLM_MASTER_KEY")
        self.openclaw_url = get("OPENCLAW_URL").rstrip("/")
        self.required_models = get("HEALTHCHECK_REQUIRED_MODELS", "qwen3.5:4b").split()
        self.backup_status_file = Path(
            get("BACKUP_STATUS_FILE", "/data/backup-status/status.json"))
        self.backup_max_age_hours = float(get("BACKUP_MAX_AGE_HOURS", "36") or 36)
        self.timeout = float(get("DASHBOARD_CHECK_TIMEOUT", "5") or 5)
        self.chat_timeout = float(get("DASHBOARD_CHAT_TIMEOUT", "180") or 180)
        self.cache_seconds = float(get("DASHBOARD_CACHE_SECONDS", "5") or 5)
        self.refresh_seconds = int(get("DASHBOARD_REFRESH_SECONDS", "30") or 30)
        self.pi_name = get("PI_HOSTNAME", "n8npi")
        self.mac_name = get("MAC_HOSTNAME", "dorkmini")
        self.access_log = get("DASHBOARD_ACCESS_LOG", "1") != "0"

    def validate(self) -> list[str]:
        problems = []
        if len(self.token) < 16 or self.token.lower().startswith(PLACEHOLDER_PREFIXES):
            problems.append("DASHBOARD_TOKEN must be set to a random value of 16+ characters "
                            "(openssl rand -hex 32)")
        return problems


# --------------------------------------------------------------------------
# Upstream helpers
# --------------------------------------------------------------------------

class UpstreamError(Exception):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


def http_request(url: str, *, timeout: float, method: str = "GET", data: bytes | None = None,
                 headers: dict[str, str] | None = None):
    """Return (status, headers, body_bytes); raise UpstreamError on network errors."""
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (fixed URLs)
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.headers, exc.read()
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        reason = getattr(exc, "reason", exc)
        raise UpstreamError(str(reason)) from exc


def get_json(url: str, *, timeout: float, headers: dict[str, str] | None = None):
    status, _, body = http_request(url, timeout=timeout, headers=headers)
    if not 200 <= status < 300:
        raise UpstreamError(f"HTTP {status}", status)
    try:
        return json.loads(body)
    except ValueError as exc:
        raise UpstreamError("invalid JSON from upstream") from exc


def litellm_headers(cfg: Config) -> dict[str, str]:
    h = {"Content-Type": "application/json"}
    if cfg.litellm_key:
        h["Authorization"] = f"Bearer {cfg.litellm_key}"
    return h


def normalise_tag(name: str) -> str:
    return name if ":" in name else f"{name}:latest"


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

def _result(name, device, status, detail, started=None, link=None):
    out = {"name": name, "device": device, "status": status, "detail": detail}
    if started is not None:
        out["latency_ms"] = round((time.monotonic() - started) * 1000)
    if link:
        out["link"] = link
    return out


def check_n8n(cfg: Config):
    t = time.monotonic()
    try:
        status, _, body = http_request(f"{cfg.n8n_url}/healthz", timeout=cfg.timeout)
    except UpstreamError as exc:
        return _result("n8n", cfg.pi_name, "FAIL", str(exc), t, cfg.n8n_public_url)
    ok = status == 200 and b"ok" in body
    return _result("n8n", cfg.pi_name, "OK" if ok else "FAIL",
                   "healthy" if ok else f"HTTP {status}", t, cfg.n8n_public_url)


def check_ollama(cfg: Config):
    t = time.monotonic()
    try:
        version = get_json(f"{cfg.ollama_url}/api/version", timeout=cfg.timeout).get("version", "?")
    except UpstreamError as exc:
        return [_result("ollama", cfg.mac_name, "FAIL", f"{exc} (Mac asleep? bound to TS IP?)", t),
                _result("ollama-models", cfg.mac_name, "SKIP", "Ollama unreachable")]
    first = _result("ollama", cfg.mac_name, "OK", f"v{version}", t)
    if not cfg.required_models:
        return [first, _result("ollama-models", cfg.mac_name, "SKIP", "none required")]
    t = time.monotonic()
    try:
        tags = get_json(f"{cfg.ollama_url}/api/tags", timeout=cfg.timeout)
    except UpstreamError as exc:
        return [first, _result("ollama-models", cfg.mac_name, "FAIL", str(exc), t)]
    installed = {m.get("name") for m in tags.get("models", [])}
    missing = [m for m in cfg.required_models if normalise_tag(m) not in installed]
    if missing:
        return [first, _result("ollama-models", cfg.mac_name, "FAIL",
                               "missing: " + ", ".join(missing), t)]
    return [first, _result("ollama-models", cfg.mac_name, "OK",
                           f"{len(cfg.required_models)} required present", t)]


def check_litellm(cfg: Config):
    t = time.monotonic()
    try:
        status, _, _ = http_request(f"{cfg.litellm_url}/health/liveliness", timeout=cfg.timeout)
    except UpstreamError as exc:
        return _result("litellm", cfg.pi_name, "FAIL", str(exc), t)
    return _result("litellm", cfg.pi_name, "OK" if status == 200 else "FAIL",
                   "alive" if status == 200 else f"HTTP {status}", t)


def check_openclaw(cfg: Config):
    if not cfg.openclaw_url:
        return _result("openclaw", cfg.pi_name, "SKIP", "OPENCLAW_URL not set")
    t = time.monotonic()
    try:
        status, _, _ = http_request(f"{cfg.openclaw_url}/healthz", timeout=cfg.timeout)
    except UpstreamError as exc:
        return _result("openclaw", cfg.pi_name, "FAIL", str(exc), t, cfg.openclaw_url)
    return _result("openclaw", cfg.pi_name, "OK" if status == 200 else "FAIL",
                   "healthy" if status == 200 else f"HTTP {status}", t, cfg.openclaw_url)


def read_backup_status(cfg: Config) -> dict:
    """Return status.json plus derived fields; never raises."""
    path = cfg.backup_status_file
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"available": False, "error": "no status file yet (has backup-n8n.sh run?)"}
    except (OSError, ValueError) as exc:
        return {"available": False, "error": f"cannot read status file: {exc}"}
    if not isinstance(data, dict):
        return {"available": False, "error": "status file is not a JSON object"}
    age = None
    try:
        last = datetime.fromisoformat(str(data.get("last_run", "")).replace("Z", "+00:00"))
        age = round((datetime.now(timezone.utc) - last).total_seconds() / 3600, 1)
    except ValueError:
        pass
    stale = age is None or age > cfg.backup_max_age_hours
    return {"available": True, **data, "age_hours": age, "stale": stale,
            "max_age_hours": cfg.backup_max_age_hours}


def check_backups(cfg: Config):
    s = read_backup_status(cfg)
    if not s["available"]:
        return _result("backups", cfg.pi_name, "WARN", s["error"])
    if s.get("result") != "ok":
        return _result("backups", cfg.pi_name, "FAIL", f"last run failed: {s.get('message', '')}")
    if s["stale"]:
        return _result("backups", cfg.pi_name, "WARN", f"last backup {s['age_hours']} h ago")
    return _result("backups", cfg.pi_name, "OK",
                   f"{s['age_hours']} h ago, {s.get('archive_count', '?')} kept")


def run_checks(cfg: Config) -> dict:
    with ThreadPoolExecutor(max_workers=5) as pool:
        futures = [pool.submit(f, cfg) for f in
                   (check_n8n, check_ollama, check_litellm, check_openclaw, check_backups)]
        checks = []
        for fut in futures:
            res = fut.result()
            checks.extend(res if isinstance(res, list) else [res])
    counts = {s: sum(1 for c in checks if c["status"] == s) for s in ("OK", "WARN", "FAIL", "SKIP")}
    overall = "FAIL" if counts["FAIL"] else "WARN" if counts["WARN"] else "OK"
    return {"overall": overall, "counts": counts, "checks": checks,
            "devices": [cfg.pi_name, cfg.mac_name],
            "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}


def collect_models(cfg: Config) -> dict:
    out: dict = {"ollama": {}, "litellm": {}}
    try:
        tags = get_json(f"{cfg.ollama_url}/api/tags", timeout=cfg.timeout)
        try:
            ps = get_json(f"{cfg.ollama_url}/api/ps", timeout=cfg.timeout)
        except UpstreamError:
            ps = {"models": []}
        loaded = {m.get("name"): m for m in ps.get("models", [])}
        installed = []
        for m in tags.get("models", []):
            d = m.get("details") or {}
            installed.append({
                "name": m.get("name"),
                "size_bytes": m.get("size"),
                "modified_at": m.get("modified_at"),
                "family": d.get("family"),
                "parameter_size": d.get("parameter_size"),
                "quantization": d.get("quantization_level"),
                "loaded": m.get("name") in loaded,
                "required": m.get("name") in {normalise_tag(r) for r in cfg.required_models},
            })
        names = {m["name"] for m in installed}
        out["ollama"] = {
            "url": cfg.ollama_url,
            "installed": sorted(installed, key=lambda m: m["name"] or ""),
            "missing_required": [r for r in cfg.required_models if normalise_tag(r) not in names],
        }
    except UpstreamError as exc:
        out["ollama"] = {"url": cfg.ollama_url, "error": str(exc)}
    try:
        data = get_json(f"{cfg.litellm_url}/v1/models", timeout=cfg.timeout,
                        headers=litellm_headers(cfg))
        groups = sorted({m.get("id") for m in data.get("data", []) if m.get("id")})
        out["litellm"] = {"groups": [{"id": g, "local": g.startswith("local-")} for g in groups]}
    except UpstreamError as exc:
        out["litellm"] = {"error": str(exc), "groups": []}
    return out


def validate_chat(payload) -> tuple[dict | None, str | None]:
    """Return (clean_payload, error)."""
    if not isinstance(payload, dict):
        return None, "body must be a JSON object"
    model = payload.get("model")
    if not isinstance(model, str) or not MODEL_RE.match(model):
        return None, "model must be a model group name"
    messages = payload.get("messages")
    if not isinstance(messages, list) or not 1 <= len(messages) <= MAX_MESSAGES:
        return None, f"messages must be a list of 1-{MAX_MESSAGES} items"
    total = 0
    clean_msgs = []
    for m in messages:
        if not isinstance(m, dict) or m.get("role") not in ROLES or not isinstance(m.get("content"), str):
            return None, "each message needs role (system/user/assistant) and string content"
        total += len(m["content"])
        clean_msgs.append({"role": m["role"], "content": m["content"]})
    if total > MAX_TOTAL_CHARS:
        return None, f"conversation too long (>{MAX_TOTAL_CHARS} characters)"
    if clean_msgs[-1]["role"] != "user" or not clean_msgs[-1]["content"].strip():
        return None, "last message must be a non-empty user message"
    clean = {"model": model, "messages": clean_msgs, "stream": payload.get("stream", True) is not False}
    temp = payload.get("temperature")
    if temp is not None:
        if not isinstance(temp, (int, float)) or isinstance(temp, bool) or not 0 <= temp <= 2:
            return None, "temperature must be between 0 and 2"
        clean["temperature"] = float(temp)
    return clean, None


# --------------------------------------------------------------------------
# HTTP handler
# --------------------------------------------------------------------------

class Cache:
    def __init__(self):
        self._lock = threading.Lock()
        self._value = None
        self._at = 0.0

    def get(self, ttl: float, producer):
        with self._lock:
            if self._value is not None and time.monotonic() - self._at < ttl:
                return self._value
        value = producer()
        with self._lock:
            self._value, self._at = value, time.monotonic()
        return value


SECURITY_HEADERS = {
    "Content-Security-Policy": ("default-src 'self'; img-src 'self' data:; style-src 'self'; "
                                "script-src 'self'; connect-src 'self'; frame-ancestors 'none'; "
                                "base-uri 'none'; form-action 'none'"),
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
    "Cross-Origin-Opener-Policy": "same-origin",
}


def make_handler(cfg: Config):
    status_cache = Cache()

    class Handler(BaseHTTPRequestHandler):
        server_version = f"homelab-dashboard/{VERSION}"
        sys_version = ""

        # ---- plumbing ------------------------------------------------------
        def log_message(self, fmt, *args):  # concise access log, never headers
            if cfg.access_log:
                sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

        def _send(self, status: int, body: bytes, content_type: str, extra: dict | None = None):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store" if self.path.startswith("/api/") else "no-cache")
            for k, v in {**SECURITY_HEADERS, **(extra or {})}.items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _json(self, status: int, obj, extra: dict | None = None):
            self._send(status, json.dumps(obj).encode(), "application/json; charset=utf-8", extra)

        def _error(self, status: int, message: str):
            self._json(status, {"error": message})

        def _authorized(self) -> bool:
            header = self.headers.get("Authorization", "")
            scheme, _, supplied = header.partition(" ")
            if scheme.lower() == "bearer" and supplied and hmac.compare_digest(
                    supplied.strip().encode(), cfg.token.encode()):
                return True
            self._json(HTTPStatus.UNAUTHORIZED, {"error": "missing or invalid dashboard token"},
                       {"WWW-Authenticate": 'Bearer realm="homelab-dashboard"'})
            return False

        # ---- routing -------------------------------------------------------
        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/healthz":
                return self._json(200, {"status": "ok", "version": VERSION})
            if path.startswith("/api/"):
                if not self._authorized():
                    return None
                routes = {
                    "/api/config": self._api_config,
                    "/api/status": lambda: self._json(200, status_cache.get(
                        cfg.cache_seconds, lambda: run_checks(cfg))),
                    "/api/models": lambda: self._json(200, collect_models(cfg)),
                    "/api/backups": lambda: self._json(200, read_backup_status(cfg)),
                }
                handler = routes.get(path)
                return handler() if handler else self._error(404, "unknown endpoint")
            return self._static(path)

        def do_POST(self):
            path = self.path.split("?", 1)[0]
            if path != "/api/chat":
                return self._error(404, "unknown endpoint")
            if not self._authorized():
                return None
            return self._api_chat()

        # ---- endpoints -----------------------------------------------------
        def _api_config(self):
            self._json(200, {
                "version": VERSION,
                "refresh_seconds": cfg.refresh_seconds,
                "devices": {"pi": cfg.pi_name, "mac": cfg.mac_name},
                "links": {"n8n": cfg.n8n_public_url, "openclaw": cfg.openclaw_url or None},
                "chat_enabled": bool(cfg.litellm_url),
            })

        def _static(self, path: str):
            rel = "index.html" if path in ("", "/") else path.lstrip("/")
            target = (STATIC_DIR / rel).resolve()
            if STATIC_DIR not in target.parents or not target.is_file():
                return self._error(404, "not found")
            ctype = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
            if ctype.startswith("text/") or ctype in ("application/javascript", "image/svg+xml"):
                ctype += "; charset=utf-8"
            return self._send(200, target.read_bytes(), ctype)

        def _api_chat(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return self._error(400, "invalid Content-Length")
            if not 0 < length <= MAX_BODY_BYTES:
                return self._error(413 if length > MAX_BODY_BYTES else 400, "body missing or too large")
            try:
                payload = json.loads(self.rfile.read(length))
            except ValueError:
                return self._error(400, "body is not valid JSON")
            clean, err = validate_chat(payload)
            if err:
                return self._error(400, err)

            req = urllib.request.Request(
                f"{cfg.litellm_url}/v1/chat/completions", method="POST",
                data=json.dumps(clean).encode(), headers=litellm_headers(cfg))
            try:
                resp = urllib.request.urlopen(req, timeout=cfg.chat_timeout)  # noqa: S310
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")
                try:
                    detail = json.loads(detail).get("error", {}).get("message", detail)
                except (ValueError, AttributeError):
                    pass
                return self._error(502 if exc.code >= 500 else exc.code,
                                   f"LiteLLM: {str(detail)[:500]}")
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                return self._error(502, f"LiteLLM unreachable: {getattr(exc, 'reason', exc)}")

            extra = {out: resp.headers[src] for src, out in FORWARDED_LITELLM_HEADERS.items()
                     if resp.headers.get(src)}
            with resp:
                if not clean["stream"]:
                    return self._send(200, resp.read(), "application/json; charset=utf-8", extra)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Accel-Buffering", "no")
                for k, v in {**SECURITY_HEADERS, **extra}.items():
                    self.send_header(k, v)
                self.end_headers()
                try:
                    for line in resp:
                        self.wfile.write(line)
                        if line in (b"\n", b"\r\n"):
                            self.wfile.flush()
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass  # browser pressed Stop; closing resp aborts upstream
            return None

    return Handler


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Homelab dashboard: static UI + JSON API over the homelab services.",
        epilog="Settings come from environment variables; see dashboard/README.md.")
    parser.add_argument("--host", default=os.environ.get("DASHBOARD_LISTEN", "0.0.0.0"),
                        help="listen address (default: DASHBOARD_LISTEN or 0.0.0.0)")
    parser.add_argument("--port", type=int, default=int(os.environ.get("DASHBOARD_PORT_INTERNAL", "8080")),
                        help="listen port (default: 8080)")
    parser.add_argument("--check-config", action="store_true",
                        help="validate configuration and exit")
    args = parser.parse_args(argv)

    cfg = Config(dict(os.environ))
    problems = cfg.validate()
    if problems:
        for p in problems:
            print(f"config error: {p}", file=sys.stderr)
        return 2
    if args.check_config:
        print("config ok")
        return 0
    httpd = ThreadingHTTPServer((args.host, args.port), make_handler(cfg))
    httpd.daemon_threads = True
    print(f"homelab-dashboard {VERSION} listening on {args.host}:{args.port}", file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

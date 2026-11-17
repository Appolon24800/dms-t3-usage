#!/usr/bin/env python3
"""Read provider usage limits from the local T3 Code server.

Prints one JSON document on stdout and always exits 0, so the DMS widget can
show T3's state (closed, refused, ...) instead of a bare exit code.

How it reads T3 Code:
  1. ~/.t3/userdata/server-runtime.json names the loopback host/port and pid.
  2. `t3 auth session issue --scope orchestration:read` mints a short-lived,
     read-only bearer token. It is cached (0600) under $XDG_RUNTIME_DIR and
     reissued shortly before it expires; the replaced session is revoked.
  3. A WebSocket RPC call to `server.getConfig` returns every provider with
     its `usageLimits.windows` (the same data as T3's Usage -> Limits page).

Standard library only: the WebSocket client below is the minimum needed for
one request/response on loopback.
"""

from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

PROTOCOL = 2
# Long enough that a T3 Code update waiting for a restart (when the new `t3`
# CLI refuses to touch the old server's database) rarely blocks a reissue.
TOKEN_TTL = "12h"
TOKEN_LABEL = "dms-t3-usage"
REISSUE_BEFORE_EXPIRY_S = 5 * 60
NET_TIMEOUT_S = 8
CLI_TIMEOUT_S = 15
MAX_FRAME = 16 * 1024 * 1024
LOOPBACK = {"127.0.0.1", "localhost", "::1"}

HOME = Path(os.environ.get("HOME", str(Path.home())))
T3_HOME = Path(os.environ.get("T3CODE_HOME") or HOME / ".t3")
RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/dms-t3-usage-{os.getuid()}") / "dms-t3-usage"
TOKEN_FILE = RUNTIME_DIR / "token.json"
LOCK_FILE = RUNTIME_DIR / "token.lock"

# Friendly names for T3's provider drivers; unknown drivers fall back to a
# title-cased driver id.
DRIVER_NAMES = {
    "claudeAgent": "Claude",
    "claude": "Claude",
    "codex": "Codex",
    "grok": "Grok",
    "opencode": "OpenCode",
    "cursor": "Cursor",
    "gemini": "Gemini",
    "kiro": "Kiro",
    "copilot": "Copilot",
    "amp": "Amp",
}


class T3Error(Exception):
    def __init__(self, state: str, message: str):
        super().__init__(message)
        self.state = state


class HttpStatus(Exception):
    def __init__(self, status: int):
        super().__init__(f"HTTP {status}")
        self.status = status


# --------------------------------------------------------------------------
# Server discovery


def find_server() -> dict:
    path = T3_HOME / "userdata" / "server-runtime.json"
    try:
        info = json.loads(path.read_text())
    except FileNotFoundError:
        raise T3Error("closed", "T3 Code is not running")
    except (OSError, ValueError):
        raise T3Error("closed", "T3 Code's runtime file is unreadable")
    pid, host, port = info.get("pid"), info.get("host", "127.0.0.1"), info.get("port")
    if not isinstance(pid, int) or not isinstance(port, int) or host not in LOOPBACK:
        raise T3Error("closed", "T3 Code's runtime file names no local server")
    if not is_t3_process(pid):
        raise T3Error("closed", "T3 Code is not running")
    return {"host": "127.0.0.1" if host == "localhost" else host, "port": port, "version": str(info.get("serverVersion") or "")}


def is_t3_process(pid: int) -> bool:
    # A stale runtime file can name a pid reused by another program, which
    # must never be sent the token.
    try:
        comm = Path(f"/proc/{pid}/comm").read_text().strip()
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
    except OSError:
        return False
    return comm == "t3" or "t3code" in comm or any(b"t3code" in arg for arg in cmdline)


# --------------------------------------------------------------------------
# Token handling


def t3_binary() -> str:
    found = shutil.which("t3")
    if found:
        return found
    for candidate in (HOME / ".local/bin/t3", T3_HOME / "bin/t3"):
        if candidate.exists():
            return str(candidate)
    raise T3Error("error", "the t3 command was not found (expected on PATH or ~/.local/bin/t3)")


def run_t3(args: list[str]) -> str:
    proc = subprocess.run(
        [t3_binary(), *args],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT_S,
    )
    if proc.returncode != 0:
        output = (proc.stderr or proc.stdout or "").strip()
        if "ServerOwnsDatabaseError" in output or "Use the `t3` that matches the running server" in output:
            raise T3Error("restart", "T3 Code was updated in the background. Restart T3 Code to finish the update.")
        lines = [line.strip() for line in output.splitlines() if line.strip() and not line.strip().startswith("at ")]
        raise T3Error("error", "t3 " + " ".join(args[:3]) + " failed" + (": " + lines[0][:200] if lines else ""))
    return proc.stdout


def parse_instant(value) -> float | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def read_cached_token() -> dict | None:
    try:
        data = json.loads(TOKEN_FILE.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not data.get("token") or not data.get("sessionId"):
        return None
    expires = parse_instant(data.get("expiresAt"))
    if expires is None or expires - time.time() <= REISSUE_BEFORE_EXPIRY_S:
        return None
    return data


def write_cached_token(data: dict) -> None:
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = TOKEN_FILE.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh)
    os.replace(tmp, TOKEN_FILE)


def revoke_in_background(session_id: str) -> None:
    try:
        subprocess.Popen(
            ["timeout", str(CLI_TIMEOUT_S), t3_binary(), "auth", "session", "revoke", "--base-dir", str(T3_HOME), session_id],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        pass


def issue_token(previous: dict | None) -> dict:
    out = run_t3([
        "auth", "session", "issue",
        "--base-dir", str(T3_HOME),
        "--scope", "orchestration:read",
        "--ttl", TOKEN_TTL,
        "--label", TOKEN_LABEL,
        "--json",
    ])
    try:
        data = json.loads(out)
    except ValueError:
        raise T3Error("error", "t3 printed a token that is not JSON")
    if not isinstance(data, dict) or not data.get("token") or not data.get("sessionId"):
        raise T3Error("error", "t3 did not issue a token")
    token = {"token": data["token"], "sessionId": data["sessionId"], "expiresAt": data.get("expiresAt")}
    write_cached_token(token)
    if previous and previous.get("sessionId") and previous["sessionId"] != token["sessionId"]:
        revoke_in_background(previous["sessionId"])
    return token


def previous_token() -> dict | None:
    try:
        data = json.loads(TOKEN_FILE.read_text())
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


# --------------------------------------------------------------------------
# Minimal WebSocket client (RFC 6455), loopback only


class WebSocket:
    def __init__(self, host: str, port: int, path: str, headers: dict[str, str]):
        self.sock = socket.create_connection((host, port), timeout=NET_TIMEOUT_S)
        self.buf = b""
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            f"GET {path} HTTP/1.1",
            f"Host: {host}:{port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
            *[f"{k}: {v}" for k, v in headers.items()],
            "",
            "",
        ]
        self.sock.sendall("\r\n".join(lines).encode())
        while b"\r\n\r\n" not in self.buf:
            self._fill()
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        status_line = head.split(b"\r\n", 1)[0].decode("latin-1")
        try:
            status = int(status_line.split(" ")[1])
        except (IndexError, ValueError):
            raise T3Error("error", "T3 Code answered with a malformed handshake")
        if status != 101:
            raise HttpStatus(status)
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        if expected not in head:
            raise T3Error("error", "T3 Code answered with a bad WebSocket accept key")

    def _fill(self) -> None:
        chunk = self.sock.recv(65536)
        if not chunk:
            raise T3Error("error", "T3 Code closed the connection")
        self.buf += chunk

    def _take(self, n: int) -> bytes:
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        header = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack("!H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack("!Q", n)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def send_text(self, text: str) -> None:
        self._send_frame(0x1, text.encode())

    def recv_text(self) -> str:
        message = b""
        while True:
            b0, b1 = self._take(2)
            fin, opcode = b0 & 0x80, b0 & 0x0F
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._take(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._take(8))[0]
            if n > MAX_FRAME or len(message) + n > MAX_FRAME:
                raise T3Error("error", "T3 Code sent a reply too large to read")
            mask = self._take(4) if b1 & 0x80 else None
            payload = self._take(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                raise T3Error("error", "T3 Code closed the connection")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            message += payload
            if fin:
                return message.decode("utf-8", "replace")

    def close(self) -> None:
        try:
            self._send_frame(0x8, struct.pack("!H", 1000))
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


def rpc(server: dict, token: str, tag: str, payload: dict | None = None):
    ws = WebSocket(
        server["host"],
        server["port"],
        f"/ws?orchestrationProtocol={PROTOCOL}",
        {"Authorization": f"Bearer {token}"},
    )
    try:
        ws.send_text(json.dumps({"_tag": "Request", "id": "1", "tag": tag, "payload": payload or {}, "headers": []}))
        deadline = time.monotonic() + NET_TIMEOUT_S
        while time.monotonic() < deadline:
            try:
                frame = json.loads(ws.recv_text())
            except ValueError:
                raise T3Error("error", "T3 Code sent a frame that is not JSON")
            if not isinstance(frame, dict):
                continue
            kind = frame.get("_tag")
            if kind == "Ping":
                ws.send_text(json.dumps({"_tag": "Pong"}))
            elif kind == "Defect":
                raise T3Error("error", f"T3 Code ended {tag} with a defect")
            elif kind == "Exit" and str(frame.get("requestId")) == "1":
                exit_ = frame.get("exit") or {}
                if exit_.get("_tag") == "Success":
                    return exit_.get("value")
                raise T3Error("error", f"T3 Code answered {tag} with {failure_tag(exit_)}")
        raise T3Error("error", "T3 Code did not answer in time")
    finally:
        ws.close()


def failure_tag(exit_: dict) -> str:
    cause = exit_.get("cause")
    first = cause[0] if isinstance(cause, list) and cause else cause
    if isinstance(first, dict):
        err = first.get("error")
        tag = err.get("_tag") if isinstance(err, dict) else first.get("_tag")
        if isinstance(tag, str) and tag.isalnum() and len(tag) < 64:
            return tag
    return "a failure"


def token_lock():
    """Serialises token issuance between widget instances (one per bar/screen)."""
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def unlock(fd: int) -> None:
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)


def get_config(server: dict):
    lock = token_lock()
    try:
        cached = read_cached_token()
        token = cached or issue_token(previous_token())
    finally:
        unlock(lock)
    try:
        return rpc(server, token["token"], "server.getConfig")
    except HttpStatus as exc:
        if exc.status == 426:
            raise T3Error("unsupported", f"T3 Code {server['version'] or ''} speaks a newer protocol than this plugin".replace("  ", " "))
        if exc.status != 401 or cached is None:
            raise T3Error("refused" if exc.status == 401 else "error", f"T3 Code refused the connection ({exc})")
    # The cached token expired or was revoked: issue one fresh token, once,
    # unless another instance already replaced it meanwhile.
    lock = token_lock()
    try:
        fresh = read_cached_token()
        token = fresh if fresh and fresh["token"] != token["token"] else issue_token(token)
    finally:
        unlock(lock)
    try:
        return rpc(server, token["token"], "server.getConfig")
    except HttpStatus as exc:
        raise T3Error("refused" if exc.status == 401 else "error", f"T3 Code refused a fresh token ({exc})")


# --------------------------------------------------------------------------
# Shape the reply for the widget


def provider_name(provider: dict) -> str:
    for key in ("displayName", "name", "label"):
        value = provider.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    driver = str(provider.get("driver") or provider.get("instanceId") or "?")
    return DRIVER_NAMES.get(driver, driver[:1].upper() + driver[1:])


def shape(config) -> list[dict]:
    providers = config.get("providers") if isinstance(config, dict) else None
    if not isinstance(providers, list):
        raise T3Error("error", "T3 Code's config has no providers list")
    out = []
    for p in providers:
        if not isinstance(p, dict) or p.get("enabled") is False:
            continue
        limits = p.get("usageLimits")
        if not isinstance(limits, dict):
            continue
        windows = []
        for w in limits.get("windows") or []:
            if not isinstance(w, dict) or not isinstance(w.get("usedPercent"), (int, float)):
                continue
            windows.append({
                "id": str(w.get("id") or ""),
                "kind": str(w.get("kind") or ""),
                "label": str(w.get("label") or w.get("id") or "Limit").strip()[:40],
                "usedPercent": max(0.0, min(100.0, float(w["usedPercent"]))),
                "resetsAt": w.get("resetsAt") if isinstance(w.get("resetsAt"), str) else None,
                "windowDurationMins": w.get("windowDurationMins") if isinstance(w.get("windowDurationMins"), int) else None,
            })
        unavailable = limits.get("unavailable")
        reason, reason_message = None, ""
        if isinstance(unavailable, dict):
            reason = str(unavailable.get("reason") or "unavailable")
            reason_message = str(unavailable.get("message") or "")[:200]
        # "unsupported" means this account has no limits to report (API keys,
        # custom endpoints, ...): nothing to show, so leave it out.
        if not windows and reason in (None, "unsupported"):
            continue
        auth = p.get("auth") if isinstance(p.get("auth"), dict) else {}
        out.append({
            "id": str(p.get("instanceId") or p.get("driver") or ""),
            "driver": str(p.get("driver") or ""),
            "name": provider_name(p),
            "status": str(p.get("status") or ""),
            "auth": str(auth.get("status") or ""),
            # auth.type is the plan name ("Claude Pro"); auth.email is never read.
            "plan": str(auth.get("type") or "")[:40],
            "checkedAt": limits.get("checkedAt") if isinstance(limits.get("checkedAt"), str) else None,
            "unavailable": reason,
            "unavailableMessage": reason_message,
            "windows": windows,
        })
    return out


def main(argv: list[str]) -> int:
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    doc: dict = {"ok": False, "state": "error", "message": "", "serverVersion": "", "fetchedAt": now, "providers": []}
    try:
        server = find_server()
        doc["serverVersion"] = server["version"]
        config = get_config(server)
        if "--raw" in argv:
            json.dump(config, sys.stdout, indent=2)
            print()
            return 0
        doc["providers"] = shape(config)
        doc["ok"] = True
        doc["state"] = "ok"
    except T3Error as exc:
        doc["state"] = exc.state
        doc["message"] = str(exc)
    except (OSError, subprocess.SubprocessError) as exc:
        doc["message"] = f"could not reach T3 Code: {exc.__class__.__name__}: {exc}"
    json.dump(doc, sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Minimal web admin UI for the Cubic Odyssey dedicated server container.

Standard library only - no pip packages, no extra runtime dependencies. The
container gets a small HTTP/JSON API (plus a static page served from
webui_index.html) that can report status, list/create/restore backups, edit
server_config.txt, tail the container log and restart the container.

Environment:
  PERSISTENT_DATA  save/backup root       (default /home/cubic/persistent_data)
  SERVER_FILES     server install root     (default /home/cubic/server_files)
  WEBUI_TOKEN      bearer token, REQUIRED  (no default - refuses to start)
  WEBUI_PORT       listen port             (default 8080)
  WEBUI_BIND       bind address            (default 0.0.0.0)
  BACKUP_SH        path to backup.sh       (default <dir of this file>/backup.sh)
  CONTAINER_LOG    log file to tail        (default PERSISTENT_DATA/logs/container.log)

Every path below /api/ needs 'Authorization: Bearer <token>'. '/' and
'/index.html' are unauthenticated and serve the static page.
"""

import glob
import hmac
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))

PERSISTENT_DATA = os.environ.get("PERSISTENT_DATA") or "/home/cubic/persistent_data"
SERVER_FILES = os.environ.get("SERVER_FILES") or "/home/cubic/server_files"
WEBUI_TOKEN = os.environ.get("WEBUI_TOKEN") or ""
WEBUI_PORT = int(os.environ.get("WEBUI_PORT") or "8080")
WEBUI_BIND = os.environ.get("WEBUI_BIND") or "0.0.0.0"
BACKUP_SH = os.environ.get("BACKUP_SH") or os.path.join(HERE, "backup.sh")
CONTAINER_LOG = os.environ.get("CONTAINER_LOG") or os.path.join(
    PERSISTENT_DATA, "logs", "container.log"
)
INDEX_HTML = os.path.join(HERE, "webui_index.html")

APP_NAME = "Cubic Odyssey"
GAME_DIR = os.path.join(SERVER_FILES, "save_server")
SCHEDULER_LOG = os.environ.get("SCHEDULER_LOG") or os.path.join(
    PERSISTENT_DATA, "cubic_scheduler.log"
)

BACKUP_DIR = os.path.join(PERSISTENT_DATA, "backup")
BACKUP_GLOB = os.path.join(BACKUP_DIR, "cubic_backup-*.tar.gz")
# A backup name is a plain archive name: prefix, timestamp-ish characters and
# the .tar.gz suffix. No slashes, no '..', no directory at all - the restore
# endpoint only ever accepts this shape.
BACKUP_NAME_RE = re.compile(r"cubic_backup-[0-9A-Za-z_.-]+\.tar\.gz\Z")
CONFIG_PATH = os.path.join(SERVER_FILES, "config", "server_config.txt")

BACKUP_TIMEOUT = 600
DEFAULT_LOG_LINES = 200
MAX_LOG_LINES = 2000
PROC_PATTERNS = ("CubicOdysseyServer.exe", "wineserver")


# --- helpers ----------------------------------------------------------------


def env_flag(name, default=False):
    """Read a 'true'/'false' style environment flag."""
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def to_int(value, default):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def read_text(path):
    try:
        with open(path, "r", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def image_version():
    """Image version stamped by the Dockerfile, 'dev' for a working copy."""
    for candidate in (
        os.environ.get("VERSION_FILE") or "",
        "./scripts/VERSION",
        os.path.join(HERE, "VERSION"),
    ):
        if candidate and os.path.isfile(candidate):
            text = read_text(candidate).strip()
            if text:
                return text
    return "dev"


def human_duration(seconds):
    """Seconds -> '3d 04:05:06' (None when unknown)."""
    if seconds is None:
        return None
    days, rest = divmod(int(seconds), 86400)
    hours, rest = divmod(rest, 3600)
    minutes, secs = divmod(rest, 60)
    if days:
        return "%dd %02d:%02d:%02d" % (days, hours, minutes, secs)
    return "%02d:%02d:%02d" % (hours, minutes, secs)


def container_uptime_seconds():
    """Age of PID 1 (the container) in seconds.

    Field 22 of /proc/1/stat is the start time in clock ticks since boot; with
    the 'btime' line of /proc/stat that becomes a wall-clock start time.
    """
    try:
        with open("/proc/1/stat", "r") as handle:
            stat = handle.read()
    except OSError:
        return None
    # Field 2 (comm) is parenthesised and may contain spaces: parse after the
    # last ')'. Field 22 is then index 19 of the remainder.
    tail = stat.rpartition(")")[2].split()
    try:
        start_ticks = int(tail[19])
    except (IndexError, ValueError):
        return None
    try:
        clk = os.sysconf("SC_CLK_TCK")
    except (ValueError, OSError):
        clk = 100
    boot_time = None
    try:
        with open("/proc/stat", "r") as handle:
            for line in handle:
                if line.startswith("btime "):
                    boot_time = int(line.split()[1])
                    break
    except (OSError, ValueError, IndexError):
        return None
    if boot_time is None or clk <= 0:
        return None
    uptime = time.time() - (boot_time + start_ticks / float(clk))
    return int(uptime) if uptime > 0 else None


def backup_files():
    """Existing archives as (path, name, bytes, mtime), oldest first."""
    entries = []
    for path in glob.glob(BACKUP_GLOB):
        try:
            st = os.stat(path)
        except OSError:
            continue
        if not os.path.isfile(path):
            continue
        # (mtime, bytes, path) sorted oldest first
        entries.append((st.st_mtime, st.st_size, path))
    entries.sort()
    return [
        (path, os.path.basename(path), size, mtime) for mtime, size, path in entries
    ]


def server_pids():
    """Pids matching the game server binary or wine's wineserver.

    Scans /proc directly: the steamcmd base image ships no procps, so pgrep
    is unavailable and a shell-out would silently report 'not running'.
    """
    pids = set()
    try:
        entries = os.listdir("/proc")
    except OSError:
        return []
    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid == os.getpid():
            continue
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as handle:
                cmdline = handle.read().replace(b"\0", b" ").decode("utf-8", "replace")
        except OSError:
            continue
        if any(pattern in cmdline for pattern in PROC_PATTERNS):
            pids.add(pid)
    return sorted(pids)


def tail_lines(path, count):
    """Last `count` lines of a file; [] when the file is missing/unreadable."""
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            pos = handle.tell()
            data = b""
            block = 64 * 1024
            while pos > 0 and data.count(b"\n") <= count:
                read = min(block, pos)
                pos -= read
                handle.seek(pos)
                data = handle.read(read) + data
    except OSError:
        return []
    lines = data.decode("utf-8", "replace").splitlines()
    if count and len(lines) > count:
        lines = lines[-count:]
    return lines


def disk_info(path):
    """{'free_bytes': .., 'total_bytes': ..} of the filesystem holding `path`."""
    try:
        usage = shutil.disk_usage(path)
        return {"free_bytes": usage.free, "total_bytes": usage.total}
    except OSError:
        return {"free_bytes": 0, "total_bytes": 0}


def run_backup(args, timeout=BACKUP_TIMEOUT):
    """Run backup.sh with the container's environment; returns (returncode, output)."""
    env = dict(os.environ)
    env["PERSISTENT_DATA"] = PERSISTENT_DATA
    env["SERVER_FILES"] = SERVER_FILES
    proc = subprocess.run(
        ["bash", BACKUP_SH] + args,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, output


def bad_config(text):
    """True when `text` is not a plausible server_config.txt body.

    The real file is a JSON-style document wrapped in a 'GameParams' section;
    a body without both markers (empty, truncated, a different file entirely)
    would break the boot, so saving it is refused.
    """
    text = text or ""
    return "GameParams" not in text or "{" not in text


class Handler(BaseHTTPRequestHandler):
    server_version = "CubicOdysseyWebUI/1.0"
    protocol_version = "HTTP/1.1"

    # --- plumbing -----------------------------------------------------------

    def log_message(self, fmt, *args):  # silenced; we log our own request line
        pass

    def _request_path(self):
        try:
            return urlparse(self.path)
        except ValueError:
            return urlparse("/")

    def _respond(self, status, body, content_type="application/json"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        except OSError:
            pass
        self._log_request(status)

    def _log_request(self, status):
        print("%s %s %s" % (self.command, self._request_path().path, status), flush=True)

    def _json(self, status, payload):
        self._respond(status, json.dumps(payload).encode("utf-8"))

    def _error(self, status, message):
        self._json(status, {"error": message})

    def _unauthorized(self):
        self._error(401, "unauthorized")

    def _not_found(self):
        self._error(404, "not found")

    def _authorized(self):
        header = self.headers.get("Authorization") or ""
        if not header.startswith("Bearer "):
            return False
        token = header[len("Bearer "):].strip()
        # Compare as UTF-8 bytes: str-vs-str compare_digest raises TypeError
        # on non-ASCII characters, which would leak as an HTTP 500 instead of
        # a clean 401. Any auth oddity must never be a 5xx.
        try:
            return hmac.compare_digest(token.encode("utf-8"), WEBUI_TOKEN.encode("utf-8"))
        except Exception:
            return False

    def _body_json(self):
        """Parsed JSON request body, or {} when absent/invalid (None on bad JSON)."""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None
        return data

    # --- dispatch -----------------------------------------------------------

    def _handle(self, method):
        try:
            parsed = self._request_path()
            path = parsed.path
            if method == "GET" and path in ("/", "/index.html"):
                return self._serve_index()
            if not path.startswith("/api/"):
                return self._not_found()
            if not self._authorized():
                return self._unauthorized()
            return self._api(method, path, parse_qs(parsed.query))
        except Exception as exc:  # never leak a traceback to the client
            traceback.print_exc()
            try:
                self._error(500, str(exc))
            except Exception:
                pass

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_HEAD(self):
        self._handle("HEAD")

    # --- static -------------------------------------------------------------

    def _serve_index(self):
        try:
            with open(INDEX_HTML, "rb") as handle:
                body = handle.read()
        except OSError:
            return self._respond(
                200, "placeholder", content_type="text/plain; charset=utf-8"
            )
        return self._respond(200, body, content_type="text/html; charset=utf-8")

    # --- API ----------------------------------------------------------------

    def _api(self, method, path, query):
        if method == "GET" and path == "/api/status":
            return self._api_status()
        if method == "GET" and path == "/api/backups":
            return self._api_backups_list()
        if method == "POST" and path == "/api/backups":
            return self._api_backups_create()
        if method == "POST" and path == "/api/backups/restore":
            return self._api_backup_restore()
        if method == "GET" and path == "/api/config":
            return self._api_config_get()
        if method == "PUT" and path == "/api/config":
            return self._api_config_put()
        if method == "GET" and path == "/api/logs":
            return self._api_logs(query)
        if method == "POST" and path == "/api/restart":
            return self._api_restart()
        return self._not_found()

    def _api_status(self):
        pids = server_pids()
        running = bool(pids)
        uptime = container_uptime_seconds()

        count, total_bytes = 0, 0
        for _path, _name, size, _mtime in backup_files():
            count += 1
            total_bytes += size

        self._json(
            200,
            {
                "app": APP_NAME,
                "version": image_version(),
                "running": running,
                "pid": pids[0] if running else None,
                "uptime_seconds": uptime,
                "uptime": human_duration(uptime),
                "server_name": os.environ.get("SERVER_NAME") or "Cubic Odyssey Docker Server",
                "port": to_int(os.environ.get("SERVER_PORT"), 0) or None,
                "game_data_exists": os.path.isdir(GAME_DIR),
                "game_data_dir": GAME_DIR,
                "backups": {"count": count, "total_bytes": total_bytes},
                "disk": {
                    "server_files": disk_info(SERVER_FILES),
                    "persistent_data": disk_info(PERSISTENT_DATA),
                },
            },
        )

    def _api_backups_list(self):
        payload = {
            "backups": [
                {"name": name, "bytes": size, "mtime": int(mtime)}
                for _path, name, size, mtime in backup_files()
            ]
        }
        # The scheduler mirrors its own log onto the volume; expose the tail so
        # the UI can explain when the last backup ran (and why one failed).
        if os.path.isfile(SCHEDULER_LOG):
            payload["scheduler_log"] = tail_lines(SCHEDULER_LOG, DEFAULT_LOG_LINES)
        self._json(200, payload)

    def _api_backups_create(self):
        try:
            code, output = run_backup(["--create"])
        except subprocess.TimeoutExpired:
            return self._error(500, "backup timed out after %ss" % BACKUP_TIMEOUT)
        lines = output.splitlines()[-40:]
        self._json(200, {"ok": code == 0, "output": "\n".join(lines)})

    def _api_backup_restore(self):
        body = self._body_json()
        if not isinstance(body, dict):
            return self._error(400, "invalid JSON body")
        name = body.get("name")
        if not isinstance(name, str) or not BACKUP_NAME_RE.match(name):
            return self._error(400, "invalid backup name")
        # Deferred restore: hand the archive name to backup.sh, which records it
        # as pending and applies it during the next boot (start.sh runs
        # 'backup.sh --apply-pending'). The server never untars in-process.
        try:
            code, output = run_backup(["--restore", name])
        except subprocess.TimeoutExpired:
            return self._error(500, "restore timed out after %ss" % BACKUP_TIMEOUT)
        lines = output.splitlines()
        last_line = lines[-1] if lines else ""
        self._json(200, {"ok": code == 0, "output_last_line": last_line})

    def _api_config_get(self):
        self._json(200, {"text": read_text(CONFIG_PATH)})

    def _api_config_put(self):
        body = self._body_json()
        if not isinstance(body, dict) or not isinstance(body.get("text"), str):
            return self._error(400, "expected JSON body {text: ...}")
        text = body["text"]
        if bad_config(text):
            return self._error(
                400, "config must contain a GameParams section and a '{'"
            )
        if os.path.isfile(CONFIG_PATH):
            try:
                shutil.copy2(CONFIG_PATH, CONFIG_PATH + ".bak")
            except OSError as exc:
                return self._error(500, "could not back up config: %s" % exc)
        directory = os.path.dirname(CONFIG_PATH)
        tmp_path = CONFIG_PATH + ".tmp"
        try:
            os.makedirs(directory, exist_ok=True)
            with open(tmp_path, "w") as handle:
                handle.write(text)
            os.replace(tmp_path, CONFIG_PATH)
        except OSError as exc:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            return self._error(500, "could not write config: %s" % exc)
        self._json(200, {"ok": True})

    def _api_logs(self, query):
        raw = (query.get("lines") or [str(DEFAULT_LOG_LINES)])[0]
        count = to_int(raw, DEFAULT_LOG_LINES)
        if count < 1:
            count = 1
        if count > MAX_LOG_LINES:
            count = MAX_LOG_LINES
        self._json(200, {"lines": tail_lines(CONTAINER_LOG, count)})

    def _api_restart(self):
        self._json(200, {"ok": True, "note": "container restarting"})

        def _signal_init():
            try:
                os.kill(1, 15)
            except OSError as exc:
                print(
                    "restart: could not signal PID 1: %s" % exc, file=sys.stderr, flush=True
                )

        timer = threading.Timer(0.5, _signal_init)
        timer.daemon = True
        timer.start()


def main():
    if not WEBUI_TOKEN:
        print(
            "WEBUI enabled but WEBUI_TOKEN is not set - refusing to start",
            file=sys.stderr,
        )
        raise SystemExit(1)
    server = ThreadingHTTPServer((WEBUI_BIND, WEBUI_PORT), Handler)
    server.daemon_threads = True
    print(
        "web UI listening on %s:%s (pid %s, %s)"
        % (WEBUI_BIND, WEBUI_PORT, os.getpid(), time.strftime("%Y-%m-%d %H:%M:%S")),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

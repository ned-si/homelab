"""apps/theater/qbittorrent-private.yaml: the private-seed script against a fake qBittorrent WebUI.

The script is taken from the ConfigMap with yq and pointed at a local server.
Each test reproduces a bug that reached main and names its pull request.
"""
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time

import pytest

from conftest import REPO

MANIFEST = REPO / "apps/theater/qbittorrent-private.yaml"
ROOT_LINE = 'ROOT = "http://qbittorrent.theater.svc.cluster.local:8080"'
WEBUI = {"bypass_auth_subnet_whitelist_enabled": True, "bypass_auth_subnet_whitelist": "10.244.0.0/16",
         "web_ui_reverse_proxy_enabled": False}


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def fake_webui(port, login):
    """A qBittorrent WebUI whose auth/login answers `login` = (status, body)."""
    class Handler(http.server.BaseHTTPRequestHandler):
        def reply(self, status, body=b"", ctype="text/plain"):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            if self.path == "/api/v2/auth/login" and status in (200, 204):
                self.send_header("Set-Cookie", "SID=fake; path=/")
            self.end_headers()
            if body and status != 204:
                self.wfile.write(body)

        def do_GET(self):
            if self.path == "/":
                self.reply(200, b"<html></html>", "text/html")
            elif self.path == "/api/v2/app/preferences":
                self.reply(200, json.dumps(WEBUI).encode(), "application/json")
            elif self.path == "/api/v2/torrents/info":
                self.reply(200, b"[]", "application/json")
            else:
                self.reply(404)

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if self.path == "/api/v2/auth/login":
                self.reply(login[0], login[1].encode())
            elif self.path == "/api/v2/torrents/createCategory":
                self.reply(200)
            else:
                self.reply(404)

        def log_message(self, *args):
            pass

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


@pytest.fixture
def script(tmp_path):
    def make(port):
        src = subprocess.run(["yq", '.data["private-seed.py"] | select(. != null)', str(MANIFEST)],
                             capture_output=True, text=True, check=True).stdout
        assert ROOT_LINE in src and "time.sleep(10)" in src
        src = src.replace(ROOT_LINE, f'ROOT = "http://127.0.0.1:{port}"').replace("time.sleep(10)", "time.sleep(0.2)")
        path = tmp_path / "private-seed.py"
        path.write_text(src)
        return path
    return make


def run(path):
    env = dict(os.environ, QBITTORRENT_USER="seed", QBITTORRENT_PASS="x")
    return subprocess.run([sys.executable, str(path)], capture_output=True, text=True, env=env, timeout=60)


@pytest.mark.parametrize("login, ok", [
    ((204, ""), True),        # qBittorrent 5.2 (#443)
    ((200, "Ok."), True),     # before 5.2
    ((200, "Fails."), False),
    ((403, ""), False),
])
def test_login_reply_443(script, login, ok):
    # #443: qBittorrent 5.2 answers 204 with the session cookie; the job read it as a failed login.
    port = free_port()
    srv = fake_webui(port, login)
    try:
        r = run(script(port))
    finally:
        srv.shutdown()
    assert (r.returncode == 0) is ok, r.stdout + r.stderr
    if ok:
        assert "category private ok" in r.stdout


def test_waits_for_a_restarting_webui_1155(script):
    # #1155: during a qBittorrent restart the Service had no endpoint; the login got
    # "connection refused", the Job failed and the CronJob went Degraded.
    port = free_port()
    proc = subprocess.Popen([sys.executable, str(script(port))], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, env=dict(os.environ, QBITTORRENT_USER="seed", QBITTORRENT_PASS="x"))
    time.sleep(1)
    srv = fake_webui(port, (204, ""))
    try:
        out, err = proc.communicate(timeout=60)
    finally:
        srv.shutdown()
    assert proc.returncode == 0, out + err
    assert "waiting for qBittorrent" in out

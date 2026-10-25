#!/usr/bin/env python3
"""磁盘写入量实时面板 —— 本地小服务。

每 0.5 秒读一次 smartctl 的累计写入计数，算出瞬时写入速率，
通过本地 HTTP 提供给 index.html 显示。数据不出本机。
"""

import json
import os
import re
import subprocess
import sys
import threading
import time
import webbrowser
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_DIR = os.path.dirname(os.path.abspath(__file__))
SMARTCTL = os.environ.get("SMARTCTL", "/usr/local/sbin/smartctl")
DEVICE = os.environ.get("DEVICE", "/dev/disk0")
START_PORT = int(os.environ.get("PORT", "8765"))
UNIT_BYTES = 512000          # NVMe: 1 Data Unit = 1000 × 512 B
INTERVAL = 1.0               # 采样间隔（秒）

for arg in sys.argv[1:]:
    if arg.startswith("/dev/"):
        DEVICE = arg

OPEN_BROWSER = "--no-open" not in sys.argv

RE_MODEL = re.compile(r"^\s*Model Number:\s+(.+?)\s*$", re.M)
RE_UNITS = re.compile(r"^\s*Data Units Written:\s+([\d,]+)", re.M)
RE_TEMP = re.compile(r"^\s*Temperature:\s+(\d+)", re.M)
RE_USED = re.compile(r"^\s*Percentage Used:\s+(\d+)", re.M)
RE_MEDIA = re.compile(r"^\s*Media and Data Integrity Errors:\s+(\d+)", re.M)


class Monitor:
    def __init__(self):
        self.lock = threading.Lock()
        self.history = deque(maxlen=900)      # 15 分钟 @1s
        self.model = ""
        self.prev_units = None
        self.prev_ts = None
        self.first_units = None
        self.peak = 0.0
        self.error = None
        self.rate = 0.0
        self.total_gb = 0.0
        self.session_gb = 0.0
        self.temp = None
        self.used = None
        self.media = None
        self.updated = 0.0

    def _read(self):
        proc = subprocess.run(
            [SMARTCTL, "-x", DEVICE],
            capture_output=True, text=True, timeout=15,
        )
        out = proc.stdout or ""
        m = RE_UNITS.search(out)
        if not m:
            tail = (proc.stderr or "").strip() or "未返回 Data Units Written"
            raise RuntimeError(tail.splitlines()[0][:160])
        units = int(m.group(1).replace(",", ""))
        model = RE_MODEL.search(out)
        temp = RE_TEMP.search(out)
        used = RE_USED.search(out)
        media = RE_MEDIA.search(out)
        return (
            units,
            model.group(1) if model else "",
            int(temp.group(1)) if temp else None,
            int(used.group(1)) if used else None,
            int(media.group(1)) if media else None,
        )

    def sample_once(self):
        now = time.time()
        try:
            units, model, temp, used, media = self._read()
        except Exception as exc:              # noqa: BLE001
            with self.lock:
                self.error = str(exc)
            return

        with self.lock:
            self.error = None
            self.model = model or self.model
            if self.first_units is None:
                self.first_units = units
            if self.prev_units is not None:
                delta = max(0, units - self.prev_units)
                dt = max(0.2, now - self.prev_ts)
                self.rate = delta * UNIT_BYTES / 1e6 / dt
                self.peak = max(self.peak, self.rate)
                self.history.append([int(now * 1000), round(self.rate, 3)])
            else:
                self.history.append([int(now * 1000), 0.0])
            self.prev_units = units
            self.prev_ts = now
            self.total_gb = units * UNIT_BYTES / 1e9
            self.session_gb = (units - self.first_units) * UNIT_BYTES / 1e9
            self.temp = temp
            self.used = used
            self.media = media
            self.updated = now

    def snapshot(self):
        with self.lock:
            return {
                "ok": self.error is None,
                "error": self.error,
                "device": DEVICE,
                "model": self.model,
                "rate": round(self.rate, 2),
                "peak": round(self.peak, 2),
                "totalGb": round(self.total_gb, 1),
                "sessionGb": round(self.session_gb, 3),
                "temp": self.temp,
                "used": self.used,
                "media": self.media,
                "interval": INTERVAL,
                "updated": int(self.updated * 1000),
                "history": list(self.history),
            }


MONITOR = Monitor()


def sampler():
    while True:
        MONITOR.sample_once()
        time.sleep(INTERVAL)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _send(self, code, body, ctype):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            try:
                with open(os.path.join(APP_DIR, "index.html"), encoding="utf-8") as fh:
                    self._send(200, fh.read(), "text/html; charset=utf-8")
            except OSError:
                self._send(500, "index.html missing", "text/plain; charset=utf-8")
        elif path == "/api/data":
            self._send(
                200,
                json.dumps(MONITOR.snapshot(), ensure_ascii=False),
                "application/json; charset=utf-8",
            )
        else:
            self._send(404, "not found", "text/plain; charset=utf-8")


def main():
    threading.Thread(target=sampler, daemon=True).start()
    port = START_PORT
    for _ in range(20):
        try:
            httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
            break
        except OSError:
            port += 1
    else:
        print("端口都被占用了，换一个 PORT 环境变量再试。")
        sys.exit(1)

    httpd.daemon_threads = True
    url = f"http://127.0.0.1:{port}/"
    print()
    print(f"  磁盘写入量面板已启动：{url}")
    print(f"  设备：{DEVICE}")
    print("  关闭这个窗口（或按 Control+C）即可停止。")
    print()
    if OPEN_BROWSER:
        threading.Timer(0.8, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()

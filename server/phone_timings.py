#!/usr/bin/env python3
"""Takes the iPhone app's playback timings over the tailnet, for reading on
the host: how late the highlight and taps were, frames dropped, the audio
route. Numbers only; a report with text in a field it should not have is
refused, so no caption, title or address can land here.

Runs on its own, since the phone plays with the Mac app and the GPU server
off. Bound to the tailnet address only. The file keeps the last reports:

    python3 phone_timings.py [--host ADDRESS] [--port 8773] [--file PATH]
"""

import argparse
import json
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 4096
KEEP = 2000

NUMBERS = {
    "seconds", "frames", "hitches", "worst_frame_ms", "highlights", "highlight_late_median_ms",
    "highlight_late_max_ms", "taps", "tap_median_ms", "tap_max_ms", "audio_latency_ms",
}
WORDS = {"build": 64, "route": 32, "thermal": 16}
FLAGS = {"low_power"}


def valid(report):
    """Only the fields the app sends, each of its kind and short."""
    if not isinstance(report, dict) or not report or not set(report) <= NUMBERS | set(WORDS) | FLAGS:
        return False
    for key, value in report.items():
        if key in NUMBERS and (isinstance(value, bool) or not isinstance(value, (int, float))):
            return False
        if key in WORDS and not (isinstance(value, str) and len(value) <= WORDS[key]):
            return False
        if key in FLAGS and not isinstance(value, bool):
            return False
    return True


def append(path, report):
    """One line a report, the newest last, the oldest dropped past KEEP."""
    lines = path.read_text().splitlines() if path.exists() else []
    lines.append(json.dumps({"received": round(time.time()), **report}))
    temporary = path.with_suffix(".tmp")
    temporary.write_text("\n".join(lines[-KEEP:]) + "\n")
    temporary.replace(path)


def handler(path):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            if self.path != "/timings" or not 0 < length <= MAX_BODY:
                return self.answer(400)
            try:
                report = json.loads(self.rfile.read(length))
            except ValueError:
                return self.answer(400)
            if not valid(report):
                return self.answer(400)
            append(path, report)
            self.answer(204)

        def answer(self, status):
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *args):
            pass

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host")
    parser.add_argument("--port", type=int, default=8773)
    parser.add_argument("--file", type=Path, default=Path.home() / "livetrans" / "phone-timings.jsonl")
    args = parser.parse_args()
    host = args.host or subprocess.check_output(["tailscale", "ip", "-4"], text=True).split()[0]
    ThreadingHTTPServer((host, args.port), handler(args.file)).serve_forever()


if __name__ == "__main__":
    main()

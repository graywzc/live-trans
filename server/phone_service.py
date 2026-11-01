#!/usr/bin/env python3
"""What the iPhone and Mac apps need of the host with the GPU server off.

POST /timings      the phone's playback timings, for reading on the host: how
                   late the highlight and taps were, frames dropped, the audio
                   route. Numbers only; a report with text in a field it should
                   not have is refused, so no caption, title or address can
                   land here. The file keeps the last reports.
GET /picks/<video> -> {"picks": {"<ms>": "nemo", ...}}
                   the recognizer picked per caption of a video kept in the dev
                   cache, by where the caption starts in milliseconds. This is
                   the one record of them; both apps read it and write to it.
POST /picks/<video>  body: {"at": <ms>, "pick": "nemo"}, or null to take a pick
                   back; a change at a time, so that neither app overwrites
                   the other's. Kept in the video's folder as picks.json, gone
                   with it.

Runs on its own, since the phone plays with the Mac app and the GPU server
off. Bound to the tailnet address only:

    python3 phone_service.py [--host ADDRESS] [--port 8773] [--file PATH] [--cache FOLDER]
"""

import argparse
import json
import re
import subprocess
import threading
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

PICKS_FILE = "picks.json"
RECOGNIZERS = {"k2", "nemo", "qwen"}
VIDEO_ID = re.compile(r"[0-9a-f]{16}")
# A caption's place, in milliseconds: past any video's end is a mistake.
MAX_AT = 100 * 3600 * 1000


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


def valid_pick(change):
    """A caption's place and a recognizer's name, or null for none."""
    if not isinstance(change, dict) or set(change) != {"at", "pick"}:
        return False
    at, pick = change["at"], change["pick"]
    return isinstance(at, int) and not isinstance(at, bool) and 0 <= at < MAX_AT and (pick is None or pick in RECOGNIZERS)


def read_picks(folder):
    try:
        picks = json.loads((folder / PICKS_FILE).read_text())
    except (OSError, ValueError):
        return {}
    return picks if isinstance(picks, dict) else {}


def write_pick(folder, at, pick):
    picks = read_picks(folder)
    if pick:
        picks[str(at)] = pick
    else:
        picks.pop(str(at), None)
    temporary = folder / f"{PICKS_FILE}.tmp"
    temporary.write_text(json.dumps(picks))
    temporary.replace(folder / PICKS_FILE)


def handler(path, cache):
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            folder = self.video_folder()
            if folder is None:
                return self.answer(404)
            with lock:
                body = json.dumps({"picks": read_picks(folder)}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= MAX_BODY:
                return self.answer(400)
            try:
                body = json.loads(self.rfile.read(length))
            except ValueError:
                return self.answer(400)
            if self.path == "/timings":
                if not valid(body):
                    return self.answer(400)
                append(path, body)
                return self.answer(204)
            if not self.path.startswith("/picks/"):
                return self.answer(400)
            folder = self.video_folder()
            if folder is None:
                return self.answer(404)
            if not valid_pick(body):
                return self.answer(400)
            with lock:
                write_pick(folder, body["at"], body["pick"])
            self.answer(204)

        def video_folder(self):
            """The folder of the video the path names, which must be one
            the cache holds: nothing here makes a folder."""
            prefix, _, video = self.path.rpartition("/")
            folder = cache / video
            return folder if prefix == "/picks" and VIDEO_ID.fullmatch(video) and folder.is_dir() else None

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
    parser.add_argument("--cache", type=Path, default=Path.home() / "livetrans" / "devcache")
    args = parser.parse_args()
    host = args.host or subprocess.check_output(["tailscale", "ip", "-4"], text=True).split()[0]
    ThreadingHTTPServer((host, args.port), handler(args.file, args.cache)).serve_forever()


if __name__ == "__main__":
    main()

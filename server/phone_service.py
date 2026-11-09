#!/usr/bin/env python3
"""What the iPhone and Mac apps need of the host with the GPU server off.

POST /timings      the phone's playback timings, for reading on the host: how
                   late the highlight and taps were, frames dropped, the audio
                   route. Numbers only; a report with text in a field it should
                   not have is refused, so no caption, title or address can
                   land here. The file keeps the last reports.
GET /picks/<video> -> {"picks": {"<ms>": "nemo", "<ms>": {"ja": "...", "en": "..."}, ...}}
                   the recognizer picked per caption of a video kept in the dev
                   cache, by where the caption starts in milliseconds, or the
                   text typed in place of every recognizer's with its
                   translation ("en" whatever the language, as in a bundle;
                   left out when the translator gave none). This is the one
                   record of them; both apps read it and write to it.
POST /picks/<video>  body: {"at": <ms>, "pick": "nemo"}, {"at": <ms>, "pick":
                   {"ja": "...", "to": "zh"}} for typed text, translated here
                   before it is kept, or null to take a pick back; a change at
                   a time, so that neither app overwrites the other's. Kept in
                   the video's folder as picks.json, gone with it.
POST /translate    body: {"ja": "...", "to": "zh"} -> {"en": "..."}: typed text
                   translated and kept nowhere, for Incognito.

Runs on its own, since the phone plays with the Mac app and the GPU server
off; translates with the host's ollama, as asr_server.py does, and never
writes or prints typed text but into the video's picks. Bound to the
tailnet address only:

    python3 phone_service.py [--host ADDRESS] [--port 8773] [--file PATH] [--cache FOLDER]
"""

import argparse
import json
import re
import subprocess
import os
import threading
import time
import urllib.error
import urllib.request
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
# Longer than any caption anyone would type.
MAX_TYPED = 500

# The translator asr_server.py uses, by the same settings.
OLLAMA_URL = os.getenv("LIVETRANS_OLLAMA_URL", "http://localhost:11434").rstrip("/")
OLLAMA_MODEL = os.getenv("LIVETRANS_OLLAMA_MODEL", "qwen3.5:9b")
# The same as asr_server.py's: one of ollama's own five minutes would cut short
# the model's stay during a session.
OLLAMA_KEEP_ALIVE = os.getenv("LIVETRANS_OLLAMA_KEEP_ALIVE", "30m")
# Loading the model, with the GPU server off, takes a while of its own.
OLLAMA_TIMEOUT = 60
LANGUAGES = {"en": "English", "zh": "Simplified Chinese"}


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


def valid_typed(typed):
    """Japanese typed for a caption, and the language to translate it into."""
    return (isinstance(typed, dict) and set(typed) <= {"ja", "to"} and isinstance(typed.get("ja"), str)
            and 0 < len(typed["ja"].strip()) <= MAX_TYPED and typed.get("to", "zh") in LANGUAGES)


def valid_pick(change):
    """A caption's place and a recognizer's name, typed text, or null for none."""
    if not isinstance(change, dict) or set(change) != {"at", "pick"}:
        return False
    at, pick = change["at"], change["pick"]
    return (isinstance(at, int) and not isinstance(at, bool) and 0 <= at < MAX_AT
            and (pick is None or (isinstance(pick, str) and pick in RECOGNIZERS) or valid_typed(pick)))


def translate(ja, to):
    """`ja` in the language `to`, from ollama; None when it gives none."""
    payload = {
        "model": OLLAMA_MODEL,
        "prompt": f"Translate this Japanese to natural {LANGUAGES[to]}. Output only the translation, nothing else.\n\n"
        + ja,
        "stream": False,
        "keep_alive": OLLAMA_KEEP_ALIVE,
        "think": False,
        "options": {"temperature": 0, "num_predict": 4 * len(ja) + 200},
    }
    request = urllib.request.Request(
        OLLAMA_URL + "/api/generate", data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=OLLAMA_TIMEOUT) as answer:
            return json.load(answer)["response"].strip() or None
    except (OSError, ValueError, KeyError):
        return None


def typed_pick(typed, translator):
    """What is kept of typed text: the text, and its translation when there is one."""
    ja = typed["ja"].strip()
    english = translator(ja, typed.get("to", "zh"))
    return {"ja": ja, "en": english} if english else {"ja": ja}


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


def handler(path, cache, translator=translate):
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            folder = self.video_folder()
            if folder is None:
                return self.answer(404)
            with lock:
                picks = read_picks(folder)
            self.answer_json({"picks": picks})

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
            if self.path == "/translate":
                if not valid_typed(body):
                    return self.answer(400)
                english = translator(body["ja"].strip(), body.get("to", "zh"))
                return self.answer_json({"en": english}) if english else self.answer(502)
            if not self.path.startswith("/picks/"):
                return self.answer(400)
            folder = self.video_folder()
            if folder is None:
                return self.answer(404)
            if not valid_pick(body):
                return self.answer(400)
            pick = body["pick"]
            # Translated before the lock, which a slow translator would hold.
            if isinstance(pick, dict):
                pick = typed_pick(pick, translator)
            with lock:
                write_pick(folder, body["at"], pick)
            self.answer(204)

        def video_folder(self):
            """The folder of the video the path names, which must be one
            the cache holds: nothing here makes a folder."""
            prefix, _, video = self.path.rpartition("/")
            folder = cache / video
            return folder if prefix == "/picks" and VIDEO_ID.fullmatch(video) and folder.is_dir() else None

        def answer_json(self, value):
            body = json.dumps(value).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

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

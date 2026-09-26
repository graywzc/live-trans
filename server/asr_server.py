"""GPU inference server for LiveTrans. Runs on a CUDA host.

The Mac captures audio, segments it with VAD, and POSTs raw PCM here; this
process runs Whisper on the GPU and returns the Japanese text plus its English
translation. Audio never leaves your own machines.

Translation defaults to the host's ollama server (qwen-class LLMs are the only
backend here that translates colloquial speech correctly), falling back to
Whisper's own speech->English task when ollama is unreachable. Set
LIVETRANS_TRANSLATE_BACKEND=whisper to skip ollama entirely, or =nllb to use
the text->text NLLB model instead.

    python asr_server.py --host 0.0.0.0 --port 8765

POST /shutdown     exit now and release the GPU (unloads the ollama model too)
POST /transcribe   body: raw PCM s16le mono 16kHz
                   query: beam_size=3, translate=1, prompt=<text said before>
                   -> {"ja": "...", "en": "...", "rtf": 0.05,
                       "lines": [{"ja": "...", "en": "...",
                                  "start": 0.3, "end": 2.1}, ...]}
                   "lines" is the same text, one sentence per entry, each
                   with where it starts and ends in the audio (seconds)
                   when its words could be placed.
GET /health       -> {"status": "ok", "asr": "...", "device": "cuda"}
"""

import argparse
import json
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

SAMPLE_RATE = 16000
ASR_MODEL = os.getenv("LIVETRANS_ASR_MODEL", "large-v3")
NLLB_DIR = os.getenv("LIVETRANS_NLLB_MODEL", "models/nllb-200-distilled-600M-ct2")
DEVICE = os.getenv("LIVETRANS_DEVICE", "cuda")
COMPUTE_TYPE = os.getenv("LIVETRANS_COMPUTE_TYPE", "float16")
# The NLLB build is int8; int8_float16 runs it natively on the GPU without
# dequantizing to fp16 first.
NLLB_COMPUTE_TYPE = os.getenv("LIVETRANS_NLLB_COMPUTE_TYPE", "int8_float16")
# "ollama" translates the transcript text with an LLM served by ollama;
# "whisper" runs a second Whisper pass over the same audio with task=translate;
# "nllb" translates the transcript text with NLLB.
TRANSLATE_BACKEND = os.getenv("LIVETRANS_TRANSLATE_BACKEND", "ollama").lower()
OLLAMA_URL = os.getenv("LIVETRANS_OLLAMA_URL", "http://localhost:11434").rstrip("/")
OLLAMA_MODEL = os.getenv("LIVETRANS_OLLAMA_MODEL", "qwen3.5:9b")
# ollama's own default unloads after 5 idle minutes; reloading qwen3.5:9b takes
# ~15s, which would stall a caption mid-session after any quiet stretch.
OLLAMA_KEEP_ALIVE = os.getenv("LIVETRANS_OLLAMA_KEEP_ALIVE", "30m")
OLLAMA_TIMEOUT = float(os.getenv("LIVETRANS_OLLAMA_TIMEOUT", "30"))

_OLLAMA_PROMPT = (
    "Translate this Japanese to natural English. "
    "Output only the translation, nothing else.\n\n"
)
# One VAD segment routinely holds several sentences (often several speakers),
# and Whisper frequently emits them with no punctuation at all, so there is
# nothing to split on mechanically. The LLM is translating anyway; have it mark
# the sentence boundaries in the same pass.
_OLLAMA_SPLIT_PROMPT = (
    "Below is a Japanese speech transcript. It may contain several sentences "
    "run together, often without punctuation, possibly from different speakers.\n"
    "Split it into individual sentences and translate each into natural English.\n"
    "Output one sentence per line in exactly this format:\n"
    "<Japanese sentence> ||| <English translation>\n"
    "Copy the Japanese characters exactly as given; do not add, drop, or change "
    "any. Output nothing else.\n\n"
)
_PAIR_SEPARATOR = "|||"
# Ignored when checking the LLM copied the transcript faithfully: it may add or
# drop punctuation at the boundaries it found, which is harmless.
_BOUNDARY_NOISE = set("。、，．,.!?！？…‥ 　\t\n")

_last_request_at = time.time()

_asr = None
_nllb = None
_nllb_tok = None
# Flipped false when ollama proves unreachable so each utterance doesn't pay a
# connection attempt; translation then falls back to the Whisper pass until
# the server is restarted.
_ollama_ok = TRANSLATE_BACKEND == "ollama"
# Whether to send "think": false. qwen-style thinking models need it or they
# burn latency on reasoning tokens; older models reject the field with a 400.
_ollama_supports_think = True
# Whisper and NLLB each hold their own CUDA context; serialize access so
# concurrent requests can't interleave batches on the same model.
_asr_lock = threading.Lock()
_nllb_lock = threading.Lock()

_UNTRANSLATABLE = set("。、，．,.!?！？…‥「」『』（）()[]{}〜ー・~-—♪♬♩* \t\n")


def load_models():
    global _asr, _nllb, _nllb_tok
    from faster_whisper import WhisperModel

    print(f"loading ASR {ASR_MODEL} on {DEVICE}/{COMPUTE_TYPE} ...", flush=True)
    t0 = time.time()
    _asr = WhisperModel(ASR_MODEL, device=DEVICE, compute_type=COMPUTE_TYPE)
    print(f"  ASR ready in {time.time() - t0:.1f}s", flush=True)

    if TRANSLATE_BACKEND == "ollama":
        threading.Thread(target=warm_ollama, daemon=True).start()
        return
    if TRANSLATE_BACKEND != "nllb":
        print("translation: whisper task=translate (NLLB not loaded)", flush=True)
        return

    if os.path.isdir(NLLB_DIR):
        import ctranslate2
        import transformers

        print(f"loading NLLB from {NLLB_DIR} ...", flush=True)
        t0 = time.time()
        _nllb_tok = transformers.AutoTokenizer.from_pretrained(
            NLLB_DIR, src_lang="jpn_Jpan"
        )
        _nllb = ctranslate2.Translator(
            NLLB_DIR, device=DEVICE, compute_type=NLLB_COMPUTE_TYPE
        )
        print(f"  NLLB ready in {time.time() - t0:.1f}s", flush=True)
    else:
        print(f"  NLLB dir {NLLB_DIR} missing - translation disabled", flush=True)


def _is_untranslatable(text):
    """True for segments that are only punctuation/filler markers."""
    stripped = text.strip()
    return not stripped or all(ch in _UNTRANSLATABLE for ch in stripped)


def decode_pcm(pcm_bytes):
    return np.frombuffer(pcm_bytes, dtype=np.int16).astype(np.float32) / 32768.0


def run_whisper(audio, beam_size=3, task="transcribe", prompt=None, words=None):
    """task="transcribe" -> Japanese, task="translate" -> English.

    `prompt` is what was said just before the audio, given to Whisper as
    context: a name or a term it has seen is one it is likelier to hear.

    `words`, a list, is filled with (text, start, end) for every word heard,
    the times in seconds into the audio.

    Returns Whisper's segments as a list. It ends a segment at a pause in the
    speech, so the boundaries are worth keeping: they are the only sign of a
    sentence break or a change of speaker when there is no punctuation.
    """
    if audio.size == 0:
        return []
    with _asr_lock:
        segments, _ = _asr.transcribe(
            audio, language="ja", task=task, beam_size=beam_size, vad_filter=False,
            initial_prompt=prompt or None, word_timestamps=words is not None,
        )
        texts = []
        for s in segments:
            text = s.text.strip()
            if not text:
                continue
            texts.append(text)
            if words is not None:
                words.extend((w.word, w.start, w.end) for w in (s.words or []))
        return texts


def sentence_times(sentences, words):
    """Where each sentence starts and ends in the audio, as (start, end), from
    the words Whisper heard; None for a sentence whose text isn't found in
    them. The sentences are the words' text cut up, so each is looked for in
    turn, past the one before it."""
    chars = []
    for index, (text, _, _) in enumerate(words):
        chars.extend((ch, index) for ch in text if ch not in _BOUNDARY_NOISE)
    stream = "".join(ch for ch, _ in chars)
    times = []
    cursor = 0
    for sentence in sentences:
        wanted = _content(sentence)
        position = stream.find(wanted, cursor) if wanted else -1
        if position < 0:
            times.append(None)
            continue
        first = chars[position][1]
        last = chars[position + len(wanted) - 1][1]
        times.append((words[first][1], words[last][2]))
        cursor = position + len(wanted)
    return times


def _ollama_generate(text, timeout, prompt=_OLLAMA_PROMPT):
    global _ollama_supports_think
    import urllib.error
    import urllib.request

    payload = {
        "model": OLLAMA_MODEL,
        "prompt": prompt + text,
        "stream": False,
        "keep_alive": OLLAMA_KEEP_ALIVE,
        "options": {"temperature": 0},
    }
    if _ollama_supports_think:
        payload["think"] = False
    req = urllib.request.Request(
        OLLAMA_URL + "/api/generate",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)["response"].strip()
    except urllib.error.HTTPError as exc:
        if exc.code == 400 and _ollama_supports_think:
            _ollama_supports_think = False
            return _ollama_generate(text, timeout, prompt)
        raise


def warm_ollama():
    """First generate pulls the model into memory; also proves reachability."""
    global _ollama_ok
    print(f"translation: ollama {OLLAMA_MODEL} at {OLLAMA_URL}, warming ...",
          flush=True)
    t0 = time.time()
    try:
        _ollama_generate("こんにちは", timeout=300)
        print(f"  ollama ready in {time.time() - t0:.1f}s", flush=True)
    except Exception as exc:
        _ollama_ok = False
        print(f"  ollama unreachable ({exc}); "
              "falling back to whisper task=translate", flush=True)


def unload_ollama():
    """Ask ollama to drop the model now rather than after OLLAMA_KEEP_ALIVE.

    ollama is a separate process, so exiting this one frees only Whisper; the
    LLM would otherwise sit in GPU memory for the whole keep-alive window.
    """
    if TRANSLATE_BACKEND != "ollama":
        return
    import urllib.request

    req = urllib.request.Request(
        OLLAMA_URL + "/api/generate",
        data=json.dumps({"model": OLLAMA_MODEL, "keep_alive": 0}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
        print(f"unloaded ollama {OLLAMA_MODEL}", flush=True)
    except Exception as exc:
        print(f"could not unload ollama {OLLAMA_MODEL} ({exc})", flush=True)


def exit_releasing_gpu():
    unload_ollama()
    os._exit(0)


def _content(text):
    return "".join(ch for ch in text if ch not in _BOUNDARY_NOISE)


def _parse_pairs(response, source):
    """Parse "ja ||| en" lines. None if the LLM strayed from the format or
    rewrote the transcript instead of copying it."""
    pairs = []
    for line in response.splitlines():
        if not line.strip():
            continue
        ja, sep, en = line.partition(_PAIR_SEPARATOR)
        if not sep or not ja.strip():
            return None
        pairs.append((ja.strip(), en.strip()))
    if _content("".join(ja for ja, _ in pairs)) != _content(source):
        return None
    return pairs


def translate_ollama(segments):
    """Return [(japanese, english), ...] one sentence per pair, or None so the
    caller falls back to Whisper."""
    global _ollama_ok
    # One Whisper segment per line: the LLM keeps a line break as a sentence
    # boundary far more reliably than it finds one in unbroken text, where it
    # reads a short exchange between two speakers as a single sentence.
    text = "\n".join(segments)
    try:
        response = _ollama_generate(
            text, timeout=OLLAMA_TIMEOUT, prompt=_OLLAMA_SPLIT_PROMPT
        )
        pairs = _parse_pairs(response, text)
        if pairs:
            return pairs
        print(f"ollama split unusable for {text!r}: {response!r}; "
              "translating per segment", flush=True)
        return [
            (segment, _ollama_generate(segment, timeout=OLLAMA_TIMEOUT))
            for segment in segments
        ]
    except Exception as exc:
        _ollama_ok = False
        print(f"ollama translation failed ({exc}); "
              "falling back to whisper task=translate", flush=True)
        return None


def translate_nllb(text):
    stripped = text.strip()
    if _nllb is None or _is_untranslatable(stripped):
        return ""
    with _nllb_lock:
        tokens = _nllb_tok.convert_ids_to_tokens(_nllb_tok.encode(stripped))
        results = _nllb.translate_batch(
            [tokens], target_prefix=[["eng_Latn"]], beam_size=2, max_decoding_length=256
        )
    hyp = results[0].hypotheses[0]
    if hyp and hyp[0] == "eng_Latn":
        hyp = hyp[1:]
    return _nllb_tok.decode(_nllb_tok.convert_tokens_to_ids(hyp)).strip()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quieter than the default access log
        pass

    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global _last_request_at
        _last_request_at = time.time()
        if self.path.startswith("/health"):
            self._send(200, {
                "status": "ok",
                "asr": ASR_MODEL,
                "device": DEVICE,
                "translation": TRANSLATE_BACKEND != "nllb" or _nllb is not None,
                "translation_backend": (
                    "whisper"
                    if TRANSLATE_BACKEND == "ollama" and not _ollama_ok
                    else TRANSLATE_BACKEND
                ),
                "ollama_model": OLLAMA_MODEL if _ollama_ok else None,
            })
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        global _last_request_at
        _last_request_at = time.time()
        if self.path.startswith("/shutdown"):
            # Lets the client release the GPU immediately on a clean exit
            # instead of waiting out the idle timeout.
            self._send(200, {"status": "shutting down"})
            self.wfile.flush()
            threading.Timer(0.2, exit_releasing_gpu).start()
            return
        if not self.path.startswith("/transcribe"):
            self._send(404, {"error": "not found"})
            return

        from urllib.parse import parse_qs, urlparse

        query = parse_qs(urlparse(self.path).query)
        beam_size = int(query.get("beam_size", ["3"])[0])
        want_translation = query.get("translate", ["1"])[0] not in ("0", "false")
        prompt = query.get("prompt", [""])[0].strip()

        length = int(self.headers.get("Content-Length", 0))
        pcm = self.rfile.read(length) if length else b""

        try:
            t0 = time.time()
            audio = decode_pcm(pcm)
            duration = audio.size / SAMPLE_RATE
            words = []
            segments = run_whisper(audio, beam_size=beam_size, prompt=prompt, words=words)
            ja = "".join(segments)
            pairs = [(ja, "")] if ja else []
            if want_translation and ja and not _is_untranslatable(ja):
                if TRANSLATE_BACKEND == "nllb":
                    pairs = [(ja, translate_nllb(ja))]
                else:
                    pairs = translate_ollama(segments) if _ollama_ok else None
                    if pairs is None:
                        pairs = [(ja, " ".join(run_whisper(
                            audio, beam_size=beam_size, task="translate"
                        )))]
            elapsed = time.time() - t0
            lines = []
            for (j, e), span in zip(pairs, sentence_times([j for j, _ in pairs], words)):
                line = {"ja": j, "en": e}
                if span:
                    line["start"], line["end"] = round(span[0], 2), round(span[1], 2)
                lines.append(line)
            self._send(200, {
                "ja": ja,
                "en": " ".join(en for _, en in pairs if en),
                "lines": lines,
                "audio_seconds": round(duration, 2),
                "elapsed": round(elapsed, 3),
                "rtf": round(elapsed / duration, 4) if duration else None,
            })
        except Exception as exc:
            self._send(500, {"error": f"{type(exc).__name__}: {exc}"})


def start_idle_watchdog(timeout):
    """Exit after `timeout` seconds with no requests.

    The client shuts this process down over SSH when it quits, but a dropped
    network or a hard-killed laptop would otherwise leave the model pinned in
    GPU memory. This is the backstop for that.
    """
    def watch():
        while True:
            time.sleep(5)
            idle = time.time() - _last_request_at
            if idle > timeout:
                print(f"idle {idle:.0f}s > {timeout}s, shutting down", flush=True)
                exit_releasing_gpu()

    threading.Thread(target=watch, daemon=True).start()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument(
        "--idle-timeout",
        type=float,
        default=float(os.getenv("LIVETRANS_IDLE_TIMEOUT", "0")),
        help="exit after this many idle seconds (0 disables)",
    )
    args = parser.parse_args()

    load_models()
    # A plain `kill` should release the LLM too, not just this process.
    signal.signal(signal.SIGTERM, lambda *_: exit_releasing_gpu())
    if args.idle_timeout > 0:
        print(f"idle timeout: {args.idle_timeout:.0f}s", flush=True)
        start_idle_watchdog(args.idle_timeout)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"listening on {args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

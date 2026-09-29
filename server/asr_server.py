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
POST /prefetch     body: {"url": media or page URL, "page": page URL,
                          "headers": {"Referer": ..., "User-Agent": ...},
                          "duration": seconds or null}
                   -> {"job": id}. Fetches the audio ahead of the viewer with
                   ffmpeg (a page URL is resolved with yt-dlp first), and
                   transcribes it in chunks cut at silences.
GET  /prefetch/<id>?since=N
                   -> {"state": "running"|"paused"|"done"|"failed", "error": ...,
                       "duration": seconds or null, "fetched": seconds,
                       "ready": seconds, "count": lines so far,
                       "lines": the lines from index N on, with absolute
                       "start"/"end"}
POST /prefetch/<id>/rehear?from=&to=
                   -> {"lines": [...]} that stretch heard again from the
                   fetched audio, with a wider search and its context; a
                   long line is split where the speaker paused after a word
                   that can end a sentence, or paused long.
POST /prefetch/<id>/stop
POST /prefetch/<id>/pause, /prefetch/<id>/resume
                   holds or lets go the transcription (the GPU work); the
                   audio keeps being fetched. A paused job reports "paused".
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
import subprocess
import threading
import time
import uuid
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


def run_whisper(audio, beam_size=3, task="transcribe", prompt=None, words=None, vad=False):
    """task="transcribe" -> Japanese, task="translate" -> English.

    `vad` runs Whisper's own voice filter (Silero) first, for audio that was
    not cut by the Mac: music and silence between the lines are skipped.

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
            audio, language="ja", task=task, beam_size=beam_size, vad_filter=vad,
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
    them."""
    return [
        (words[span[0]][1], words[span[1]][2]) if span else None
        for span in sentence_word_spans(sentences, words)
    ]


def sentence_word_spans(sentences, words):
    """The first and last of `words` in each sentence, or None for one whose
    text isn't found in them. The sentences are the words' text cut up, so
    each is looked for in turn, past the one before it."""
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
        times.append((chars[position][1], chars[position + len(wanted) - 1][1]))
        cursor = position + len(wanted)
    return times


# A line heard again that runs longer than this is looked at for pauses to
# split it at: two sentences run together the first time are often heard as
# one again.
SPLIT_MIN_SECONDS = 6.0
SPLIT_MIN_CHARS = 40
# A pause this long ends a sentence; a shorter one only after a word that
# can end one, so a speaker hesitating mid-sentence is not cut. Pauses are
# measured in the audio: Whisper stretches its words over the silence
# around them, so the gaps between its word times are mostly gone.
SPLIT_PAUSE = 0.7
SPLIT_PAUSE_AT_ENDING = 0.2
# A piece shorter than this stays with its neighbour.
SPLIT_MIN_PIECE_CHARS = 4
_SENTENCE_ENDINGS = ("。", "？", "！", "?", "!", "ます", "です", "た", "だ", "ね", "よ", "か", "わ")


def _ends_sentence(text):
    text = text.rstrip(" 　、,")
    return text.endswith(_SENTENCE_ENDINGS)


def silences(audio):
    """The quiet stretches between speech in `audio`, as (start, end) seconds."""
    from faster_whisper.vad import VadOptions, get_speech_timestamps

    speech = get_speech_timestamps(audio, VadOptions(min_silence_duration_ms=150, speech_pad_ms=0))
    return [(a["end"] / SAMPLE_RATE, b["start"] / SAMPLE_RATE) for a, b in zip(speech, speech[1:])]


def pause_between(words, i, quiet):
    """How long the speaker paused between word i and the next: the longest
    quiet stretch centred between the start of the one and the end of the
    other, which is as close as Whisper's word times place the break."""
    low, high = words[i][1], words[i + 1][2]
    return max((end - start for start, end in quiet if low <= (start + end) / 2 <= high), default=0.0)


def pause_cuts(words, first, last, quiet):
    """Where to cut the words first..last into sentences: the indices of the
    words each new piece starts with."""
    cuts = []
    piece_start = first
    for i in range(first, last):
        gap = pause_between(words, i, quiet)
        before = "".join(w[0] for w in words[piece_start:i + 1])
        after = "".join(w[0] for w in words[i + 1:last + 1])
        if (gap >= SPLIT_PAUSE or (gap >= SPLIT_PAUSE_AT_ENDING and _ends_sentence(before))) \
                and len(_content(before)) >= SPLIT_MIN_PIECE_CHARS \
                and len(_content(after)) >= SPLIT_MIN_PIECE_CHARS:
            cuts.append(i + 1)
            piece_start = i + 1
    return cuts


def _cut_text(text, counts):
    """`text` cut after each of `counts` characters of content (punctuation
    uncounted); punctuation at a cut stays with the piece before it."""
    pieces, start, seen, index = [], 0, 0, 0
    for count in counts:
        while index < len(text) and seen < count:
            if text[index] not in _BOUNDARY_NOISE:
                seen += 1
            index += 1
        while index < len(text) and text[index] in _BOUNDARY_NOISE:
            index += 1
        pieces.append(text[start:index].strip())
        start = index
    pieces.append(text[start:].strip())
    return pieces


def split_at_pauses(lines, words, quiet, translate):
    """Long lines cut into sentences where the speaker paused, each piece
    with its own times and its own translation from `translate(ja)`. A line
    that cannot be placed among the words, or whose pieces cannot be
    translated, is kept whole."""
    spans = sentence_word_spans([line["ja"] for line in lines], words)
    result = []
    for line, span in zip(lines, spans):
        long = (line.get("end", 0) - line.get("start", 0) > SPLIT_MIN_SECONDS
                or len(_content(line["ja"])) > SPLIT_MIN_CHARS)
        cuts = pause_cuts(words, *span, quiet) if span and long else []
        if not cuts:
            result.append(line)
            continue
        bounds = [span[0], *cuts, span[1] + 1]
        counts, total = [], 0
        for a, b in zip(bounds, bounds[1:-1]):
            total += len(_content("".join(w[0] for w in words[a:b])))
            counts.append(total)
        texts = _cut_text(line["ja"], counts)
        try:
            english = [translate(text) for text in texts]
        except Exception as exc:
            print(f"split kept whole, translation failed: {exc}", flush=True)
            result.append(line)
            continue
        print(f"split at pauses: {line['ja']} -> {' | '.join(texts)}", flush=True)
        for text, en, a, b in zip(texts, english, bounds, bounds[1:]):
            result.append({"ja": text, "en": en,
                           "start": round(float(words[a][1]), 2), "end": round(float(words[b - 1][2]), 2)})
    return result


def translate_text(ja):
    """One sentence's English, from the text alone."""
    if _is_untranslatable(ja):
        return ""
    if TRANSLATE_BACKEND == "nllb":
        return translate_nllb(ja)
    if not _ollama_ok:
        raise RuntimeError("no text translator")
    return _ollama_generate(ja, timeout=OLLAMA_TIMEOUT)


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


def transcribe_and_translate(audio, beam_size, prompt="", want_translation=True, vad=False, words=None):
    """Japanese text, its sentences paired with English, and the lines with
    where each sits in `audio`: [{"ja", "en", "start", "end"}, ...].
    `words`, a list, is filled with the words heard and their times."""
    words = [] if words is None else words
    segments = run_whisper(audio, beam_size=beam_size, prompt=prompt, words=words, vad=vad)
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
    lines = []
    for (j, e), span in zip(pairs, sentence_times([j for j, _ in pairs], words)):
        line = {"ja": j, "en": e}
        if span:
            line["start"], line["end"] = round(span[0], 2), round(span[1], 2)
        lines.append(line)
    return ja, pairs, lines


# ---------------------------------------------------------------------------
# Pre-fetch: the audio of a video fetched ahead of the viewer and transcribed
# in chunks, so the captions are ready before the video gets there.

PREFETCH_CHUNK = float(os.getenv("LIVETRANS_PREFETCH_CHUNK", "60"))
# How far past the chunk to look for a quiet moment to cut at, and how much
# past it must have arrived before cutting, so a fetch that only just keeps
# ahead of the viewer is still transcribed as it comes.
PREFETCH_LOOKAHEAD = 30.0
PREFETCH_MIN_LOOKAHEAD = 5.0
# What the transcription of a chunk is told of the one before, so a name
# carries over; Whisper reads at most ~224 tokens of prompt.
PREFETCH_PROMPT_CHARS = 120
PREFETCH_MAX_JOBS = 4
PREFETCH_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
}

_jobs = {}
_jobs_lock = threading.Lock()


def _tool(name):
    """A command on PATH, or in the user's own bin directories, which a
    server started over ssh may not have on its PATH."""
    import shutil

    found = shutil.which(name)
    if found:
        return found
    for directory in ("~/.local/bin", "~/.deno/bin", "/usr/local/bin"):
        candidate = os.path.expanduser(os.path.join(directory, name))
        if os.access(candidate, os.X_OK):
            return candidate
    return name


def resolve_media_url(url, page):
    """A URL ffmpeg can read. A page (no direct media given) is asked of
    yt-dlp, which knows most video sites and has a generic fallback. Formats
    fetched by plain HTTP are preferred to HLS: YouTube paces HLS at
    playback speed, and its direct formats need yt-dlp to have a JavaScript
    runtime (deno)."""
    if url:
        return url, None
    command = [_tool("yt-dlp"), "--no-playlist", "-f", "ba[protocol!*=m3u8]/ba/b", "--get-url", page]
    deno = _tool("deno")
    if os.path.isabs(deno):
        command[1:1] = ["--js-runtimes", f"deno:{deno}"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if result.returncode != 0 or not lines:
        return None, (result.stderr.strip().splitlines() or ["yt-dlp found no media"])[-1]
    return lines[0], None


def choose_boundary(audio, target):
    """Where to end a chunk, in seconds into `audio`: the quiet moment after
    the last speech that ends by `target`, or `target` itself when the
    speech runs on through it. The next chunk starts there, so no word is
    cut in two."""
    from faster_whisper.vad import VadOptions, get_speech_timestamps

    speech = get_speech_timestamps(audio, VadOptions(min_silence_duration_ms=300))
    ends = [s["end"] / SAMPLE_RATE for s in speech if s["end"] / SAMPLE_RATE <= target]
    if not ends:
        return target
    last = ends[-1]
    following = [s["start"] / SAMPLE_RATE for s in speech if s["start"] / SAMPLE_RATE > last]
    return min(last + 0.15, (last + following[0]) / 2) if following else last + 0.15


class PrefetchJob:
    def __init__(self, url, page, headers, duration):
        self.id = uuid.uuid4().hex[:12]
        self.url = url
        self.page = page
        self.headers = {**PREFETCH_HEADERS, **(headers or {})}
        self.duration = duration
        self.audio = np.zeros(0, dtype=np.float32)
        self.audio_lock = threading.Lock()
        self.fetch_done = False
        self.lines = []
        self.text = ""
        self.ready = 0.0
        self.state = "running"
        self.error = None
        self.stop_event = threading.Event()
        self.paused = threading.Event()
        self.process = None
        self.started = time.time()
        threading.Thread(target=self._fetch, daemon=True).start()
        threading.Thread(target=self._transcribe, daemon=True).start()

    @property
    def fetched(self):
        return self.audio.size / SAMPLE_RATE

    def stop(self):
        self.stop_event.set()
        if self.process and self.process.poll() is None:
            self.process.kill()

    def fail(self, message):
        print(f"prefetch {self.id}: {message}", flush=True)
        self.error = message
        self.state = "failed"
        self.stop()

    def _fetch(self):
        try:
            media, error = resolve_media_url(self.url, self.page)
        except Exception as exc:
            media, error = None, f"{type(exc).__name__}: {exc}"
        if not media:
            self.fail(error or "no media")
            return
        header_lines = "".join(f"{k}: {v}\r\n" for k, v in self.headers.items())
        command = [
            _tool("ffmpeg"), "-nostdin", "-loglevel", "error",
            "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5",
            "-headers", header_lines, "-i", media,
            "-vn", "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "s16le", "-",
        ]
        print(f"prefetch {self.id}: fetching {media[:80]}", flush=True)
        try:
            self.process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as exc:
            self.fail(f"ffmpeg: {exc}")
            return
        while not self.stop_event.is_set():
            chunk = self.process.stdout.read(SAMPLE_RATE * 2)  # one second
            if not chunk:
                break
            samples = decode_pcm(chunk)
            with self.audio_lock:
                self.audio = np.concatenate([self.audio, samples])
        self.process.wait()
        if self.process.returncode not in (0, None) and not self.stop_event.is_set() and self.fetched < 1:
            self.fail(f"ffmpeg: {self.process.stderr.read().decode(errors='replace').strip()[-200:]}")
            return
        self.fetch_done = True
        if self.duration is None or self.duration <= 0:
            self.duration = self.fetched
        print(f"prefetch {self.id}: fetched {self.fetched:.0f}s", flush=True)

    def _transcribe(self):
        position = 0.0
        while not self.stop_event.is_set() and self.state == "running":
            with self.audio_lock:
                have = self.fetched
                done = self.fetch_done
            if done and have <= position + 0.05:
                self.state = "done"
                print(f"prefetch {self.id}: done, {len(self.lines)} lines", flush=True)
                return
            if self.paused.is_set():
                time.sleep(0.25)
                continue
            if have - position < PREFETCH_CHUNK + PREFETCH_MIN_LOOKAHEAD and not done:
                time.sleep(0.25)
                continue
            window_end = min(have, position + PREFETCH_CHUNK + PREFETCH_LOOKAHEAD)
            with self.audio_lock:
                window = self.audio[int(position * SAMPLE_RATE):int(window_end * SAMPLE_RATE)].copy()
            if done and window_end >= have:
                boundary = window_end
            else:
                boundary = position + choose_boundary(window, PREFETCH_CHUNK)
            try:
                self._transcribe_chunk(position, boundary, window[:int((boundary - position) * SAMPLE_RATE)])
            except Exception as exc:
                self.fail(f"transcription: {type(exc).__name__}: {exc}")
                return
            position = boundary
            self.ready = boundary

    def _transcribe_chunk(self, start, end, audio):
        t0 = time.time()
        ja, _, lines = transcribe_and_translate(
            audio, beam_size=5, prompt=self.text[-PREFETCH_PROMPT_CHARS:], vad=True
        )
        for line in lines:
            if "start" in line:
                line["start"] = round(line["start"] + start, 2)
                line["end"] = round(line["end"] + start, 2)
            else:
                # Not placed among the words: the whole chunk is the best
                # that can be said.
                line["start"], line["end"] = round(start, 2), round(end, 2)
        self.lines.extend(lines)
        self.text += ja
        print(f"prefetch {self.id}: {start:.0f}-{end:.0f}s, {len(lines)} lines in {time.time() - t0:.1f}s", flush=True)

    def rehear(self, start, end):
        """The stretch heard again from the fetched audio, with the wider
        search and the lines before it as context, and a long line split
        where the speaker paused."""
        lead, tail = 0.3, 0.3
        with self.audio_lock:
            from_sample = int(max(start - lead, 0) * SAMPLE_RATE)
            audio = self.audio[from_sample:int((end + tail) * SAMPLE_RATE)].copy()
        before = [line["ja"] for line in self.lines if line.get("end", 0) <= start + 0.05][-2:]
        words = []
        _, _, lines = transcribe_and_translate(audio, beam_size=10, prompt="".join(before), words=words)
        lines = split_at_pauses(lines, words, silences(audio), translate_text)
        offset = from_sample / SAMPLE_RATE
        for line in lines:
            if "start" in line:
                line["start"], line["end"] = round(line["start"] + offset, 2), round(line["end"] + offset, 2)
        return lines

    def status(self, since=0):
        with self.audio_lock:
            last = self.audio[-SAMPLE_RATE:]
        return {
            "state": "paused" if self.state == "running" and self.paused.is_set() else self.state,
            "error": self.error,
            "duration": self.duration,
            "fetched": round(self.fetched, 2),
            # Loudness of the last second fetched, on the int16 scale: a
            # fetch that yields silence is a fetch of the wrong thing.
            "level": round(float(np.sqrt(np.mean(last * last))) * 32768, 1) if last.size else 0,
            "ready": round(self.ready, 2),
            "count": len(self.lines),
            "lines": self.lines[since:],
        }


def start_prefetch(url, page, headers, duration):
    with _jobs_lock:
        for job in list(_jobs.values()):
            if job.page == page and job.state == "running":
                job.stop()
                del _jobs[job.id]
        while len(_jobs) >= PREFETCH_MAX_JOBS:
            oldest = min(_jobs.values(), key=lambda j: j.started)
            oldest.stop()
            del _jobs[oldest.id]
        job = PrefetchJob(url, page, headers, duration)
        _jobs[job.id] = job
        return job


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
                "prefetch": True,
            })
        elif self.path.startswith("/prefetch/"):
            from urllib.parse import parse_qs, urlparse

            parts = urlparse(self.path)
            job = _jobs.get(parts.path.split("/")[2])
            if job is None:
                self._send(404, {"error": "no such job"})
                return
            since = int(parse_qs(parts.query).get("since", ["0"])[0])
            self._send(200, job.status(since))
        else:
            self._send(404, {"error": "not found"})

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length else b""

    def _do_prefetch(self):
        from urllib.parse import parse_qs, urlparse

        parts = urlparse(self.path)
        pieces = parts.path.split("/")
        if len(pieces) == 2:
            try:
                request = json.loads(self._read_body() or b"{}")
                job = start_prefetch(
                    request.get("url") or "", request.get("page") or "",
                    request.get("headers") or {}, request.get("duration"),
                )
            except Exception as exc:
                self._send(400, {"error": f"{type(exc).__name__}: {exc}"})
                return
            self._send(200, {"job": job.id})
            return
        job = _jobs.get(pieces[2])
        if job is None:
            self._send(404, {"error": "no such job"})
            return
        action = pieces[3] if len(pieces) > 3 else ""
        if action == "stop":
            job.stop()
            self._send(200, {"state": job.state})
        elif action in ("pause", "resume"):
            if action == "pause":
                job.paused.set()
            else:
                job.paused.clear()
            print(f"prefetch {job.id}: {action}d", flush=True)
            self._send(200, {"state": job.status(len(job.lines))["state"]})
        elif action == "rehear":
            query = parse_qs(parts.query)
            try:
                start, end = float(query["from"][0]), float(query["to"][0])
                self._send(200, {"lines": job.rehear(start, end)})
            except Exception as exc:
                self._send(500, {"error": f"{type(exc).__name__}: {exc}"})
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
        if self.path.startswith("/prefetch"):
            self._do_prefetch()
            return
        if not self.path.startswith("/transcribe"):
            self._send(404, {"error": "not found"})
            return

        from urllib.parse import parse_qs, urlparse

        query = parse_qs(urlparse(self.path).query)
        beam_size = int(query.get("beam_size", ["3"])[0])
        want_translation = query.get("translate", ["1"])[0] not in ("0", "false")
        prompt = query.get("prompt", [""])[0].strip()
        pcm = self._read_body()

        try:
            t0 = time.time()
            audio = decode_pcm(pcm)
            duration = audio.size / SAMPLE_RATE
            ja, pairs, lines = transcribe_and_translate(audio, beam_size, prompt, want_translation)
            elapsed = time.time() - t0
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

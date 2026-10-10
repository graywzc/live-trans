"""GPU inference server for LiveTrans. Runs on a CUDA host.

The Mac captures audio, segments it with VAD, and POSTs raw PCM here; this
process runs Whisper on the GPU and returns the Japanese text plus its English
translation. Audio never leaves your own machines, and nothing heard or
what was watched is written to the log: it counts lines, it does not quote
them.

Translation defaults to the host's ollama server (qwen-class LLMs are the only
backend here that translates colloquial speech correctly), falling back to
Whisper's own speech->English task when ollama is unreachable. Set
LIVETRANS_TRANSLATE_BACKEND=whisper to skip ollama entirely, or =nllb to use
the text->text NLLB model instead.

    python asr_server.py --host 0.0.0.0 --port 8765

POST /shutdown     exit now and release the GPU (unloads the ollama model too)
POST /prefetch     body: {"url": media or page URL, "page": page URL,
                          "headers": {"Referer": ..., "User-Agent": ...},
                          "duration": seconds or null,
                          "start": seconds into the video, 0 if absent}
                   -> {"job": id}. Fetches the audio from there on with
                   ffmpeg (a page URL is resolved with yt-dlp first), and
                   finds the speech in it as it arrives, and transcribes
                   that in batches of about a minute of speech, each ending
                   in a pause (see choose_batch), the words of each put
                   into the pieces of a grid of cuts made at the pauses in
                   the audio (see CutGrid). A job running for the
                   same page is stopped; what it captioned can still be
                   heard again.
GET  /prefetch/<id>?since=N
                   -> {"state": "running"|"paused"|"done"|"failed", "error": ...,
                       "duration": seconds or null, "start": seconds,
                       "fetched": seconds, "ready": seconds (both places in
                       the video, like "start"), "count": lines so far,
                       "lines": the lines from index N on, with absolute
                       "start"/"end"}
POST /prefetch/<id>/rehear?from=&to=[&vad=1]
                   -> {"lines": [...]} the pieces of the grid at that
                   stretch heard again from the fetched audio, with a wider
                   search, their context, and the neighbours that follow on
                   in the audio heard with them; the lines come back on the
                   same cuts as before, or finer, never otherwise.
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
GET /events?since=N
                   -> {"boot": id of this run of the server, "next": N to
                       ask from next time, "events": [{"seq": 12,
                       "at": seconds since 1970, "text": "..."}, ...]}
                   what the server told of its work (see `tell`) from N
                   on, for the app to list. It may quote what was heard,
                   as the lines of a job do, and like them is only ever
                   in memory: the last couple of thousand, never in the
                   log.
"""

import argparse
import collections
import json
import os
import re
import signal
import subprocess
import sys
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
# Whisper now and then returns half a minute of speech as one segment with
# no punctuation. Among the other lines of a transcript the LLM leaves such
# a line whole; given it alone and told it is too long, it breaks it up.
_OLLAMA_LONG_PROMPT = (
    "Below is one long stretch of Japanese speech, transcribed without sentence breaks.\n"
    "Break it into short lines, each a sentence or a clause, cutting after sentence "
    "endings and after connectives such as けど, ので, から, し, て or たら. "
    "A line should be at most about 40 Japanese characters.\n"
    "Translate each line into natural English.\n"
    "Output one line per piece in exactly this format:\n"
    "<Japanese> ||| <English translation>\n"
    "Copy the Japanese characters exactly as given, in order; do not add, drop, or "
    "change any. Output nothing else.\n\n"
)
_PAIR_SEPARATOR = "|||"
# How much of the transcript the LLM's copy must match for its sentence
# breaks to be used.
_COPY_MIN_RATIO = 0.9
# Ignored when checking the LLM copied the transcript faithfully: it may add or
# drop punctuation at the boundaries it found, which is harmless.
_BOUNDARY_NOISE = set("。、，．,.!?！？…‥ 　\t\n")

_last_request_at = time.time()

# What the server tells of its work, for the app to list beside its own. A
# run of the server numbers the lines from one, and names itself so that a
# client can tell the numbering has started over.
EVENTS_KEPT = 2000
_boot = uuid.uuid4().hex[:8]
_events = collections.deque(maxlen=EVENTS_KEPT)
_events_lock = threading.Lock()
_event_count = 0


def tell(text):
    """A line for /events alone: it may quote what was heard, so it is
    never printed, and is gone with the server."""
    global _event_count
    with _events_lock:
        _event_count += 1
        _events.append({"seq": _event_count, "at": round(time.time(), 3), "text": text})


def clock(seconds):
    """"4:05.3", a place in the video as the app shows it, to the tenth."""
    tenths = round(max(float(seconds), 0.0) * 10)
    return f"{tenths // 600}:{tenths % 600 / 10:04.1f}"


def events_since(since):
    with _events_lock:
        return {
            "boot": _boot,
            "next": _event_count,
            "events": [event for event in _events if event["seq"] > since],
        }


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


def run_whisper(audio, beam_size=3, task="transcribe", prompt=None, words=None, vad=False, breaks=None, clips=None):
    """task="transcribe" -> Japanese, task="translate" -> English.

    `vad` finds the speech in the audio first (Silero), and Whisper is
    given only those stretches, as clips: music and silence between the
    lines are skipped, and a stretch with no speech in it gives nothing,
    where Whisper alone invents a stock line over it. The clips are decoded
    in place, pauses and all, not cut out and glued end to end as Whisper's
    own voice filter would: glued, a grunt four seconds before a sentence
    lands on its first word and changes it, and the word times are
    stretched over the silence that was cut.

    `prompt` is what was said just before the audio, given to Whisper as
    context: a name or a term it has seen is one it is likelier to hear.

    `clips`, [(start, end), ...] in seconds, are the stretches to decode,
    each on its own, in place of `vad` finding them.

    `words`, a list, is filled with (text, start, end) for every word heard,
    the times in seconds into the audio; `breaks`, a list, with (index,
    start) for each segment: the index in `words` of its first word, and
    where it starts in the audio.

    Returns Whisper's segments as a list. It ends a segment at a pause in the
    speech, so the boundaries are worth keeping: they are the only sign of a
    sentence break or a change of speaker when there is no punctuation.
    """
    if audio.size == 0:
        return []
    if clips is not None:
        clips = [t for clip in clips for t in clip]
        if not clips:
            return []
    elif vad:
        clips = speech_clips(audio)
        if not clips:
            return []
    else:
        clips = "0"
    with _asr_lock:
        segments, _ = _asr.transcribe(
            audio, language="ja", task=task, beam_size=beam_size, clip_timestamps=clips,
            initial_prompt=prompt or None, word_timestamps=words is not None,
        )
        texts = []
        for s in segments:
            text = s.text.strip()
            if not text:
                continue
            texts.append(text)
            if breaks is not None:
                breaks.append((len(words), s.start))
            if words is not None:
                words.extend((w.word, w.start, w.end) for w in (s.words or []))
        return texts


def speech_clips(audio):
    """Where the speech is in `audio`, as [start, end, start, end, ...] in
    seconds, for Whisper's `clip_timestamps`; empty when there is none.
    Silero's own defaults, as its filter in Whisper would use them: a pause
    shorter than two seconds stays inside a clip."""
    from faster_whisper.vad import VadOptions, get_speech_timestamps

    clips = []
    for chunk in get_speech_timestamps(audio, VadOptions()):
        clips += [chunk["start"] / SAMPLE_RATE, chunk["end"] / SAMPLE_RATE]
    return clips


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


# A line that runs longer than this is taken to hold more than a sentence:
# the LLM is asked to split it by itself, and what is still long after that
# is looked at for pauses to split it at.
SPLIT_MIN_SECONDS = 6.0
SPLIT_MIN_CHARS = 40
# A pause this long ends a sentence; a shorter one only where Whisper
# wrote a sentence's punctuation, so a speaker hesitating mid-sentence is
# not cut. Pauses are measured in the audio: Whisper stretches its words
# over the silence around them, so the gaps between its word times are
# mostly gone.
SPLIT_PAUSE = 0.7
SPLIT_PAUSE_AT_PUNCTUATION = 0.2
# A piece shorter than this stays with its neighbour.
SPLIT_MIN_PIECE_CHARS = 4


def _ends_sentence(text):
    """Whether `text` ends in the punctuation that ends a sentence."""
    return bool(_SENTENCE_END.search(text.rstrip(" \u3000")[-1:]))


def silences(audio):
    """The quiet stretches between speech in `audio`, as (start, end) seconds."""
    from faster_whisper.vad import VadOptions, get_speech_timestamps

    speech = get_speech_timestamps(audio, VadOptions(min_silence_duration_ms=150, speech_pad_ms=0))
    return [(a["end"] / SAMPLE_RATE, b["start"] / SAMPLE_RATE) for a, b in zip(speech, speech[1:])]


# No word lasts across a silence this long: one that does was put astride
# it by Whisper, and is taken back to the side it was said on.
STRETCH_PAUSE = 1.0


def unstretch(words, quiet):
    """`words` with none lasting across a long stretch of `quiet` (the
    silences in the audio). Whisper hears the audio with the silences cut
    out, and a word at a cut can land on either side of it when its times
    are put back: the first word of a sentence spoken after a pause gets
    the end of the sentence before as its start, half a minute early, and
    the last word before a pause can run on to the sentence after. A word
    that starts in a long silence starts where it ends; one that ends in
    one ends where it begins; one spanning it whole keeps the side more of
    it is on."""
    long = [(a, b) for a, b in quiet if b - a >= STRETCH_PAUSE]
    result = []
    for text, start, end in words:
        for qa, qb in long:
            if start < qa and end > qb:
                if end - qb >= qa - start:
                    start = qb
                else:
                    end = qa
            elif qa <= start < qb < end:
                start = qb
            elif start < qa < end <= qb:
                end = qa
        result.append((text, start, end))
    return result


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
        if (gap >= SPLIT_PAUSE or (gap >= SPLIT_PAUSE_AT_PUNCTUATION and _ends_sentence(before))) \
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
    translated, is kept whole. `quiet()` gives the silences in the audio,
    asked for only when a line is long."""
    spans = sentence_word_spans([line["ja"] for line in lines], words)
    result = []
    silent = None
    for line, span in zip(lines, spans):
        cuts = []
        if span and _is_long(line["ja"], span, words):
            if silent is None:
                silent = quiet()
            cuts = pause_cuts(words, *span, silent)
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
        print(f"split at pauses: one line into {len(texts)}", flush=True)
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
    # Nothing of the session is kept: the log, which the app starts afresh
    # with each launch, is emptied too. A crash leaves it for a look.
    try:
        sys.stdout.flush()
        if os.path.isfile(f"/proc/self/fd/{sys.stdout.fileno()}"):
            os.ftruncate(sys.stdout.fileno(), 0)
    except OSError:
        pass
    os._exit(0)


def _content(text):
    return "".join(ch for ch in text if ch not in _BOUNDARY_NOISE)


def _parse_pairs(response, source):
    """Parse "ja ||| en" lines. None if the LLM strayed from the format or
    rewrote the transcript instead of copying it. A copy off by a character
    or two (a particle dropped, a word respelled) is still good for where
    the sentences break: the transcript's own text is put back in them."""
    pairs = []
    for line in response.splitlines():
        if not line.strip():
            continue
        ja, sep, en = line.partition(_PAIR_SEPARATOR)
        if not sep or not ja.strip():
            return None
        pairs.append((ja.strip(), en.strip()))
    copied = "".join(_content(ja) for ja, _ in pairs)
    wanted = _content(source)
    if copied == wanted:
        return pairs
    import difflib

    matcher = difflib.SequenceMatcher(None, copied, wanted, autojunk=False)
    if matcher.ratio() < _COPY_MIN_RATIO:
        return None
    blocks = matcher.get_opcodes()

    def in_source(position):
        for tag, i1, i2, j1, j2 in blocks:
            if position <= i2:
                return j1 + position - i1 if tag == "equal" else (j2 if position == i2 else j1)
        return len(wanted)

    counts, seen = [], 0
    for ja, _ in pairs[:-1]:
        seen += len(_content(ja))
        counts.append(in_source(seen))
    texts = [text.replace("\n", "") for text in _cut_text(source, counts)]
    # A line with nothing of the transcript in it was made up, and one
    # without English was not translated: neither is a split to trust.
    restored = [(text, en) for text, (_, en) in zip(texts, pairs) if _content(text)]
    if not restored or any(not en for _, en in restored):
        return None
    return restored


_SENTENCE_END = re.compile(r"[。？！?!]+")


def _at_sentence_ends(segments):
    """Whisper's segments cut after the punctuation that ends a sentence,
    where it wrote any: given a segment as a line, the LLM tends to keep it
    as one however many sentences it holds. A piece too short to stand
    alone ("え？") stays with what follows, and words being quoted are not
    cut from the sentence quoting them."""
    result = []
    for segment in segments:
        start = 0
        for match in _SENTENCE_END.finditer(segment):
            piece, rest = segment[start:match.end()], segment[match.end():]
            quoted = rest[:1] in "」』" or piece.count("「") + piece.count("『") > piece.count("」") + piece.count("』")
            if not quoted and len(_content(piece)) >= SPLIT_MIN_PIECE_CHARS \
                    and len(_content(rest)) >= SPLIT_MIN_PIECE_CHARS:
                result.append(piece.strip())
                start = match.end()
        result.append(segment[start:].strip())
    return result


_BREAK_IN_SPEECH = re.compile(r"(?<=[^\x00-\x7f])[ \u3000]+(?=[^\x00-\x7f])")


def _for_splitting(text):
    """`text` as the LLM is given it to split. Whisper writes a space where
    a Japanese speaker broke off; the LLM takes a line with one for two
    fields already and answers with no English. A comma says the same."""
    return _BREAK_IN_SPEECH.sub("、", text)


def _breaks_only(response, source):
    """The pieces of `source` from an answer that broke it up but did not
    translate it ("ja ||| ja ||| ja"), each translated by itself. None if
    the answer is not that."""
    fields = [field.strip() for line in response.splitlines() for field in line.split(_PAIR_SEPARATOR)]
    japanese = [field for field in fields if any(ch > "\u3000" for ch in field)]
    pieces = _parse_pairs("\n".join(f"{field} {_PAIR_SEPARATOR} -" for field in japanese), source)
    if not pieces or len(pieces) < 2:
        return None
    return [(ja, _ollama_generate(ja, timeout=OLLAMA_TIMEOUT)) for ja, _ in pieces]


def _is_long(text, span, words):
    """Whether a line runs long enough, in characters or in seconds, to hold
    more than a sentence."""
    return (len(_content(text)) > SPLIT_MIN_CHARS
            or (span is not None and words[span[1]][2] - words[span[0]][1] > SPLIT_MIN_SECONDS))


def _split_long(pairs, words):
    """`pairs` with the long ones broken up, each asked of the LLM alone:
    one long in characters into sentences and clauses, one long only by
    the clock (a few short lines shouted over half a minute) into its
    sentences. One the LLM cannot break stays whole."""
    result = []
    for (ja, en), span in zip(pairs, sentence_word_spans([ja for ja, _ in pairs], words)):
        pieces = None
        size = len(_content(ja))
        if _is_long(ja, span, words) and size >= 2 * SPLIT_MIN_PIECE_CHARS:
            prompt = _OLLAMA_LONG_PROMPT if size > SPLIT_MIN_CHARS else _OLLAMA_SPLIT_PROMPT
            try:
                response = _ollama_generate(_for_splitting(ja), timeout=OLLAMA_TIMEOUT, prompt=prompt)
                pieces = _parse_pairs(response, ja) or _breaks_only(response, ja)
            except Exception as exc:
                print(f"long line not split: {exc}", flush=True)
            print(f"long line of {size} characters: "
                  + (f"into {len(pieces)}" if pieces else "kept whole"), flush=True)
        result.extend(pieces or [(ja, en)])
    return result


def translate_ollama(segments):
    """Return [(japanese, english), ...] one sentence per pair, or None so the
    caller falls back to Whisper."""
    global _ollama_ok
    # One Whisper segment per line: the LLM keeps a line break as a sentence
    # boundary far more reliably than it finds one in unbroken text, where it
    # reads a short exchange between two speakers as a single sentence.
    segments = _at_sentence_ends(segments)
    text = "\n".join(segments)
    try:
        response = _ollama_generate(
            _for_splitting(text), timeout=OLLAMA_TIMEOUT, prompt=_OLLAMA_SPLIT_PROMPT
        )
        pairs = _parse_pairs(response, text)
        if pairs:
            return pairs
        print(f"ollama split unusable ({len(text)} characters in, {len(response)} out); "
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
    quiet = None
    # Only a word this long can lie across a long silence.
    if any(end - start >= STRETCH_PAUSE for _, start, end in words):
        quiet = silences(audio)
        words[:] = unstretch(words, quiet)
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
            else:
                pairs = _split_long(pairs, words)
    lines = []
    for (j, e), span in zip(pairs, sentence_times([j for j, _ in pairs], words)):
        line = {"ja": j, "en": e}
        if span:
            line["start"], line["end"] = round(span[0], 2), round(span[1], 2)
        lines.append(line)
    if want_translation and (TRANSLATE_BACKEND == "nllb" or _ollama_ok):
        # What is still long after the LLM had its say: cut where the
        # speaker paused.
        lines = split_at_pauses(lines, words, lambda: quiet if quiet is not None else silences(audio), translate_text)
        pairs = [(line["ja"], line["en"]) for line in lines]
    return ja, pairs, lines


# ---------------------------------------------------------------------------
# Pre-fetch: the audio of a video fetched ahead of the viewer and transcribed
# a batch of speech at a time, so the captions are ready before the video
# gets there.

# How much speech, in seconds, makes a batch for Whisper: the stretches of
# it are gathered until there is this much, and the batch ends in the next
# long pause.
PREFETCH_SPEECH = float(os.getenv("LIVETRANS_PREFETCH_SPEECH", os.getenv("LIVETRANS_PREFETCH_CHUNK", "60")))
# Speech this far from the speech before it is not gathered with it: a
# batch ends at a silence this long, however little it holds. What is said
# after a scene of music is not said in the context of what was said
# before, and a fetch that only keeps up with the viewer is not held up by
# a silence for the captions it already has the audio of.
PREFETCH_FAR_GAP = 5.0
# A batch that has run this long from its first speech without ending is
# ended: at the last long pause in it, or where there is none (speech that
# never pauses for GRID_HARD_PAUSE) at the longest pause there is.
PREFETCH_SPAN_LIMIT = 90.0
# How much of the audio is looked at for a batch, from where the last
# ended: enough for one to end in, by the limits above.
PREFETCH_SCAN = PREFETCH_SPAN_LIMIT + 2 * PREFETCH_FAR_GAP
# The audio is looked at again once this much more of it has arrived.
PREFETCH_SCAN_STEP = 1.0
# What the transcription of a batch is told of the one before, so a name
# carries over; Whisper reads at most ~224 tokens of prompt.
PREFETCH_PROMPT_CHARS = 120
PREFETCH_MAX_JOBS = 8
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
    command = [_tool("yt-dlp"), "--no-cache-dir", "--no-playlist", "-f", "ba[protocol!*=m3u8]/ba/b", "--get-url", page]
    deno = _tool("deno")
    if os.path.isabs(deno):
        command[1:1] = ["--js-runtimes", f"deno:{deno}"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if result.returncode != 0 or not lines:
        return None, (result.stderr.strip().splitlines() or ["yt-dlp found no media"])[-1]
    return lines[0], None


# How far into a pause a batch's edge goes, so the last word keeps its tail.
PREFETCH_CUT_LEAD = 0.3


def speech_stretches(audio):
    """Where the speech is in `audio`, as [(start, end), ...] in seconds:
    Silero's, with every pause of GRID_PAUSE_MIN or more kept and measured
    as it is, unpadded (its padding would take most of a second off each)."""
    from faster_whisper.vad import VadOptions, get_speech_timestamps

    found = get_speech_timestamps(
        audio, VadOptions(min_silence_duration_ms=int(GRID_PAUSE_MIN * 1000), speech_pad_ms=0)
    )
    return [(s["start"] / SAMPLE_RATE, s["end"] / SAMPLE_RATE) for s in found]


def choose_batch(speech, length, more, capped=False):
    """Where the next batch for Whisper ends, as (seconds, reason), or None
    to wait for more audio. `speech` is where the speech is in the audio
    from the end of the last batch on, `length` seconds of it; `more`,
    whether audio is still to come; `capped`, whether there is more already
    than was looked at, so that waiting would show nothing new.

    The stretches of speech are gathered from the first on, and the batch
    ends in the first pause of GRID_HARD_PAUSE or more by which there is
    PREFETCH_SPEECH of speech, or which is PREFETCH_FAR_GAP long: what
    follows is too far off to be heard with it. An edge is always in such a
    pause, which is a cut in the grid anyway, so no caption is cut by where
    its batch happened to end; only speech that runs PREFETCH_SPAN_LIMIT
    without one is cut elsewhere, in its longest pause, or failing any at
    PREFETCH_SPEECH. A silence of PREFETCH_FAR_GAP before the first speech
    is a batch of its own, with nothing in it. The reason is what is told
    of the cut at the edge."""
    def edge(start, end):
        return min(start + PREFETCH_CUT_LEAD, (start + end) / 2)

    if not speech:
        if not more and not capped:
            return length, "end of the audio"
        return (length - 1.0, f"silence {length - 1.0:.0f}s") if length >= PREFETCH_FAR_GAP else None
    first = speech[0][0]
    if first >= PREFETCH_FAR_GAP:
        return first - PREFETCH_CUT_LEAD, f"silence {first:.0f}s"
    spoken = 0.0
    last_long = None
    for (start, end), following in zip(speech, speech[1:] + [None]):
        spoken += end - start
        if following is None and not more and not capped:
            return length, "end of the audio"
        # After the last stretch, the silence so far: a pause still open.
        until = following[0] if following else length
        pause = until - end
        if pause < GRID_HARD_PAUSE:
            continue
        told = f"pause {pause:.1f}s" + ("" if following else " or more")
        if spoken >= PREFETCH_SPEECH or pause >= PREFETCH_FAR_GAP:
            return edge(end, until), told
        if following:
            last_long = (edge(end, until), told)
    if length - first < PREFETCH_SPAN_LIMIT and not capped:
        return None
    if last_long:
        return last_long
    pauses = [(a[1], b[0]) for a, b in zip(speech, speech[1:])]
    if pauses:
        start, end = max(pauses, key=lambda p: p[1] - p[0])
        return edge(start, end), f"no long pause in {PREFETCH_SPAN_LIMIT:.0f}s, the longest {end - start:.2f}s"
    return min(first + PREFETCH_SPEECH, length), f"no pause in {PREFETCH_SPAN_LIMIT:.0f}s"


# ---------------------------------------------------------------------------
# The cut grid: where a job's audio is cut into captions.
#
# Whisper and the LLM cut a stretch of speech into sentences differently
# each time they hear it, so a caption heard again came back cut
# otherwise, and the lines took the place of its neighbours too, some of
# them lost. The cuts are kept instead, as times in the video, and the
# words of every hearing are put into the pieces between them: a line is a
# piece, and a piece heard again is the same piece with other words. A
# long pause in the audio cuts from the start, hard: the audio either side
# is decoded on its own, so a word belongs to the piece it was heard in
# whatever time Whisper gives it. A sentence heard to end between two
# words, in its punctuation or by the LLM, cuts there for good, soft; one
# that a segment of Whisper's suggests cuts when the speaker paused there
# too. The grid only gets finer, so clicking a caption converges on the
# sentences and never moves a cut back.

# A pause this long always cuts.
GRID_HARD_PAUSE = 0.5
# A pause this long is where a sentence suggested to end is cut, and
# where a sentence heard to end is cut if one lies between the words.
GRID_SOFT_PAUSE = 0.2
# The shortest pause the grid knows of.
GRID_PAUSE_MIN = 0.15
# A piece is heard again with the neighbours that follow on within this
# many seconds, for Whisper to hear it in its context.
GRID_NEIGHBOUR_GAP = 1.0
# How far from a soft cut the gap between two words may lie and still be
# the one the cut falls in, when it reads like a sentence break or
# matches the cut's marks.
GRID_SNAP = 0.4
# How many characters either side of a soft cut are kept as its marks,
# and how far from the cut a gap matching them may lie: Whisper's times
# can be out by more than GRID_SNAP, and the text says where the cut is.
GRID_MARK_CHARS = 3
GRID_MARK_REACH = 1.0
# How far into the pauses either side of a hard piece its audio is
# decoded, so the first and last words keep their edges.
GRID_CLIP_PAD = 0.15


class CutGrid:
    """The speech, pauses and cuts of a job's audio, in seconds of the
    video. `cuts` are the middles of pauses, the edges of the batches the
    audio was heard in, and where sentences were heard to end; `hard` are
    the first two kinds."""

    def __init__(self):
        self.speech = []
        self.pauses = []
        self.cuts = []
        self.hard = set()
        # For a soft cut, the last characters before it and the first
        # after, as heard when it was made: where it falls among the words
        # of a later hearing, whatever times they are given.
        self.marks = {}
        # What made each cut, in a few words, for telling why a caption
        # starts and ends where it does.
        self.reasons = {}
        self.lock = threading.Lock()

    def add_speech(self, speech, began, end, end_reason="end of the audio"):
        """`speech`, the (start, end) stretches of it in the video from
        `began` to `end`, and the cuts the audio alone decides: at the
        edges, the end made for `end_reason` (the start is the end of the
        batch before, a cut already, or where the audio begins), and at
        every long pause."""
        pauses = [(a[1], b[0]) for a, b in zip(speech, speech[1:])]
        with self.lock:
            self.speech = sorted(self.speech + speech)
            self.pauses = sorted(self.pauses + pauses)
            self._cut(began, hard=True, reason="start of the audio")
            self._cut(end, hard=True, reason=end_reason)
            for a, b in pauses:
                if b - a >= GRID_HARD_PAUSE:
                    self._cut((a + b) / 2, hard=True, reason=f"pause {b - a:.1f}s")

    def _cut(self, at, hard=False, reason=""):
        """A cut at `at`, made for `reason`; whether it is new."""
        import bisect

        index = bisect.bisect_left(self.cuts, at)
        if (index < len(self.cuts) and abs(self.cuts[index] - at) < 1e-6) \
                or (index > 0 and abs(self.cuts[index - 1] - at) < 1e-6):
            return False
        self.cuts.insert(index, at)
        self.reasons[at] = reason
        if hard:
            self.hard.add(at)
        return True

    def cut_between(self, before, after, heard, tail="", head="", why=""):
        """A cut between the words `before` and `after`, (text, start,
        end): at the longest pause of GRID_SOFT_PAUSE or more lying under
        either word, which is as close as Whisper's word times place a
        break: the first word after a pause is timed early, into the pause
        and sometimes right up to the word before, so the pause lies under
        it rather than between the two, and the last word before a pause
        can run on into it. Without one, between the words themselves when
        the sentence was `heard` to end there, and not at all when it was
        only suggested. `tail` and `head` are the text either side, kept
        as the cut's marks; `why` is what asked for the cut, kept as its
        reason. Whether one was made."""
        low, high = before[1], after[2]
        with self.lock:
            found = max(((b - a, (a + b) / 2) for a, b in self.pauses if a < high and b > low), default=None)
            if found is not None and found[0] >= GRID_SOFT_PAUSE:
                at = found[1]
                reason = f"{why}, pause {found[0]:.2f}s"
            elif heard:
                at = min(max((before[2] + after[1]) / 2, low + 1e-3), high - 1e-3)
                reason = f"{why}, no pause"
            else:
                return False
            if not self._cut(at, reason=reason):
                return False
            self.marks[at] = (_content(tail)[-GRID_MARK_CHARS:], _content(head)[:GRID_MARK_CHARS])
            return True

    def pieces(self, low, high):
        """The pieces between cuts whose speech lies partly in `low`..`high`
        of the video (a piece without speech, by its cuts): [(from, to)].
        A piece whose speech only touches the stretch, within the
        rounding of a line's times, is not in it."""
        with self.lock:
            cuts = list(self.cuts)
        result = []
        for a, b in zip(cuts, cuts[1:]):
            inside = self.bounds(a, b) or (a, b)
            if inside[1] > low + 0.01 and inside[0] < high - 0.01:
                result.append((a, b))
        return result

    def bounds(self, a, b):
        """Where the speech in the piece `a`..`b` starts and ends, or None
        when there is none."""
        inside = [(max(s, a), min(e, b)) for s, e in self.speech if e > a and s < b]
        return (inside[0][0], inside[-1][1]) if inside else None

    def clips(self, low, high):
        """The hard pieces lying partly in `low`..`high`, as the stretches
        of the video to decode, each on its own: the speech in each, let
        run GRID_CLIP_PAD into the pauses either side but not past its
        cuts. A hard piece with no speech in it gives no clip."""
        with self.lock:
            hard = sorted(c for c in self.cuts if c in self.hard)
        result = []
        for a, b in zip(hard, hard[1:]):
            if b <= low or a >= high:
                continue
            inside = self.bounds(a, b)
            if inside:
                result.append((max(inside[0] - GRID_CLIP_PAD, a), min(inside[1] + GRID_CLIP_PAD, b)))
        return result

    def with_neighbours(self, pieces):
        """`pieces` and the ones before and after that follow on within
        GRID_NEIGHBOUR_GAP of their speech, as (from, to) of the whole."""
        with self.lock:
            cuts = list(self.cuts)
        low, high = pieces[0][0], pieces[-1][1]
        first, last = cuts.index(low), cuts.index(high)
        here = self.bounds(low, high) or (low, high)
        if first > 0:
            before = self.bounds(cuts[first - 1], low)
            if before and here[0] - before[1] <= GRID_NEIGHBOUR_GAP:
                low = cuts[first - 1]
        if last < len(cuts) - 1:
            after = self.bounds(high, cuts[last + 1])
            if after and after[0] - here[1] <= GRID_NEIGHBOUR_GAP:
                high = cuts[last + 1]
        return low, high


def _content_offsets(texts):
    """Where each of `texts` begins and ends in their content (the
    characters that are not punctuation or spaces) joined."""
    offsets, at = [], 0
    for text in texts:
        size = len(_content(text))
        offsets.append((at, at + size))
        at += size
    return offsets


def hear_pieces(grid, audio, began, beam_size, prompt, within=None):
    """`audio`, the video from `began` on, heard by its hard pieces, and
    its words put into the pieces of `grid`: the lines [{"ja", "en",
    "start", "end"}] of the pieces with words in them, those partly in
    `within` (seconds of the video) when given. Where a sentence ends
    inside a piece in `within`, a cut is made (see CutGrid). A piece's
    times are its speech's."""
    import bisect

    low, high = within or (began, began + audio.size / SAMPLE_RATE)
    clips = grid.clips(began, began + audio.size / SAMPLE_RATE)
    words, breaks = [], []
    run_whisper(
        audio, beam_size=beam_size, prompt=prompt, words=words, breaks=breaks,
        clips=[(max(a - began, 0), b - began) for a, b in clips],
    )
    words = [(text, began + start, began + end) for text, start, end in words]
    if not words:
        return []
    # The clip each word was heard in: that of its segment, which Whisper
    # decoded within one clip whatever times it gave the words, so the
    # clip its words lie most in; by its start when they lie in none.
    heard_in = [0] * len(words)
    for (index, start), (next_index, _) in zip(breaks, breaks[1:] + [(len(words), None)]):
        span = (words[index][1], max(words[next_index - 1][2], words[index][1] + 1e-3))
        clip = max(
            range(len(clips)),
            key=lambda k: (max(min(span[1], clips[k][1]) - max(span[0], clips[k][0]), 0), -abs(clips[k][0] - began - start)),
        )
        for j in range(index, next_index):
            heard_in[j] = clip
    breaks = {index for index, _ in breaks}

    def grouped():
        """The words of each piece, in order: [(from, to, [word indices])].
        A hard cut lies between clips, and the words of a clip are the
        words of the hard piece it covers. A soft cut falls in the gap
        between two words nearest it, unless a gap within GRID_SNAP of it
        reads more like a sentence break: Whisper's times put a word a few
        tenths of a second off, and the first word of a sentence would
        otherwise end the one before, cut in two."""
        with grid.lock:
            cuts = list(grid.cuts)
            hard = set(grid.hard)
            marks = dict(grid.marks)
        result = []
        for clip, (clip_from, clip_to) in enumerate(clips):
            members = [j for j in range(len(words)) if heard_in[j] == clip]
            if not members:
                continue
            first = bisect.bisect_right(cuts, clip_from) - 1
            last = bisect.bisect_left(cuts, clip_to)
            soft = [c for c in cuts[first + 1:last] if c not in hard]
            gaps = [(words[members[k]][2] + words[members[k + 1]][1]) / 2 for k in range(len(members) - 1)]
            texts = [_content(words[j][0]) for j in members]
            boundaries = []  # the first member of each soft piece after the first
            for cut in soft:
                tail, head = marks.get(cut, ("", ""))

                def marked(k):
                    return bool(tail and "".join(texts[:k + 1]).endswith(tail)) \
                        or bool(head and "".join(texts[k + 1:]).startswith(head))

                def score(k):
                    return (1.0 if marked(k) else 0.0) + break_score(members[k]) - abs(gaps[k] - cut)

                candidates = [
                    k for k in range(len(gaps))
                    if abs(gaps[k] - cut) <= GRID_SNAP or (abs(gaps[k] - cut) <= GRID_MARK_REACH and marked(k))
                ]
                if candidates:
                    chosen = max(candidates, key=score) + 1
                else:
                    chosen = bisect.bisect_right([(words[j][1] + words[j][2]) / 2 for j in members], cut)
                boundaries.append(max(chosen, boundaries[-1] if boundaries else 0))
            edges = [cuts[first]] + soft + [cuts[last]]
            for piece, (a, b) in enumerate(zip(edges, edges[1:])):
                inside = members[(boundaries[piece - 1] if piece else 0):(boundaries[piece] if piece < len(soft) else None)]
                if inside:
                    result.append((a, b, inside))
        return result

    def break_score(k):
        """How much the gap after word k reads like a sentence break, in
        seconds of distance from a cut it is worth."""
        before, after = words[k][0].rstrip(" \u3000"), words[k + 1][0]
        if _SENTENCE_END.search(before[-1:]):
            return 0.5
        score = 0.0
        if after.startswith((" ", "\u3000")) or words[k][0].endswith((" ", "\u3000")):
            score += 0.3  # Whisper writes a space where the speaker broke off
        return score

    def cut_after(i, heard, why):
        """A cut after word i, asked for by `why`, when the pieces either
        side can stand alone and the cut falls in `within`."""
        if not (low <= words[i][2] and words[i + 1][1] <= high) or heard_in[i] != heard_in[i + 1]:
            return False
        for _, _, members in grouped():
            if i in members:
                k = members.index(i)
                before = "".join(words[j][0] for j in members[:k + 1])
                after = "".join(words[j][0] for j in members[k + 1:])
                if len(_content(before)) < SPLIT_MIN_PIECE_CHARS or len(_content(after)) < SPLIT_MIN_PIECE_CHARS:
                    return False
                if before.count("「") + before.count("『") > before.count("」") + before.count("』"):
                    return False  # a sentence being quoted ends inside the one quoting it
                return grid.cut_between(words[i], words[i + 1], heard, tail=before, head=after, why=why)
        return False

    # Where Whisper ended a sentence: heard to, in its punctuation; or
    # suggested, by a segment of its. No guess of our own from the words
    # themselves: a word that can end a sentence ends a clause as often,
    # and a guess that is wrong once is a cut for good.
    for i in range(len(words) - 1):
        so_far = "".join(words[j][0] for j in range(i + 1)).rstrip(" \u3000")
        if _SENTENCE_END.search(so_far[-1:]):
            cut_after(i, heard=True, why="Whisper's sentence end")
        elif i + 1 in breaks:
            cut_after(i, heard=False, why="Whisper's segment")

    pieces = grouped()
    texts = ["".join(words[j][0] for j in members).strip() for _, _, members in pieces]
    pairs = None
    if TRANSLATE_BACKEND != "nllb" and _ollama_ok and any(not _is_untranslatable(t) for t in texts):
        pairs = translate_ollama(texts)
    if pairs:
        # Where the LLM ended a sentence inside a piece: a cut there.
        chars = [j for j, (text, _, _) in enumerate(words) for ch in text if ch not in _BOUNDARY_NOISE]
        ends = [end for _, end in _content_offsets([ja for ja, _ in pairs])][:-1]
        for end in ends:
            if 0 < end < len(chars) and chars[end] == chars[end - 1] + 1:
                cut_after(chars[end - 1], heard=True, why="the LLM's sentence end")
        pieces = grouped()
        texts = ["".join(words[j][0] for j in members).strip() for _, _, members in pieces]
        # Each piece's English: that of the LLM's sentences lying within it,
        # or its own translation where a sentence straddles two pieces.
        spans = _content_offsets(texts)
        sentences = _content_offsets([ja for ja, _ in pairs])
        english = []
        for a, b in spans:
            inside = [en for (c, d), (_, en) in zip(sentences, pairs) if a <= c and d <= b]
            straddling = any(c < a < d or c < b < d for c, d in sentences)
            english.append(None if straddling or not inside else " ".join(inside))
    else:
        english = [None] * len(texts)
    lines = []
    for (a, b, members), text, en in zip(pieces, texts, english):
        if not text:
            continue
        if en is None:
            try:
                en = translate_text(text)
            except Exception as exc:
                print(f"piece not translated: {exc}", flush=True)
                en = ""
        start, end = grid.bounds(a, b) or (words[members[0]][1], words[members[-1]][2])
        if within is None or (a >= low - 1e-6 and b <= high + 1e-6):
            lines.append({"ja": text, "en": en, "start": round(start, 2), "end": round(end, 2)})
            tell(f"{'heard again ' if within else ''}{clock(start)}–{clock(end)}  {text}\n"
                 f"   starts: {grid.reasons.get(a) or '?'} · ends: {grid.reasons.get(b) or '?'}")
    return lines


class PrefetchJob:
    def __init__(self, url, page, headers, duration, start=0.0):
        self.id = uuid.uuid4().hex[:12]
        self.url = url
        self.page = page
        self.headers = {**PREFETCH_HEADERS, **(headers or {})}
        self.duration = duration
        # Where in the video the audio begins: the viewer's place when the
        # job was asked for, not always the top.
        self.offset = max(float(start or 0), 0.0)
        self.audio = np.zeros(0, dtype=np.float32)
        self.audio_lock = threading.Lock()
        self.fetch_done = False
        self.lines = []
        self.text = ""
        self.grid = CutGrid()
        self.ready = self.offset
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
        """Seconds of audio held, from `offset` on."""
        return self.audio.size / SAMPLE_RATE

    def stop(self):
        self.stop_event.set()
        if self.process and self.process.poll() is None:
            self.process.kill()

    def retire(self):
        """Stopped for another stretch of the same video. What it captioned
        can still be heard again; the audio past that is let go."""
        self.stop()
        with self.audio_lock:
            self.audio = self.audio[:int(max(self.ready - self.offset, 0) * SAMPLE_RATE)].copy()
        if self.state == "running":
            self.state = "stopped"

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
            "-headers", header_lines,
            # Without -copyts a seek into an HLS stream can land at the start
            # of the segment the moment is in, up to a segment early, and the
            # audio is then taken for later than it is. Without -seek2any it
            # can land late instead: the HLS demuxer drops everything up to
            # the next video keyframe after the moment, seconds away in a
            # segment with few of them, and the audio that starts there is
            # taken for the moment, so every caption comes early by that
            # much. With both, the seek is exact to a frame at every point
            # tried; the audio needs no keyframe to be decoded from.
            *(["-ss", f"{self.offset:.3f}", "-copyts", "-seek2any", "1"] if self.offset > 0 else []), "-i", media,
            "-vn", "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "s16le", "-",
        ]
        print(f"prefetch {self.id}: fetching", flush=True)
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
            self.duration = self.offset + self.fetched
        print(f"prefetch {self.id}: fetched {self.fetched:.0f}s from {self.offset:.0f}s", flush=True)

    def _transcribe(self):
        position = 0.0
        # How far the audio had come when it was last looked at for a batch.
        looked = -1.0
        while not self.stop_event.is_set() and self.state == "running":
            with self.audio_lock:
                have = self.fetched
                done = self.fetch_done
            if done and have <= position + 0.05:
                self.state = "done"
                print(f"prefetch {self.id}: done, {len(self.lines)} lines", flush=True)
                return
            window_end = min(have, position + PREFETCH_SCAN)
            capped = window_end < have
            if self.paused.is_set() or (not done and not capped and window_end - looked < PREFETCH_SCAN_STEP):
                time.sleep(0.25)
                continue
            looked = window_end
            with self.audio_lock:
                window = self.audio[int(position * SAMPLE_RATE):int(window_end * SAMPLE_RATE)].copy()
            speech = speech_stretches(window)
            batch = choose_batch(speech, window.size / SAMPLE_RATE, more=not done, capped=capped)
            if batch is None:
                time.sleep(0.25)
                continue
            length, reason = batch
            boundary = position + length
            try:
                self._transcribe_batch(
                    self.offset + position, self.offset + boundary, window[:int(length * SAMPLE_RATE)],
                    [(self.offset + position + a, self.offset + position + min(b, length)) for a, b in speech if a < length],
                    reason,
                )
            except Exception as exc:
                self.fail(f"transcription: {type(exc).__name__}: {exc}")
                return
            if self.stop_event.is_set():
                return
            position = boundary
            looked = -1.0
            self.ready = self.offset + boundary

    def _transcribe_batch(self, start, end, audio, speech, reason):
        """`audio` is the video from `start` to `end`, `speech` where the
        speech is in it (in seconds of the video), and `reason` what ended
        it there."""
        t0 = time.time()
        self.grid.add_speech(speech, start, end, end_reason=reason)
        lines = hear_pieces(self.grid, audio, start, beam_size=5, prompt=self.text[-PREFETCH_PROMPT_CHARS:])
        ja = "".join(line["ja"] for line in lines)
        if self.stop_event.is_set():
            # Stopped while this was heard: its audio may be let go already.
            return
        self.lines.extend(lines)
        self.text += ja
        print(f"prefetch {self.id}: {start:.0f}-{end:.0f}s, {len(lines)} lines in {time.time() - t0:.1f}s", flush=True)

    def rehear(self, start, end, vad=False):
        """The pieces of the grid at `start`..`end` heard again from the
        fetched audio, with the wider search, the lines before them as
        context, and the neighbours that follow on in the audio heard with
        them, so a sentence is heard whole; only those pieces' lines come
        back. Only the speech of the pieces is decoded, so `vad` (once
        asking for that, for a gap in the captions that may be music)
        changes nothing."""
        pieces = self.grid.pieces(start, end)
        if not pieces:
            return []
        low, high = self.grid.with_neighbours(pieces)
        with self.audio_lock:
            from_sample = int(max(low - self.offset, 0) * SAMPLE_RATE)
            audio = self.audio[from_sample:int(max(high - self.offset, 0) * SAMPLE_RATE)].copy()
        before = [line["ja"] for line in self.lines if line.get("end", 0) <= start + 0.05][-2:]
        t0 = time.time()
        began = self.offset + from_sample / SAMPLE_RATE
        lines = hear_pieces(
            self.grid, audio, began, beam_size=10, prompt="".join(before), within=(pieces[0][0], pieces[-1][1])
        )
        print(f"prefetch {self.id}: {start:.1f}-{end:.1f}s heard again, {len(lines)} lines in {time.time() - t0:.1f}s",
              flush=True)
        return lines

    def status(self, since=0):
        with self.audio_lock:
            last = self.audio[-SAMPLE_RATE:]
        return {
            "state": "paused" if self.state == "running" and self.paused.is_set() else self.state,
            "error": self.error,
            "duration": self.duration,
            "start": round(self.offset, 2),
            "fetched": round(self.offset + self.fetched, 2),
            # Loudness of the last second fetched, on the int16 scale: a
            # fetch that yields silence is a fetch of the wrong thing.
            "level": round(float(np.sqrt(np.mean(last * last))) * 32768, 1) if last.size else 0,
            "ready": round(self.ready, 2),
            "count": len(self.lines),
            "lines": self.lines[since:],
        }


def start_prefetch(url, page, headers, duration, start=0.0):
    with _jobs_lock:
        for job in _jobs.values():
            if job.page == page and job.state == "running":
                job.retire()
        while len(_jobs) >= PREFETCH_MAX_JOBS:
            oldest = min(_jobs.values(), key=lambda j: j.started)
            oldest.stop()
            del _jobs[oldest.id]
        job = PrefetchJob(url, page, headers, duration, start)
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
        elif self.path.startswith("/events"):
            from urllib.parse import parse_qs, urlparse

            query = parse_qs(urlparse(self.path).query)
            self._send(200, events_since(int(query.get("since", ["0"])[0])))
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
                    request.get("headers") or {}, request.get("duration"), request.get("start") or 0,
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
                vad = query.get("vad", ["0"])[0] == "1"
                self._send(200, {"lines": job.rehear(start, end, vad=vad)})
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
            # The Mac cuts utterances by loudness alone, so a piano or a music
            # bed after a quiet stretch arrives here as one: Whisper's own
            # voice filter drops it, where Whisper alone invents a line.
            ja, pairs, lines = transcribe_and_translate(audio, beam_size, prompt, want_translation, vad=True)
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

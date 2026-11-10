"""Times words by CTC forced alignment: nemo-v2's and Qwen3-ASR's, which
come with no times of their own, for the captions and the timeline.

Run by the server in the align venv (see setup.sh). Reads on stdin one
line of JSON, {"samples": N, "pieces": [{"start", "length", "words":
[[start, end, text, probability], ...]}, ...]} (times in seconds; a word's
within its piece), then N samples of 16 kHz mono audio as little-endian
int16. Writes {"pieces": [[[start, end] or null, ...], ...]}: each word's
time measured within its piece, in the same order. With "read": [text,
...] in the request, also "readings": [[kana, ...], ...], each text's
reading a character at a time (a word's reading on its first character,
"" on the rest), for telling whether two recognizers heard the same.
Only times and readings leave; the text comes in by the pipe and is not
kept anywhere. With --serve it stays, the model loaded, and answers one
request after another, a line each. It runs on the GPU where there is one
(LIVETRANS_ALIGN_DEVICE): on the CPU it took two thirds of the captioning
time, 13 s of each 19 s batch.

The model is ReazonSpeech's Japanese wav2vec2, trained on Japanese TV;
its CTC blank is config.pad_token_id (0), not the tokenizer's pad. A
character it does not know is aligned by its kana reading (pykakasi), and
one with no reading it knows is left out of the word. A vowel that only
draws out the one before it (でもなあ, そう, ねえ, ー) is not aligned: it has
no start of its own to find, and the model's faint guess at it wanders to
the next same vowel, even the next speaker's (でもな｜あ葵 for でもなあ｜葵);
it is timed just after the character it draws out."""
import json
import os
import sys

import numpy as np

MODEL = "reazon-research/japanese-wav2vec2-large-rs35kh"


# Each kana's vowel, for telling a vowel that draws out the one before it.
_VOWEL_ROWS = {
    "a": "あかさたなはまやらわがざだばぱぁゃゎ",
    "i": "いきしちにひみりぎじぢびぴぃ",
    "u": "うくすつぬふむゆるぐずづぶぷぅゅ",
    "e": "えけせてねへめれげぜでべぺぇ",
    "o": "おこそとのほもよろをごぞどぼぽぉょ",
}
VOWEL_OF = {kana: vowel for vowel, row in _VOWEL_ROWS.items() for kana in row}
# The vowels a bare vowel kana draws out: お and う both draw out an o (そう).
DRAWS_OUT = {"あ": "a", "い": "i", "う": "uo", "え": "e", "お": "o"}


def _hiragana(text):
    return "".join(chr(ord(ch) - 0x60) if "ァ" <= ch <= "ヶ" else ch for ch in text)


def draws_out(reading_before, text):
    """Whether `text`, one character, only draws out the vowel `reading_
    before` (the kana before it) ends in: a long-vowel mark after any kana,
    or a bare vowel kana after one with that vowel."""
    if text == "ー":
        return bool(reading_before)
    vowel = DRAWS_OUT.get(_hiragana(text))
    last = VOWEL_OF.get(_hiragana(reading_before[-1:]))
    return bool(vowel and last and last in vowel)


def viterbi(lp, tokens, blank):
    """The frames each token holds on the likeliest CTC path, (first, last)."""
    frames, count = lp.shape[0], len(tokens)
    states = 2 * count + 1
    labels = np.full(states, blank)
    labels[1::2] = tokens
    low = -1e30
    score = np.full(states, low)
    score[0] = lp[0, labels[0]]
    if states > 1:
        score[1] = lp[0, labels[1]]
    back = np.zeros((frames, states), dtype=np.int8)
    skip_ok = np.zeros(states, bool)
    skip_ok[3::2] = labels[3::2] != labels[1:-2:2]
    for t in range(1, frames):
        step = np.r_[low, score[:-1]]
        skip = np.where(skip_ok, np.r_[low, low, score[:-2]], low)
        options = np.stack([score, step, skip])
        best = options.argmax(0)
        back[t] = best
        score = options[best, np.arange(states)] + lp[t, labels]
    state = states - 1 if states == 1 or score[states - 1] >= score[states - 2] else states - 2
    if score[state] < low / 2:
        return None
    path = np.empty(frames, dtype=np.int64)
    for t in range(frames - 1, -1, -1):
        path[t] = state
        state -= int(back[t, state])
    spans = []
    for k in range(count):
        held = np.flatnonzero(path == 2 * k + 1)
        spans.append((int(held[0]), int(held[-1])) if held.size else None)
    return spans


def read_request():
    """The next request on stdin, (header, audio), or None at its end."""
    line = sys.stdin.buffer.readline()
    if not line.strip():
        return None
    header = json.loads(line)
    audio = np.frombuffer(sys.stdin.buffer.read(header["samples"] * 2), dtype="<i2").astype(np.float32) / 32768
    return header, audio


def main():
    import pykakasi
    import torch
    from transformers import AutoModelForCTC, AutoProcessor

    serve = "--serve" in sys.argv
    device = os.getenv("LIVETRANS_ALIGN_DEVICE") or ("cuda" if torch.cuda.is_available() else "cpu")
    torch.set_num_threads(int(os.getenv("LIVETRANS_ALIGN_THREADS", "4")))
    processor = AutoProcessor.from_pretrained(MODEL)
    model = AutoModelForCTC.from_pretrained(MODEL).to(device).eval()
    if device == "cuda":
        model = model.half()
    blank = model.config.pad_token_id
    single = {k: v for k, v in processor.tokenizer.get_vocab().items() if len(k) == 1}
    kakasi = pykakasi.kakasi()

    def ids(text):
        out = []
        for ch in text:
            if ch in single:
                out.append(single[ch])
                continue
            for part in kakasi.convert(ch):
                out += [single[k] for k in part["hira"] if k in single]
        return out

    def reading(text):
        """`text`'s reading, a character at a time."""
        chars = []
        for part in kakasi.convert(text):
            chars += [part["hira"]] + [""] * (len(part["orig"]) - 1)
        return chars[:len(text)] + [""] * (len(text) - len(chars))

    def answer(header, audio):
        result = []
        for piece in header["pieces"]:
            words = piece["words"]
            clip = audio[int(piece["start"] * 16000):int((piece["start"] + piece["length"]) * 16000)]
            # A clip under a second is heard with silence after it to make
            # one up, as the model takes no less; the times stay the clip's.
            if 0 < clip.size < 16000:
                clip = np.concatenate([clip, np.zeros(16000 - clip.size, np.float32)])
            timed = [None] * len(words)
            if words and clip.size >= 16000:
                with torch.no_grad():
                    x = processor(clip, sampling_rate=16000, return_tensors="pt").input_values.to(device)
                    if device == "cuda":
                        x = x.half()
                    lp = torch.log_softmax(model(x).logits[0].float(), -1).cpu().numpy()
                hop = clip.size / 16000 / lp.shape[0]
                tokens, owner, drawn = [], [], set()
                for i, word in enumerate(words):
                    if i and len(word[2]) == 1 and draws_out("".join(part["hira"] for part in kakasi.convert(words[i - 1][2])), word[2]):
                        drawn.add(i)
                        continue
                    word_ids = ids(word[2])
                    tokens += word_ids
                    owner += [i] * len(word_ids)
                spans = viterbi(lp, np.array(tokens), blank) if tokens and len(tokens) < lp.shape[0] else None
                if spans:
                    for i in range(len(words)):
                        held = [spans[k] for k in range(len(tokens)) if owner[k] == i and spans[k] is not None]
                        if held:
                            timed[i] = [round(min(h[0] for h in held) * hop, 3), round((max(h[1] for h in held) + 1) * hop, 3)]
                        elif i in drawn and timed[i - 1]:
                            timed[i] = [timed[i - 1][1], round(timed[i - 1][1] + hop, 3)]
            result.append(timed)
        found = {"pieces": result}
        if "read" in header:
            found["readings"] = [reading(text) for text in header["read"]]
        return found

    while (request := read_request()) is not None:
        try:
            found = answer(*request)
        except Exception as exc:
            if not serve:
                raise
            found = {"error": f"{type(exc).__name__}: {exc}"[:300]}
        if device == "cuda":
            # What a request held goes back between them; the weights stay.
            torch.cuda.empty_cache()
        sys.__stdout__.write(json.dumps(found, ensure_ascii=False) + "\n")
        sys.__stdout__.flush()
        if not serve:
            return


if __name__ == "__main__":
    # Libraries print as they load; only the answer goes to stdout.
    sys.stdout = sys.stderr
    main()

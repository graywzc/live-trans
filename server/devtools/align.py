"""Re-times Whisper's words by CTC forced alignment, for the dev timeline.

Run by the server in the align venv (see setup.sh). Reads on stdin one
line of JSON, {"samples": N, "pieces": [{"start", "length", "words":
[[start, end, text, probability], ...]}, ...]} (times in seconds; a word's
within its piece), then N samples of 16 kHz mono audio as little-endian
int16. Writes {"pieces": [[[start, end] or null, ...], ...]}: each word's
time re-measured within its piece, in the same order. Only times leave;
the text comes in by the pipe and is not kept anywhere.

The model is ReazonSpeech's Japanese wav2vec2, trained on Japanese TV;
its CTC blank is config.pad_token_id (0), not the tokenizer's pad. A
character it does not know is aligned by its kana reading (pykakasi), and
one with no reading it knows is left out of the word."""
import json
import sys

import numpy as np

MODEL = "reazon-research/japanese-wav2vec2-large-rs35kh"


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


def main():
    import pykakasi
    import torch
    from transformers import AutoModelForCTC, AutoProcessor

    header = json.loads(sys.stdin.buffer.readline())
    audio = np.frombuffer(sys.stdin.buffer.read(header["samples"] * 2), dtype="<i2").astype(np.float32) / 32768
    device = "cuda" if torch.cuda.is_available() else "cpu"
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

    result = []
    for piece in header["pieces"]:
        words = piece["words"]
        clip = audio[int(piece["start"] * 16000):int((piece["start"] + piece["length"]) * 16000)]
        timed = [None] * len(words)
        if words and clip.size >= 16000:
            with torch.no_grad():
                x = processor(clip, sampling_rate=16000, return_tensors="pt").input_values.to(device)
                if device == "cuda":
                    x = x.half()
                lp = torch.log_softmax(model(x).logits[0].float(), -1).cpu().numpy()
            hop = clip.size / 16000 / lp.shape[0]
            tokens, owner = [], []
            for i, word in enumerate(words):
                word_ids = ids(word[2])
                tokens += word_ids
                owner += [i] * len(word_ids)
            spans = viterbi(lp, np.array(tokens), blank) if tokens and len(tokens) < lp.shape[0] else None
            if spans:
                for i in range(len(words)):
                    held = [spans[k] for k in range(len(tokens)) if owner[k] == i and spans[k] is not None]
                    if held:
                        timed[i] = [round(min(h[0] for h in held) * hop, 3), round((max(h[1] for h in held) + 1) * hop, 3)]
        result.append(timed)
    json.dump({"pieces": result}, sys.__stdout__)


if __name__ == "__main__":
    # Libraries print as they load; only the answer goes to stdout.
    sys.stdout = sys.stderr
    main()

"""Hears each caption's stretch again with Qwen3-ASR-1.7B, for dev mode's
comparison of recognizers beside the captions' own (k2).

Run by the server in the hear_qwen venv (see setup.sh), with the stdin and
stdout of hear_nemo.py: {"samples": N, "clips": [[start, end], ...]} and
the audio in, {"i": k, "text": "..."} per clip out.

The model is Qwen/Qwen3-ASR-1.7B (Apache-2.0), told the language is
Japanese."""
import contextlib
import json
import sys

import numpy as np

MODEL = "Qwen/Qwen3-ASR-1.7B"
# Eight at a time: about 5 GB beside the server and its other workers.
BATCH = 8


def main():
    header = json.loads(sys.stdin.buffer.readline())
    audio = np.frombuffer(sys.stdin.buffer.read(header["samples"] * 2), dtype="<i2").astype(np.float32) / 32768
    out = sys.stdout
    with contextlib.redirect_stdout(sys.stderr):
        import torch
        from qwen_asr import Qwen3ASRModel

        model = Qwen3ASRModel.from_pretrained(MODEL, dtype=torch.bfloat16, device_map="cuda:0",
                                              max_inference_batch_size=BATCH, max_new_tokens=256)
        clips = header["clips"]
        for first in range(0, len(clips), BATCH):
            batch = clips[first:first + BATCH]
            heard = model.transcribe([(audio[int(a * 16000):int(b * 16000)], 16000) for a, b in batch], language="Japanese")
            for k, r in enumerate(heard):
                out.write(json.dumps({"i": first + k, "text": r.text.strip()}, ensure_ascii=False) + "\n")
            out.flush()


if __name__ == "__main__":
    main()

"""Hears clips of speech with Qwen3-ASR-1.7B, one of the three recognizers
the captions are heard by, on the GPU (on the CPU it is too slow to keep
up: about 24 s per minute of speech).

Run by the server in the hear_qwen venv (see setup.sh), with the stdin and
stdout of hear_nemo.py: {"samples": N, "clips": [[start, end], ...]} and
the audio in, {"i": k, "text": "..."} per clip out, and --serve as there.

The model is Qwen/Qwen3-ASR-1.7B (Apache-2.0), told the language is
Japanese."""
import contextlib
import json
import sys

import numpy as np

MODEL = "Qwen/Qwen3-ASR-1.7B"
# Eight at a time: about 5 GB beside the server and its other workers.
BATCH = 8


def read_request():
    """The next request on stdin, (header, audio), or None at its end."""
    line = sys.stdin.buffer.readline()
    if not line.strip():
        return None
    header = json.loads(line)
    audio = np.frombuffer(sys.stdin.buffer.read(header["samples"] * 2), dtype="<i2").astype(np.float32) / 32768
    return header, audio


def main():
    serve = "--serve" in sys.argv
    out = sys.stdout
    with contextlib.redirect_stdout(sys.stderr):
        import torch
        from qwen_asr import Qwen3ASRModel

        model = Qwen3ASRModel.from_pretrained(MODEL, dtype=torch.bfloat16, device_map="cuda:0",
                                              max_inference_batch_size=BATCH, max_new_tokens=256)
        while (request := read_request()) is not None:
            header, audio = request
            try:
                clips = header["clips"]
                for first in range(0, len(clips), BATCH):
                    batch = clips[first:first + BATCH]
                    heard = model.transcribe([(audio[int(a * 16000):int(b * 16000)], 16000) for a, b in batch], language="Japanese")
                    for k, r in enumerate(heard):
                        out.write(json.dumps({"i": first + k, "text": r.text.strip()}, ensure_ascii=False) + "\n")
                    out.flush()
            except Exception as exc:
                if not serve:
                    raise
                out.write(json.dumps({"error": f"{type(exc).__name__}: {exc}"[:300]}) + "\n")
            if not serve:
                return
            # What a batch held of the GPU goes back between requests: the
            # model's own weights stay, the rest is the translator's room.
            torch.cuda.empty_cache()
            out.write('{"done": true}\n')
            out.flush()


if __name__ == "__main__":
    main()

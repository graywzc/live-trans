"""Hears clips of speech with ReazonSpeech nemo-v2, one of the three
recognizers the captions are heard by, and the words on the timeline.

Run by the server in the hear_nemo venv (see setup.sh). Reads on stdin one
line of JSON, {"samples": N, "clips": [[start, end], ...]} in seconds of
the audio, then N samples of 16 kHz mono audio as little-endian int16.
Writes one line of JSON per clip as it is heard, {"i": k, "text": "..."}.
With --serve it stays, the model loaded, and takes one such request after
another, each answer ending with {"done": true} (or {"error": ...} first).

The model is reazon-research/reazonspeech-nemo-v2 (Apache-2.0), an RNN-T
that punctuates; given half a second of silence either side, as the
reazonspeech package gives it. It runs on the CPU (LIVETRANS_NEMO_DEVICE),
where it hears an episode in about a minute and a half and leaves the GPU
to the translator and the others, with LIVETRANS_NEMO_THREADS threads."""
import contextlib
import json
import os
import sys

import numpy as np

MODEL = "reazon-research/reazonspeech-nemo-v2"
DEVICE = os.getenv("LIVETRANS_NEMO_DEVICE", "cpu")
THREADS = int(os.getenv("LIVETRANS_NEMO_THREADS", "8"))


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
        from huggingface_hub import hf_hub_download
        from nemo.collections.asr.models import EncDecRNNTBPEModel

        torch.set_num_threads(THREADS)
        model = EncDecRNNTBPEModel.restore_from(hf_hub_download(MODEL, "reazonspeech-nemo-v2.nemo"), map_location=DEVICE).eval()
        pad = np.zeros(8000, np.float32)
        while (request := read_request()) is not None:
            header, audio = request
            try:
                for i, (start, end) in enumerate(header["clips"]):
                    clip = np.concatenate([pad, audio[int(start * 16000):int(end * 16000)], pad])
                    with torch.inference_mode():
                        hyps = model.transcribe([clip], batch_size=1, verbose=False)
                    hyp = (hyps[0] if isinstance(hyps, tuple) else hyps)[0]
                    out.write(json.dumps({"i": i, "text": getattr(hyp, "text", hyp).strip()}, ensure_ascii=False) + "\n")
                    out.flush()
            except Exception as exc:
                if not serve:
                    raise
                out.write(json.dumps({"error": f"{type(exc).__name__}: {exc}"[:300]}) + "\n")
            if not serve:
                return
            out.write('{"done": true}\n')
            out.flush()


if __name__ == "__main__":
    main()

"""Hears each caption's stretch again with ReazonSpeech nemo-v2, for dev
mode's comparison of recognizers beside the captions' own (k2).

Run by the server in the hear_nemo venv (see setup.sh). Reads on stdin one
line of JSON, {"samples": N, "clips": [[start, end], ...]} in seconds of
the audio, then N samples of 16 kHz mono audio as little-endian int16.
Writes one line of JSON per clip as it is heard, {"i": k, "text": "..."}.

The model is reazon-research/reazonspeech-nemo-v2 (Apache-2.0), an RNN-T
that punctuates; given half a second of silence either side, as the
reazonspeech package gives it."""
import contextlib
import json
import sys

import numpy as np

MODEL = "reazon-research/reazonspeech-nemo-v2"


def main():
    header = json.loads(sys.stdin.buffer.readline())
    audio = np.frombuffer(sys.stdin.buffer.read(header["samples"] * 2), dtype="<i2").astype(np.float32) / 32768
    out = sys.stdout
    with contextlib.redirect_stdout(sys.stderr):
        import torch
        from huggingface_hub import hf_hub_download
        from nemo.collections.asr.models import EncDecRNNTBPEModel

        model = EncDecRNNTBPEModel.restore_from(hf_hub_download(MODEL, "reazonspeech-nemo-v2.nemo"), map_location="cuda").eval()
        pad = np.zeros(8000, np.float32)
        for i, (start, end) in enumerate(header["clips"]):
            clip = np.concatenate([pad, audio[int(start * 16000):int(end * 16000)], pad])
            with torch.inference_mode():
                hyps = model.transcribe([clip], batch_size=1, verbose=False)
            hyp = (hyps[0] if isinstance(hyps, tuple) else hyps)[0]
            out.write(json.dumps({"i": i, "text": getattr(hyp, "text", hyp).strip()}, ensure_ascii=False) + "\n")
            out.flush()


if __name__ == "__main__":
    main()

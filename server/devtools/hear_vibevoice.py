"""Hears each caption's stretch again with VibeVoice-ASR, for dev mode's
comparison of recognizers beside the captions' own (k2).

Run by the server in the hear_vibevoice venv (see setup.sh), with the
stdin and stdout of hear_nemo.py: {"samples": N, "clips": [[start, end],
...]} and the audio in, {"i": k, "text": "..."} per clip out.

The model is microsoft/VibeVoice-ASR-HF (MIT), 8.3B parameters at full
precision: about 17 GB of GPU memory, so the server lets the translator go
first. It answers with segments of speaker and text; their texts are
joined. Whole episodes or long pieces make it loop, so it is given one
caption at a time."""
import contextlib
import json
import sys

import numpy as np

MODEL = "microsoft/VibeVoice-ASR-HF"


def main():
    header = json.loads(sys.stdin.buffer.readline())
    audio = np.frombuffer(sys.stdin.buffer.read(header["samples"] * 2), dtype="<i2").astype(np.float32) / 32768
    out = sys.stdout
    with contextlib.redirect_stdout(sys.stderr):
        import librosa
        import torch
        from transformers import AutoProcessor, VibeVoiceAsrForConditionalGeneration

        proc = AutoProcessor.from_pretrained(MODEL)
        rate = proc.feature_extractor.sampling_rate
        model = VibeVoiceAsrForConditionalGeneration.from_pretrained(MODEL, dtype=torch.bfloat16, device_map={"": 0}).eval()
        for i, (start, end) in enumerate(header["clips"]):
            clip = librosa.resample(audio[int(start * 16000):int(end * 16000)], orig_sr=16000, target_sr=rate)
            inputs = proc.apply_transcription_request(audio=clip).to(model.device, torch.bfloat16)
            with torch.inference_mode():
                made = model.generate(**inputs, max_new_tokens=512, do_sample=False)
            made = made[:, inputs["input_ids"].shape[1]:]
            try:
                text = "".join(d.get("Content", "") for d in proc.decode(made, return_format="parsed")[0])
            except ValueError:
                # Answered out of its format: the raw text, for what it is worth.
                text = proc.decode(made, skip_special_tokens=True)[0]
            out.write(json.dumps({"i": i, "text": text.strip()}, ensure_ascii=False) + "\n")
            out.flush()


if __name__ == "__main__":
    main()

"""Tells the speakers apart over a dev job's audio, for the dev timeline.

Run by the server in the diarize venv (see setup.sh). Reads on stdin one
line of JSON, {"samples": N}, then N samples of 16 kHz mono audio as
little-endian int16. Writes {"segments": [[start, end, "S1"], ...]} in
seconds; speakers are named S1, S2, ... by how much they speak, most first,
and two may overlap.

The model is DiariZen (BUT; WavLM-Large with a Conformer that labels each
frame, then VBx clustering), the most consistent of the systems tried on
a Japanese drama. Its weights are CC BY-NC 4.0: personal, non-commercial
use only."""
import contextlib
import io
import json
import sys
import wave

MODEL = "BUT-FIT/diarizen-wavlm-large-s80-md-v2"


def main():
    from diarizen.pipelines.inference import DiariZenPipeline

    header = json.loads(sys.stdin.buffer.readline())
    pcm = sys.stdin.buffer.read(header["samples"] * 2)
    # As a WAV file in memory, the one kind of input it takes but a path.
    wav = io.BytesIO()
    with wave.open(wav, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(16000)
        f.writeframes(pcm)
    wav.seek(0)
    # Libraries print as they load and run; only the answer goes to stdout.
    with contextlib.redirect_stdout(sys.stderr):
        pipeline = DiariZenPipeline.from_pretrained(MODEL)
        annotation = pipeline(wav)
    segments = [(turn.start, turn.end, str(label)) for turn, _, label in annotation.itertracks(yield_label=True)]
    talk = {}
    for start, end, label in segments:
        talk[label] = talk.get(label, 0.0) + end - start
    names = {label: f"S{i + 1}" for i, label in enumerate(sorted(talk, key=talk.get, reverse=True))}
    json.dump({"segments": [[round(s, 3), round(e, 3), names[label]] for s, e, label in sorted(segments)]}, sys.stdout)


if __name__ == "__main__":
    main()

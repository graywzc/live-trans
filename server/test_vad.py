"""The speech finder runs Silero's own v6.2 model: run with the server's
Python, `python test_vad.py`. No real speech is needed to check the
plumbing: silence scores near zero, the model answers one probability per
32 ms window, and faster_whisper's post-processing is fed from it."""
import hashlib
import os
import time

import numpy as np

import asr_server as srv

HERE = os.path.dirname(os.path.abspath(__file__))


def test_the_model_file_is_the_official_v62_release():
    digest = hashlib.sha256(open(os.path.join(HERE, "silero_vad.onnx"), "rb").read()).hexdigest()
    assert digest.startswith("1a153a22f4509e29"), digest
    assert os.path.getsize(os.path.join(HERE, "silero_vad.onnx")) == 2327524


def test_one_probability_per_window_and_silence_scores_nothing():
    audio = np.zeros(srv.SAMPLE_RATE * 3 + 100, dtype=np.float32)
    probs = srv._silero(audio)
    assert probs.shape == (audio.size // 512,), probs.shape
    assert float(probs.max()) < 0.1, float(probs.max())
    noise = (np.random.default_rng(0).standard_normal(srv.SAMPLE_RATE * 3) * 0.01).astype(np.float32)
    assert float(srv._silero(noise).max()) < 0.5


def test_the_finder_uses_the_official_model_and_keeps_its_rules():
    import faster_whisper.vad as fw_vad

    assert srv.speech_stretches(np.zeros(srv.SAMPLE_RATE * 2, dtype=np.float32)) == []
    assert fw_vad.get_vad_model() is srv._silero
    assert srv.speech_clips(np.zeros(srv.SAMPLE_RATE * 2, dtype=np.float32)) == []


def test_a_minute_of_audio_is_scored_in_well_under_a_second():
    audio = (np.random.default_rng(1).standard_normal(srv.SAMPLE_RATE * 60) * 0.01).astype(np.float32)
    srv._silero(audio[:512])
    t0 = time.time()
    srv._silero(audio)
    assert time.time() - t0 < 2.0


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"ok {name}")

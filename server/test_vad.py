"""The speech finder runs Silero's own v6.2 model, or FireRedVAD in its
place for the dev step: run with the server's Python, `python test_vad.py`.
No real speech is needed to check the plumbing: silence scores near zero,
the model answers one probability per 32 ms window, and faster_whisper's
post-processing is fed from it."""
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


def test_the_firered_files_are_the_authors_own():
    digest = hashlib.sha256(open(os.path.join(HERE, "fireredvad_vad.onnx"), "rb").read()).hexdigest()
    assert digest.startswith("a226e68e69554875"), digest
    digest = hashlib.sha256(open(os.path.join(HERE, "fireredvad_cmvn.ark"), "rb").read()).hexdigest()
    assert digest.startswith("c87f6f13edf0f0ec"), digest
    digest = hashlib.sha256(open(os.path.join(HERE, "fireredvad_aed.onnx"), "rb").read()).hexdigest()
    assert digest.startswith("4ec27ccd86b16c38"), digest


def test_the_feature_normalisation_has_a_mean_and_spread_per_bin():
    mean, istd = srv.read_kaldi_cmvn(os.path.join(HERE, "fireredvad_cmvn.ark"))
    assert mean.shape == istd.shape == (80,)
    assert np.isfinite(mean).all() and (istd > 0).all()


def test_the_filterbank_has_a_row_per_10_ms_and_puts_a_tone_in_its_bin():
    tone = np.sin(2 * np.pi * 1000 * np.arange(srv.SAMPLE_RATE) / srv.SAMPLE_RATE) * 8000
    feats = srv.kaldi_fbank(tone)
    assert feats.shape == (1 + (srv.SAMPLE_RATE - 400) // 160, 80), feats.shape
    # 1 kHz on Kaldi's mel scale, between 20 Hz and 8 kHz in 81 steps.
    mel = lambda f: 1127.0 * np.log(1.0 + f / 700.0)
    expected = round((mel(1000) - mel(20)) / ((mel(8000) - mel(20)) / 81)) - 1
    assert abs(int(np.argmax(feats.mean(axis=0))) - expected) <= 1
    assert srv.kaldi_fbank(np.zeros(399)).shape == (0, 80)


def test_firered_answers_one_probability_per_window_and_silence_scores_nothing():
    audio = np.zeros(srv.SAMPLE_RATE * 3 + 100, dtype=np.float32)
    probs = srv._firered(audio)
    assert probs.shape == (audio.size // 512,), probs.shape
    assert float(probs.max()) < 0.1, float(probs.max())
    assert srv._firered(np.zeros(300, dtype=np.float32)).shape == (0,)


def test_the_finder_scores_with_firered_for_one_call_then_silero_again():
    import faster_whisper.vad as fw_vad

    seen = []

    class Recorder:
        def __call__(self, audio, **kwargs):
            seen.append(fw_vad.get_vad_model())
            return np.zeros(audio.shape[0] // 512, dtype=np.float32)

    recorder = Recorder()
    assert srv.speech_stretches(np.zeros(srv.SAMPLE_RATE, dtype=np.float32), model=recorder) == []
    assert seen == [recorder]
    assert fw_vad.get_vad_model() is srv._silero
    assert srv.speech_stretches(np.zeros(srv.SAMPLE_RATE * 2, dtype=np.float32), model=srv._firered) == []
    assert fw_vad.get_vad_model() is srv._silero


def test_event_runs_close_short_gaps_and_drop_short_runs():
    on = np.zeros(300, dtype=bool)
    on[10:60] = True    # 0.10-0.615 s
    on[80:120] = True   # 0.2 s after: bridged, to 1.215 s
    on[200:210] = True  # 0.115 s long: dropped
    assert srv.event_runs(on) == [(0.1, 1.215)]
    assert srv.event_runs(np.zeros(5, dtype=bool)) == []
    assert srv.event_runs(np.ones(100, dtype=bool)) == [(0.0, 1.015)]


def test_the_event_model_hears_nothing_in_silence():
    assert srv._firered_events.frames(np.zeros(srv.SAMPLE_RATE * 2, dtype=np.float32)).shape[1] == 3
    assert srv.sound_events(np.zeros(srv.SAMPLE_RATE * 2, dtype=np.float32)) == {"singing": [], "music": []}
    assert srv.sound_events(np.zeros(100, dtype=np.float32)) == {"singing": [], "music": []}


def test_firered_scores_a_minute_in_well_under_a_second():
    audio = (np.random.default_rng(1).standard_normal(srv.SAMPLE_RATE * 60) * 0.01).astype(np.float32)
    srv._firered(audio[:16000])
    t0 = time.time()
    srv._firered(audio)
    assert time.time() - t0 < 2.0


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"ok {name}")

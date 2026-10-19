"""A job that runs one step of captioning ahead over the whole of its
audio, for looking at what the step does: run with the server's Python,
`python test_steps.py`. The audio is a made-up file of noise and silence,
and Silero is stood in for by a loudness check, so the test is of the job,
not of Silero."""
import io
import json
import os
import tempfile
import time
import wave

import numpy as np

import asr_server as srv

# Whisper is not loaded here: the words a step job hears are made up by
# the tests that look at them, and none elsewhere.
srv.heard_words = lambda audio, start=0.0: []


def _not_set_up(name, header, audio):
    raise RuntimeError(f"{name} is not set up")


# Nor the dev tools: none of the tests but those about them see them.
srv.run_devtool = _not_set_up


def loud_stretches(audio):
    """Where `audio` is louder than nothing, by the tenth of a second."""
    step = srv.SAMPLE_RATE // 10
    loud = [np.abs(audio[i:i + step]).mean() > 0.01 for i in range(0, audio.size, step)]
    found, start = [], None
    for i, is_loud in enumerate(loud + [False]):
        if is_loud and start is None:
            start = i
        elif not is_loud and start is not None:
            found.append((start / 10, i / 10))
            start = None
    return found


def noise_and_silence(pattern):
    """`pattern`, [(seconds, loud), ...], as 16 kHz samples."""
    rng = np.random.default_rng(1)
    parts = []
    for seconds, loud in pattern:
        n = int(seconds * srv.SAMPLE_RATE)
        parts.append((rng.standard_normal(n) * 0.2).astype(np.float32) if loud else np.zeros(n, np.float32))
    return np.concatenate(parts)


_served = None


def wav_file(samples):
    """`samples` as a WAV file served over HTTP on this machine: ffmpeg is
    run with options that only an HTTP input takes."""
    global _served
    if _served is None:
        import functools
        import threading
        from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

        class RangeHandler(SimpleHTTPRequestHandler):
            """Serves a byte range too: ffmpeg seeks into a served file by
            asking for one, and without that a seek gives nothing."""

            def log_message(self, *args):
                pass

            def do_GET(self):
                header = self.headers.get("Range", "")
                path = self.translate_path(self.path)
                if not header.startswith("bytes=") or not os.path.isfile(path):
                    return super().do_GET()
                size = os.path.getsize(path)
                first, last = header[6:].split("-")
                first, last = int(first or 0), int(last) if last else size - 1
                with open(path, "rb") as f:
                    f.seek(first)
                    body = f.read(last - first + 1)
                self.send_response(206)
                self.send_header("Content-Type", "audio/wav")
                self.send_header("Content-Range", f"bytes {first}-{first + len(body) - 1}/{size}")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        class QuietServer(ThreadingHTTPServer):
            def handle_error(self, request, client_address):
                pass  # ffmpeg drops its probing connection early; nothing to tell

        directory = tempfile.mkdtemp()
        handler = functools.partial(RangeHandler, directory=directory)
        server = QuietServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        _served = (directory, server.server_address[1], 0)
    directory, port, count = _served
    _served = (directory, port, count + 1)
    name = f"clip{count}.wav"
    with wave.open(os.path.join(directory, name), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(srv.SAMPLE_RATE)
        f.writeframes((samples * 32767).astype("<i2").tobytes())
    return f"http://127.0.0.1:{port}/{name}"


def fresh_cache():
    """A cache of its own for the test, empty."""
    srv.DEV_CACHE_DIR = tempfile.mkdtemp()
    return srv.DEV_CACHE_DIR


def wait_for(job, state, seconds=30):
    deadline = time.time() + seconds
    while job.state != state and time.time() < deadline:
        time.sleep(0.1)
    assert job.state == state, (job.state, job.error)


def test_the_speech_step_finds_the_speech_in_the_whole_audio(monkeypatch=None):
    fresh_cache()
    original = srv.speech_stretches
    srv.speech_stretches = loud_stretches
    try:
        path = wav_file(noise_and_silence([(1, False), (2, True), (1, False), (1.5, True), (0.5, False)]))
        job = srv.PrefetchJob(path, "file", {}, None, step="speech")
        wait_for(job, "done")
    finally:
        srv.speech_stretches = original
    assert job.speech == [(1.0, 3.0), (4.0, 5.5)], job.speech
    assert abs(job.analysed - 6.0) < 0.01, job.analysed
    status = job.status()
    assert status["step"] == "speech" and status["lines"] == [] and abs(status["analysed"] - 6.0) < 0.01, status
    found = {k: v for k, v in job.findings().items() if k not in ("words", "worded", "aligned")}
    assert found == {"step": "speech", "analysed": 6.0, "speech": [[1.0, 3.0], [4.0, 5.5]]}, found
    # Its audio can be heard, a stretch at a time, as a WAV file.
    with wave.open(io.BytesIO(job.wav(1.0, 2.0))) as f:
        assert (f.getnchannels(), f.getsampwidth(), f.getframerate()) == (1, 2, srv.SAMPLE_RATE)
        assert f.getnframes() == srv.SAMPLE_RATE
        heard = np.frombuffer(f.readframes(f.getnframes()), dtype="<i2")
    assert np.abs(heard).mean() > 1000, "the second second is noise"
    with wave.open(io.BytesIO(job.wav(0.0, 0.5))) as f:
        assert np.abs(np.frombuffer(f.readframes(f.getnframes()), dtype="<i2")).max() == 0, "the first is silence"
    with wave.open(io.BytesIO(job.wav(10.0, 12.0))) as f:
        assert f.getnframes() == 0, "nothing past the audio"
    # Retired for another job of the same video, it keeps the audio it looked at.
    job.retire()
    assert job.state == "done" and abs(job.fetched - 6.0) < 0.01


def test_a_step_job_begins_where_it_was_told_to():
    fresh_cache()
    original = srv.speech_stretches
    srv.speech_stretches = loud_stretches
    try:
        path = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        job = srv.PrefetchJob(path, "file", {}, 3.0, start=1.5, step="speech")
        wait_for(job, "done")
    finally:
        srv.speech_stretches = original
    assert job.speech == [(1.5, 2.0)], job.speech
    assert abs(job.analysed - 3.0) < 0.05
    assert job.status()["start"] == 1.5


def test_a_job_says_while_its_audio_is_still_coming():
    # The app waits on this before switching a dev job to another step, as
    # the host keeps the audio for the next step only once a fetch has
    # ended unstopped.
    fresh_cache()
    original = srv.speech_stretches
    srv.speech_stretches = loud_stretches
    try:
        path = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        job = srv.PrefetchJob(path, "file", {}, 3.0, step="speech")
        assert job.status()["fetching"] is True
        wait_for(job, "done")
    finally:
        srv.speech_stretches = original
    assert job.status()["fetching"] is False


def test_only_a_known_step_runs():
    try:
        srv.PrefetchJob("x", "file", {}, None, step="grammar")
    except ValueError as exc:
        assert "grammar" in str(exc)
    else:
        assert False, "an unknown step was accepted"


def test_at_most_a_couple_of_minutes_of_audio_come_at_once():
    fresh_cache()
    original = srv.speech_stretches
    srv.speech_stretches = lambda audio: []
    try:
        path = wav_file(noise_and_silence([(130, False)]))
        job = srv.PrefetchJob(path, "file", {}, None, step="speech")
        wait_for(job, "done")
    finally:
        srv.speech_stretches = original
    with wave.open(io.BytesIO(job.wav(0.0, 130.0))) as f:
        assert f.getnframes() == int(srv.DEV_AUDIO_LIMIT * srv.SAMPLE_RATE)


def test_a_video_fetched_once_is_kept_for_the_step_to_run_again():
    cache = fresh_cache()
    original = srv.speech_stretches
    srv.speech_stretches = loud_stretches
    try:
        url = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        first = srv.PrefetchJob(url, "https://example.com/v", {}, 7.0, step="speech")
        wait_for(first, "done")
        assert not first.cached and first.speech == [(1.0, 2.0)]
        assert sorted(os.listdir(os.path.join(cache, os.listdir(cache)[0]))) == ["audio.json", "audio.s16", "speech.json"]
        # The same page again, from a link that no longer serves: the audio
        # and the step's findings come from the cache, with no fetch.
        srv.speech_stretches = lambda audio: (_ for _ in ()).throw(AssertionError("the step ran again"))
        again = srv.PrefetchJob(url + ".gone", "https://example.com/v", {}, 7.0, step="speech")
        wait_for(again, "done", seconds=5)
        assert again.cached and again.speech == [(1.0, 2.0)] and abs(again.analysed - 3.0) < 0.05, again.speech
        assert again.status()["cached"] is True and again.duration == 7.0
        # The step's code changed: it runs again, over the cached audio.
        srv.STEP_VERSIONS["speech"] = "silero-whole-test"
        srv.speech_stretches = lambda audio: [(0.5, 2.5)]
        changed = srv.PrefetchJob(url + ".gone", "https://example.com/v", {}, 7.0, step="speech")
        wait_for(changed, "done", seconds=5)
        assert changed.cached and changed.speech == [(0.5, 2.5)], changed.speech
        # A production job keeps nothing and takes nothing.
        production = srv.PrefetchJob(url + ".gone", "https://example.com/v", {}, 7.0)
        wait_for(production, "failed", seconds=10)
        assert not production.cached
    finally:
        srv.speech_stretches = original
        srv.STEP_VERSIONS["speech"] = "silero-6.2-whole-1"
    assert srv.clear_dev_cache() == 1
    assert os.listdir(cache) == []
    assert srv.clear_dev_cache() == 0


def test_a_step_job_hears_the_words_piece_by_piece_and_keeps_them_off_disk():
    cache = fresh_cache()
    original = srv.speech_stretches, srv.heard_words, srv.WORDS_PIECE, srv.WORDS_OVERLAP
    srv.speech_stretches = loud_stretches
    srv.WORDS_PIECE, srv.WORDS_OVERLAP = 4.0, 2.0
    pieces = []

    def heard(audio, start=0.0):
        # A made-up word a second, each piece on its own clock. (Jobs of
        # the tests before may still be listening too: theirs are shorter.)
        pieces.append(audio.size / srv.SAMPLE_RATE)
        return [(t + 0.1, t + 0.5, f"w{t}", 0.9) for t in range(int(np.ceil(audio.size / srv.SAMPLE_RATE)))]

    srv.heard_words = heard
    try:
        url = wav_file(noise_and_silence([(1, False), (6.5, True), (1, False)]))
        job = srv.PrefetchJob(url, "https://example.com/x", {}, 8.5, step="speech")
        wait_for(job, "done")
        deadline = time.time() + 10
        while job.worded < 8.5 - 0.01 and time.time() < deadline:
            time.sleep(0.1)
    finally:
        srv.speech_stretches, srv.heard_words, srv.WORDS_PIECE, srv.WORDS_OVERLAP = original
    # Pieces of 4 s every 2 s: 0-4, 2-6, 4-8, 6-8.5 (the last to the end).
    assert pieces[-4:] == [4.0, 4.0, 4.0, 2.5], pieces
    starts = [w[0] for w in job.words]
    # Each word once, from the piece it starts in the middle of: the first
    # piece keeps its head, each its middle, the last its tail.
    assert starts == [0.1, 1.1, 2.1, 3.1, 4.1, 5.1, 6.1, 7.1, 8.1], starts
    assert [w[2] for w in job.words] == ["w0", "w1", "w2", "w1", "w2", "w1", "w2", "w1", "w2"], job.words
    assert abs(job.worded - 8.5) < 0.01 and job.status()["worded"] == job.worded
    found = job.findings()
    assert found["words"][0] == [0.1, 0.5, "w0", 0.9]
    with open(os.path.join(cache, os.listdir(cache)[0], "speech.json"), encoding="utf-8") as f:
        assert "words" not in json.load(f), "no text on disk"
    srv.clear_dev_cache()


def test_the_words_are_re_timed_and_the_speakers_told_apart_by_the_dev_tools():
    cache = fresh_cache()
    original = srv.speech_stretches, srv.heard_words, srv.run_devtool, srv.WORDS_PIECE, srv.WORDS_OVERLAP
    srv.speech_stretches = loud_stretches
    srv.WORDS_PIECE, srv.WORDS_OVERLAP = 4.0, 2.0
    srv.heard_words = lambda audio, start=0.0: [(0.5, 0.9, "w", 0.9), (2.5, 3.5, "v", 0.8)]
    asked = []

    def tool(name, header, audio):
        asked.append((name, header, audio.size))
        if name == "align":
            # Each word 0.1 s later and shorter than Whisper had it.
            return {"pieces": [[[w[0] + 0.1, w[1] - 0.1] for w in p["words"]] for p in header["pieces"]]}
        return {"segments": [[1.0, 2.0, "S1"], [4.0, 5.5, "S2"]]}

    srv.run_devtool = tool
    try:
        url = wav_file(noise_and_silence([(1, False), (5, True), (1, False)]))
        job = srv.PrefetchJob(url, "https://example.com/y", {}, 7.0, step="speech")
        deadline = time.time() + 15
        while not (job.aligned and job.speakers is not None) and time.time() < deadline:
            time.sleep(0.1)
        # Taken from the cache again, the speakers come with no worker run
        # (the words, never kept, are re-timed again).
        def again_tool(name, header, audio):
            asked.append((name, header, audio.size))
            return _not_set_up(name, header, audio)

        srv.run_devtool = again_tool
        again = srv.PrefetchJob(url + ".gone", "https://example.com/y", {}, 7.0, step="speech")
        deadline = time.time() + 15
        while again.speakers is None and time.time() < deadline:
            time.sleep(0.1)
    finally:
        srv.speech_stretches, srv.heard_words, srv.run_devtool, srv.WORDS_PIECE, srv.WORDS_OVERLAP = original
    assert job.aligned and job.status()["aligned"] and job.status()["speakers"]
    # Pieces of 4 s every 2 s; the word at 0.5 is the first piece's, the
    # one at 2.5 into each piece is that piece's.
    assert [w[:2] for w in job.words][:2] == [(0.6, 0.8), (2.6, 3.4)], job.words
    assert job.findings()["speakers"] == [[1.0, 2.0, "S1"], [4.0, 5.5, "S2"]]
    assert again.speakers == [(1.0, 2.0, "S1"), (4.0, 5.5, "S2")]
    names = [a[0] for a in asked]
    assert sorted(set(names)) == ["align", "diarize"] and names.count("diarize") == 1, names
    assert names.count("align") == 2, names
    align = next(h for n, h, _ in asked if n == "align")
    assert align["pieces"][0]["words"][0] == [0.5, 0.9, "w", 0.9]
    folder = os.path.join(cache, os.listdir(cache)[0])
    assert sorted(os.listdir(folder)) == ["audio.json", "audio.s16", "speakers.json", "speech.json"], os.listdir(folder)
    for name in ("speakers.json", "speech.json"):
        with open(os.path.join(folder, name), encoding="utf-8") as f:
            kept = json.load(f)
        assert "words" not in kept and "\"w\"" not in json.dumps(kept), (name, kept)
    srv.clear_dev_cache()


def test_the_firered_step_finds_the_speech_with_firered_and_keeps_it_apart():
    cache = fresh_cache()
    original = srv.speech_stretches
    models = []

    def found(audio, model=None):
        models.append(model)
        return loud_stretches(audio)

    srv.speech_stretches = found
    events = srv.sound_events
    srv.sound_events = lambda audio: {"singing": [(1.2, 1.8)], "music": []}
    try:
        url = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        silero = srv.PrefetchJob(url, "https://example.com/w", {}, 3.0, step="speech")
        wait_for(silero, "done")
        firered = srv.PrefetchJob(url + ".gone", "https://example.com/w", {}, 3.0, step="speech-firered")
        wait_for(firered, "done", seconds=10)
        # Taken from the cache again, the events come back with the speech.
        again = srv.PrefetchJob(url + ".gone", "https://example.com/w", {}, 3.0, step="speech-firered")
        wait_for(again, "done", seconds=10)
    finally:
        srv.speech_stretches = original
        srv.sound_events = events
    # The Silero job asked for Silero, the other for FireRedVAD, which ran
    # over the audio the first one kept: its own findings, not the cached ones.
    assert models and models[0] is None and models[-1] is srv._firered, models
    assert firered.cached and firered.speech == [(1.0, 2.0)], firered.speech
    assert firered.findings()["step"] == "speech-firered"
    assert firered.findings()["events"] == {"singing": [[1.2, 1.8]], "music": []}
    assert again.findings()["events"] == {"singing": [[1.2, 1.8]], "music": []}
    assert "events" not in silero.findings(), "Silero hears no events"
    kept = sorted(os.listdir(os.path.join(cache, os.listdir(cache)[0])))
    assert kept == ["audio.json", "audio.s16", "speech-firered.json", "speech.json"], kept
    srv.clear_dev_cache()


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"ok {name}")

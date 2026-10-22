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

# The step tests look at the steps; the captions a step job also makes
# have a test of their own.
srv.DEV_CAPTIONS = False
srv.DEV_SPEAKER_CUTS = False

# Whisper is not loaded here: the words a step job hears are made up by
# the tests that look at them, and none elsewhere.
srv.heard_words = lambda audio, start=0.0: []


def _not_set_up(name, header, audio):
    raise RuntimeError(f"{name} is not set up")


# Nor the dev tools: none of the tests but those about them see them.
srv.run_devtool = _not_set_up
srv.run_devtool_lines = lambda name, header, audio, on_line: _not_set_up(name, header, audio)


def loud_stretches(audio, model=None):
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


def test_a_fetch_that_ends_short_of_the_video_is_not_kept():
    # A link that stops serving partway (its signature run out, say) ends
    # ffmpeg as if the video were over; kept, every step after ran over
    # the first minutes only.
    cache = fresh_cache()
    original = srv.speech_stretches
    srv.speech_stretches = loud_stretches
    try:
        url = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        short = srv.PrefetchJob(url, "https://example.com/short", {}, 60.0, step="speech")
        wait_for(short, "done")
        assert short.speech == [(1.0, 2.0)] and not short.cached
        assert not os.path.exists(os.path.join(short.cache.dir, "audio.s16")), os.listdir(short.cache.dir)
    finally:
        srv.speech_stretches = original


def test_a_short_audio_kept_by_an_older_server_is_fetched_again():
    fresh_cache()
    original = srv.speech_stretches
    srv.speech_stretches = loud_stretches
    try:
        url = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        # Kept as if whole: 2 s of a video said to be a minute long.
        srv.DevCache("https://example.com/old", url).save_audio(srv.np.zeros(2 * srv.SAMPLE_RATE, srv.np.float32), 60.0)
        job = srv.PrefetchJob(url, "https://example.com/old", {}, 3.0, step="speech")
        wait_for(job, "done")
        assert not job.cached and job.speech == [(1.0, 2.0)], (job.cached, job.speech)
    finally:
        srv.speech_stretches = original


def test_what_a_step_found_over_a_short_audio_is_not_taken_for_the_whole():
    cache = fresh_cache()
    original = srv.speech_stretches, srv.sound_events
    srv.speech_stretches = lambda audio, model=None: loud_stretches(audio)
    srv.sound_events = lambda audio: {"singing": [], "music": []}
    try:
        url = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        kept = srv.DevCache("https://example.com/short", url)
        # An older server kept 2 s of a 3 s video, and what Silero and
        # DiariZen found over them, with nothing to say which audio that was.
        kept.save_audio(srv.np.zeros(2 * srv.SAMPLE_RATE, srv.np.float32), 3.0)
        with open(os.path.join(kept.dir, "speech.json"), "w") as f:
            json.dump({"speech": [[0.1, 0.2]], "analysed": 2.0, "version": srv.STEP_VERSIONS["speech"]}, f)
        with open(os.path.join(kept.dir, "speakers.json"), "w") as f:
            json.dump({"speakers": [[0.1, 0.2, "S1"]], "version": srv.STEP_VERSIONS["speakers"]}, f)
        # Another step fetches the whole video again and keeps it.
        firered = srv.PrefetchJob(url, "https://example.com/short", {}, 3.0, step="speech-firered")
        wait_for(firered, "done")
        assert not firered.cached
        assert "speakers.json" not in os.listdir(kept.dir), "the new audio drops the old findings"
        # Silero, over the audio now kept: found again, not the 2 s of it.
        silero = srv.PrefetchJob(url + ".gone", "https://example.com/short", {}, 3.0, step="speech")
        wait_for(silero, "done", seconds=5)
        assert silero.cached and silero.speech == [(1.0, 2.0)], silero.speech
        # And found over the whole of it now, taken from the cache again.
        srv.speech_stretches = lambda audio, model=None: (_ for _ in ()).throw(AssertionError("the step ran again"))
        again = srv.PrefetchJob(url + ".gone", "https://example.com/short", {}, 3.0, step="speech")
        wait_for(again, "done", seconds=5)
        assert again.cached and again.speech == [(1.0, 2.0)], again.speech
        assert abs(kept.load_findings("speech")["audio_seconds"] - 3.0) < 0.01
        # A file from before findings said which audio they were over.
        found = kept.load_findings("speech")
        with open(os.path.join(kept.dir, "speech.json"), "w") as f:
            json.dump({k: v for k, v in found.items() if k != "audio_seconds"}, f)
        assert kept.load_findings("speech") is None
    finally:
        srv.speech_stretches, srv.sound_events = original
    srv.clear_dev_cache()

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
    srv.speech_stretches = lambda audio, model=None: []
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
        first = srv.PrefetchJob(url, "https://example.com/v", {}, 3.0, step="speech")
        wait_for(first, "done")
        assert not first.cached and first.speech == [(1.0, 2.0)]
        assert sorted(os.listdir(os.path.join(cache, os.listdir(cache)[0]))) == ["audio.json", "audio.s16", "speech.json"]
        # The same page again, from a link that no longer serves: the audio
        # and the step's findings come from the cache, with no fetch.
        srv.speech_stretches = lambda audio, model=None: (_ for _ in ()).throw(AssertionError("the step ran again"))
        again = srv.PrefetchJob(url + ".gone", "https://example.com/v", {}, 3.0, step="speech")
        wait_for(again, "done", seconds=5)
        assert again.cached and again.speech == [(1.0, 2.0)] and abs(again.analysed - 3.0) < 0.05, again.speech
        assert again.status()["cached"] is True and again.duration == 3.0
        # The step's code changed: it runs again, over the cached audio.
        srv.STEP_VERSIONS["speech"] = "silero-whole-test"
        srv.speech_stretches = lambda audio, model=None: [(0.5, 2.5)]
        changed = srv.PrefetchJob(url + ".gone", "https://example.com/v", {}, 3.0, step="speech")
        wait_for(changed, "done", seconds=5)
        assert changed.cached and changed.speech == [(0.5, 2.5)], changed.speech
        # A production job keeps nothing and takes nothing.
        production = srv.PrefetchJob(url + ".gone", "https://example.com/v", {}, 3.0)
        wait_for(production, "failed", seconds=10)
        assert not production.cached
    finally:
        srv.speech_stretches = original
        srv.STEP_VERSIONS["speech"] = "silero-6.2-whole-1"
    assert srv.clear_dev_cache() == 1
    assert os.listdir(cache) == []
    assert srv.clear_dev_cache() == 0


def test_a_step_job_hears_the_words_piece_by_piece_and_keeps_them_for_next_time():
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
    assert abs(job.worded - 8.5) < 0.01 and job.status()["worded"] == round(job.worded, 2), (job.worded, job.status()["worded"])
    found = job.findings()
    assert found["words"][0] == [0.1, 0.5, "w0", 0.9]
    with open(os.path.join(cache, os.listdir(cache)[0], "speech.json"), encoding="utf-8") as f:
        assert "words" not in json.load(f), "the words are kept apart from the step's findings"
    # Run again over the same video, the words come from the cache, unheard.
    heard_before = len(pieces)
    srv.heard_words = heard
    try:
        again = srv.PrefetchJob(url, "https://example.com/x", {}, 8.5, step="speech")
        deadline = time.time() + 10
        while not again.words and time.time() < deadline:
            time.sleep(0.1)
    finally:
        srv.heard_words = original[1]
    assert again.cached and len(pieces) == heard_before, (again.cached, pieces)
    assert [list(w) for w in again.words] == found["words"] and abs(again.worded - job.worded) < 0.01
    # Forgetting one video leaves the others.
    os.makedirs(srv.DevCache("https://example.com/y", None).dir)
    assert srv.clear_dev_cache("https://example.com/x") == 1
    assert os.listdir(cache) == [os.path.basename(srv.DevCache("https://example.com/y", None).dir)], os.listdir(cache)
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
        # Taken from the cache again, the speakers and the re-timed words
        # come with no worker run.
        def again_tool(name, header, audio):
            asked.append((name, header, audio.size))
            return _not_set_up(name, header, audio)

        srv.run_devtool = again_tool
        again = srv.PrefetchJob(url + ".gone", "https://example.com/y", {}, 7.0, step="speech")
        deadline = time.time() + 15
        # Both come once the audio is in, in either order.
        while (again.speakers is None or not again.aligned) and time.time() < deadline:
            time.sleep(0.1)
    finally:
        srv.speech_stretches, srv.heard_words, srv.run_devtool, srv.WORDS_PIECE, srv.WORDS_OVERLAP = original
    assert job.aligned and job.status()["aligned"] and job.status()["speakers"]
    # Pieces of 4 s every 2 s; the word at 0.5 is the first piece's, the
    # one at 2.5 into each piece is that piece's.
    assert [w[:2] for w in job.words][:2] == [(0.6, 0.8), (2.6, 3.4)], job.words
    assert job.findings()["speakers"] == [[1.0, 2.0, "S1"], [4.0, 5.5, "S2"]]
    assert again.speakers == [(1.0, 2.0, "S1"), (4.0, 5.5, "S2")]
    assert again.words == job.words, (again.words, job.words)
    names = [a[0] for a in asked]
    assert sorted(set(names)) == ["align", "diarize"], names
    align = next(h for n, h, _ in asked if n == "align")
    assert align["pieces"][0]["words"][0] == [0.5, 0.9, "w", 0.9]
    folder = os.path.join(cache, os.listdir(cache)[0])
    assert sorted(os.listdir(folder)) == ["audio.json", "audio.s16", "speakers.json", "speech.json", "words.json"], os.listdir(folder)
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
    assert [k for k in kept if k != "words.json"] == ["audio.json", "audio.s16", "speech-firered.json", "speech.json"], kept
    srv.clear_dev_cache()


def test_the_mean_step_finds_the_speech_with_both_models_and_tells_the_events():
    cache = fresh_cache()
    original = srv.speech_stretches
    models = []

    def found(audio, model=None):
        models.append(model)
        return loud_stretches(audio)

    srv.speech_stretches = found
    events = srv.sound_events
    srv.sound_events = lambda audio: {"singing": [], "music": [(0.2, 0.9)]}
    try:
        url = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        job = srv.PrefetchJob(url, "https://example.com/w", {}, 3.0, step="speech-mean")
        wait_for(job, "done", seconds=10)
    finally:
        srv.speech_stretches = original
        srv.sound_events = events
    assert models and set(models) == {srv._firered_and_segmentation}, models
    assert srv._firered_and_segmentation.models == (srv._firered, srv._segmentation)
    assert job.speech == [(1.0, 2.0)], job.speech
    assert job.findings()["step"] == "speech-mean"
    assert job.findings()["events"] == {"singing": [], "music": [[0.2, 0.9]]}
    srv.clear_dev_cache()


def test_a_step_job_captions_the_video_with_its_speech_finder_and_keeps_no_text():
    cache = fresh_cache()
    original = srv.speech_stretches, srv.hear_pieces, srv.sound_events, srv.DEV_CAPTIONS
    models = []

    def found(audio, model=None):
        models.append(model)
        return loud_stretches(audio)

    def heard(grid, audio, start, **kwargs):
        return [{"ja": "ことば", "en": "words", "start": a, "end": b} for a, b in grid.pieces(start, start + audio.size / srv.SAMPLE_RATE)]

    srv.speech_stretches, srv.hear_pieces, srv.DEV_CAPTIONS = found, heard, True
    srv.sound_events = lambda audio: {"singing": [], "music": []}
    try:
        url = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        job = srv.PrefetchJob(url, "https://example.com/c", {}, 3.0, step="speech-firered")
        deadline = time.time() + 15
        while not job.captioned and time.time() < deadline:
            time.sleep(0.1)
        status = job.status()
    finally:
        srv.speech_stretches, srv.hear_pieces, srv.sound_events, srv.DEV_CAPTIONS = original
    assert status["captions"] == "done", status
    assert status["count"] >= 1 and status["lines"][0]["en"] == "words", status["lines"]
    line = status["lines"][0]
    assert 0 <= line["start"] < line["end"] <= 3.0, line
    # Batches and stretches both found by the step's model.
    assert models and set(models) == {srv._firered}, models
    folder = os.path.join(cache, os.listdir(cache)[0])
    for name in os.listdir(folder):
        if name.endswith(".json"):
            assert "ことば" not in open(os.path.join(folder, name), encoding="utf-8").read(), name
    srv.clear_dev_cache()

def test_a_step_job_s_captions_are_kept_and_shown_again_without_hearing():
    fresh_cache()
    original = srv.speech_stretches, srv.hear_pieces, srv.sound_events, srv.DEV_CAPTIONS
    calls = []

    def heard(grid, audio, start, **kwargs):
        calls.append(start)
        return [{"ja": "ことば", "en": "words", "start": a, "end": b} for a, b in grid.pieces(start, start + audio.size / srv.SAMPLE_RATE)]

    def captions():
        job = srv.PrefetchJob(url, "https://example.com/k", {}, 3.0, step="speech")
        deadline = time.time() + 15
        while not job.captioned and time.time() < deadline:
            time.sleep(0.1)
        return job.status()

    srv.speech_stretches, srv.hear_pieces, srv.DEV_CAPTIONS = (lambda audio, model=None: loud_stretches(audio)), heard, True
    srv.sound_events = lambda audio: {"singing": [], "music": []}
    try:
        url = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        first = captions()
        made = len(calls)
        again = captions()
    finally:
        srv.speech_stretches, srv.hear_pieces, srv.sound_events, srv.DEV_CAPTIONS = original
    assert made >= 1 and len(calls) == made, (made, calls)
    assert again["lines"] == first["lines"] and again["captions"] == "done", (first, again)
    srv.clear_dev_cache()


def test_each_caption_is_heard_again_by_the_other_recognizers_and_kept_for_next_time():
    cache = fresh_cache()
    original = (srv.speech_stretches, srv.hear_pieces, srv.sound_events, srv.DEV_CAPTIONS,
                srv.run_devtool_lines, srv.unload_ollama)
    asked = []

    def heard(grid, audio, start, **kwargs):
        return [{"ja": "ことば", "en": "words", "start": a, "end": b} for a, b in grid.pieces(start, start + audio.size / srv.SAMPLE_RATE)]

    def other(name, header, audio, on_line):
        asked.append((name, header["clips"]))
        if name == "hear_qwen":
            raise RuntimeError("hear_qwen is not set up")
        for i, _ in enumerate(header["clips"]):
            on_line({"i": i, "text": f"{name}のことば"})

    def run(page_url):
        job = srv.PrefetchJob(url, page_url, {}, 3.0, step="speech")
        # (Jobs of tests before may still be about, asking too.)
        deadline = time.time() + 15
        while time.time() < deadline and not (job.captioned and job.status()["others"] >= 2 * job.status()["count"] > 0):
            time.sleep(0.1)
        time.sleep(0.3)
        return job.status(), job.findings()

    srv.speech_stretches, srv.hear_pieces, srv.DEV_CAPTIONS = (lambda audio, model=None: loud_stretches(audio)), heard, True
    srv.sound_events = lambda audio: {"singing": [], "music": []}
    srv.run_devtool_lines, srv.unload_ollama = other, lambda: asked.append(("unload", None))
    try:
        url = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        status, found = run("https://example.com/o")
        names, clip = [a[0] for a in asked], asked[0][1][0]
        del asked[:]
        # Again over the same video: what was heard is taken from the cache,
        # and only the recognizer that failed is asked again.
        status_again, found_again = run("https://example.com/o")
    finally:
        (srv.speech_stretches, srv.hear_pieces, srv.sound_events, srv.DEV_CAPTIONS,
         srv.run_devtool_lines, srv.unload_ollama) = original
    assert names[:4] == ["hear_nemo", "hear_qwen", "unload", "hear_vibevoice"], names
    line = status["lines"][0]
    # From half a second before the caption (or the audio's start) to 0.3 s after.
    assert abs(clip[0] - max(line["start"] - 0.5, 0)) < 0.01 and abs(clip[1] - (line["end"] + 0.3)) < 0.01, (clip, line)
    assert found["others"][0] == {"start": line["start"], "end": line["end"],
                                  "nemo": "hear_nemoのことば", "vibevoice": "hear_vibevoiceのことば"}, found["others"]
    assert status["others"] == 2 * len(status["lines"]), status["others"]
    assert [a[0] for a in asked] == ["hear_qwen"], asked
    assert found_again["others"] == found["others"], found_again
    srv.clear_dev_cache()


def test_the_official_subtitles_of_a_page_are_found_by_its_index():
    folder = tempfile.mkdtemp()
    os.makedirs(os.path.join(folder, "site", "ep1"))
    with open(os.path.join(folder, "index.json"), "w") as f:
        json.dump({"https://example.com/play/1.html": "site/ep1"}, f)
    with open(os.path.join(folder, "site", "ep1", "subtitles.tsv"), "w", encoding="utf-8") as f:
        f.write("index\tstart\tend\ttext\n0\t1.5\t3.0\t-\n1\t4.0\t6.5\t今天下雨了\n2\t7.0\t9.0\t(credits)\n")
    kept = srv.REFERENCE_DIR
    srv.REFERENCE_DIR = folder
    try:
        assert srv.reference_lines("https://example.com/play/1.html?from=list") == [{"start": 4.0, "end": 6.5, "text": "今天下雨了"}]
        assert srv.reference_lines("https://example.com/play/2.html") is None
    finally:
        srv.REFERENCE_DIR = kept

def test_a_dev_job_is_timed_on_the_video_s_clock_and_its_cache_keeps_it():
    fresh_cache()
    original = srv.speech_stretches
    srv.speech_stretches = lambda audio, model=None: loud_stretches(audio)
    try:
        url = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        first = srv.PrefetchJob(url, "https://example.com/clock", {}, 3.0, step="speech")
        wait_for(first, "done")
        assert first.clock and first.clock.at, "the fetch timed its packets"
        kept = srv.DevCache("https://example.com/clock", url).load_audio()
        assert kept and kept[2]["at"] == first.clock.at, "the cache keeps the clock"
        again = srv.PrefetchJob(url + ".gone", "https://example.com/clock", {}, 3.0, step="speech")
        wait_for(again, "done", seconds=5)
        assert again.cached and again.clock.at == first.clock.at
        # Audio kept with no clock (by an older server) is fetched again.
        older = srv.DevCache("https://example.com/older", url)
        older.save_audio(srv.np.zeros(3 * srv.SAMPLE_RATE, srv.np.float32), 3.0)
        assert older.load_audio() is None
    finally:
        srv.speech_stretches = original
    srv.clear_dev_cache()

def test_a_failed_fetch_falls_back_to_audio_kept_without_a_clock():
    fresh_cache()
    original = srv.speech_stretches
    srv.speech_stretches = lambda audio, model=None: loud_stretches(audio)
    try:
        url = wav_file(noise_and_silence([(1, False), (1, True), (1, False)]))
        kept = srv.DevCache("https://example.com/stale", url)
        kept.save_audio(noise_and_silence([(1, False), (1, True), (1, False)]), 3.0)
        job = srv.PrefetchJob(url + ".gone", "https://example.com/stale", {}, 3.0, step="speech")
        wait_for(job, "done", seconds=10)
        assert job.cached and job.clock is None and job.speech == [(1.0, 2.0)], (job.cached, job.speech)
    finally:
        srv.speech_stretches = original
    srv.clear_dev_cache()

if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"ok {name}")

"""The video a dev step job keeps for the phone, with its captions (see
BundleFetch): run with the server's Python, `python test_bundle.py`. The
stream is made up by ffmpeg (a test pattern and a tone) and served from
this machine; the speech finder is stood in for, as in test_steps.py, and
no model is loaded."""
import contextlib
import functools
import io
import json
import os
import subprocess
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

import asr_server as srv

# No captions are made by the pipeline here (that needs the models): the
# tests put the captions a job would have made where it keeps them.
srv.DEV_CAPTIONS = False
srv.DEV_SPEAKER_CUTS = False
srv.DEV_OTHER_HEARING = False
srv.heard_words = lambda audio, start=0.0: []


def _not_set_up(name, header, audio):
    raise RuntimeError(f"{name} is not set up")


srv.run_devtool = _not_set_up
srv.run_devtool_lines = lambda name, header, audio, on_line: _not_set_up(name, header, audio)
srv.speech_stretches = lambda audio, model=None: [(0.0, audio.size / srv.SAMPLE_RATE)] if audio.size else []

# Made-up lines, as a step job's captions come: the text, its translation,
# and where in the video it was said.
LINES = [
    {"ja": "今日は良い天気ですね。", "en": "Nice weather today, isn't it.", "start": 0.4, "end": 1.9},
    {"ja": "散歩に行きましょう。", "en": "Let's go for a walk.", "start": 2.3, "end": 3.6},
]
TITLE = "A made-up episode"

_served = None
_made = 0


def served():
    """A folder served over plain HTTP on this machine, and its URL: ffmpeg
    is run with options only an HTTP input takes."""
    global _served
    if _served is None:
        directory = tempfile.mkdtemp()

        class Quiet(SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass

        class QuietServer(ThreadingHTTPServer):
            def handle_error(self, request, client_address):
                pass  # ffmpeg drops its probing connection early; nothing to tell

        server = QuietServer(("127.0.0.1", 0), functools.partial(Quiet, directory=directory))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        _served = (directory, f"http://127.0.0.1:{server.server_address[1]}")
    return _served


def hls_stream(seconds=6):
    """A made-up video `seconds` long as an HLS playlist served from this
    machine: its URL, and the playlist's path on disk."""
    global _made
    directory, base = served()
    name = f"stream{_made}"
    _made += 1
    folder = os.path.join(directory, name)
    os.makedirs(folder)
    subprocess.run([
        "ffmpeg", "-nostdin", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=10",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=16000",
        "-t", str(seconds), "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac",
        "-f", "hls", "-hls_time", "2", "-hls_list_size", "0",
        "-hls_segment_filename", os.path.join(folder, "seg%03d.ts"), os.path.join(folder, "playlist.m3u8"),
    ], check=True, timeout=120)
    return f"{base}/{name}/playlist.m3u8", os.path.join(folder, "playlist.m3u8")


def fresh_cache():
    """A cache of its own for the test, empty."""
    srv.DEV_CACHE_DIR = tempfile.mkdtemp()
    return srv.DEV_CACHE_DIR


def wait_for(job, state, seconds=30):
    deadline = time.time() + seconds
    while job.state != state and time.time() < deadline:
        time.sleep(0.1)
    assert job.state == state, (job.state, job.error)


def wait_for_bundle(job, seconds=60):
    """The bundle's state once its fetch has ended."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        state, _ = srv.bundle_status(job.cache)
        if state != "running":
            return state
        time.sleep(0.1)
    raise AssertionError("the bundle fetch did not end")


def step_job(url, page, seconds):
    """A step job over the served stream, run to its end."""
    job = srv.PrefetchJob(url, page, {}, float(seconds), step="speech")
    wait_for(job, "done")
    return job


def probe(path, entries):
    return subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", entries, "-of", "csv=p=0", path],
        capture_output=True, text=True, check=True,
    ).stdout.split()


def last_pts(path, stream):
    """Where the last packet of `stream` ("v:0", "a:0") lies, in seconds."""
    return float(subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", stream, "-show_entries", "packet=pts_time", "-of", "csv=p=0", path],
        capture_output=True, text=True, check=True,
    ).stdout.split()[-1])


def kept_for_phone(folder):
    return sorted(n for n in os.listdir(folder) if n.startswith("video") or n == "bundle.json")


def test_a_step_job_keeps_its_video_and_captions_for_the_phone():
    cache = fresh_cache()
    url, playlist = hls_stream(6)
    page = "https://example.com/watch/1"
    job = step_job(url, page, 6)
    assert job.status()["bundle"] == "none"
    # The job keeps its captions in the cache; the ones it would have made
    # are put there.
    job.cache.save_findings("captions-speech", {"lines": LINES})
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        assert srv.start_bundle(job, TITLE) == (200, {"bundle": "running"})
        # Asked again meanwhile, the fetch running is left to run.
        fetch = srv._bundle_fetches[job.cache.dir]
        assert srv.start_bundle(job, TITLE) == (200, {"bundle": "running"})
        assert srv._bundle_fetches[job.cache.dir] is fetch
        assert job.status()["bundle"] == "running"
        assert wait_for_bundle(job) == "done", fetch.error
    status = job.status()
    assert status["bundle"] == "done" and abs(status["bundle_fetched"] - 6) < 0.2, status
    folder = job.cache.dir
    assert kept_for_phone(folder) == ["bundle.json", "video.mp4"], kept_for_phone(folder)
    with open(os.path.join(folder, "bundle.json"), encoding="utf-8") as f:
        bundle = json.load(f)
    assert bundle["version"] == 1 and bundle["id"] == os.path.basename(folder) and bundle["title"] == TITLE
    assert bundle["video"] == "video.mp4" and bundle["size"] == os.path.getsize(os.path.join(folder, "video.mp4"))
    assert bundle["step"] == "speech" and bundle["lines"] == LINES, bundle["lines"]
    assert bundle["created"].endswith("Z") and len(bundle["created"]) == 20, bundle["created"]
    # The mp4 is on the stream's own timeline shifted to begin at zero,
    # its packets where the stream had them, which is the timeline the
    # captions were timed on (and the browser's): a playlist's declared
    # length is only its segments' targets, so it is the packets that are
    # compared. ffmpeg's own streams begin at 1.4 s, which shows the shift.
    video = os.path.join(folder, "video.mp4")
    shift = float(probe(playlist, "format=start_time")[0])
    assert shift > 1, shift
    for stream in ("v:0", "a:0"):
        assert abs(last_pts(video, stream) - (last_pts(playlist, stream) - shift)) < 0.001, (
            stream, last_pts(video, stream), last_pts(playlist, stream), shift)
    kept = float(probe(video, "format=duration")[0])
    assert abs(bundle["duration"] - kept) < 0.01, (bundle["duration"], kept)
    assert probe(video, "stream=codec_type") == ["video", "audio"]
    # The index lists it for the phone.
    with open(os.path.join(cache, "index.json"), encoding="utf-8") as f:
        index = json.load(f)
    assert index == [{
        "id": bundle["id"], "title": TITLE, "duration": bundle["duration"], "created": bundle["created"],
        "size": bundle["size"], "lines": 2,
    }], index
    # The log names neither the title nor where the video came from.
    assert TITLE not in out.getvalue() and "http" not in out.getvalue(), out.getvalue()
    assert all(TITLE not in e["text"] and "http" not in e["text"] for e in srv._events)
    return job


def test_only_a_finished_step_job_in_dev_mode_keeps_its_video():
    fresh_cache()
    url, _ = hls_stream(2)
    job = step_job(url, "https://example.com/watch/2", 2)
    assert srv.start_bundle(job) == (409, {"error": "the job has no captions"})
    job.lines = list(LINES)
    job.captioned = False
    assert srv.start_bundle(job) == (409, {"error": "the captions have not reached the end yet"})
    job.captioned = True
    job.caption_error = "no model"
    assert srv.start_bundle(job) == (409, {"error": "the captions failed: no model"})
    job.caption_error = None
    step, job.step = job.step, None
    assert srv.start_bundle(job) == (409, {"error": "only a step job in dev mode keeps its video"})
    job.step = step
    assert job.status()["bundle"] == "none"


def test_a_video_that_comes_short_or_not_at_all_is_not_kept():
    fresh_cache()
    url, _ = hls_stream(2)
    job = step_job(url, "https://example.com/watch/3", 2)
    job.lines = list(LINES)
    # The stream link has gone stale: nothing to fetch.
    job.url = url.replace("playlist.m3u8", "gone.m3u8")
    assert srv.start_bundle(job)[0] == 200
    state = wait_for_bundle(job)
    assert state.startswith("failed: ffmpeg:") and "http" not in state, state
    assert job.status()["bundle"] == state
    assert kept_for_phone(job.cache.dir) == [], kept_for_phone(job.cache.dir)
    # The fetch ends early (the link stops serving partway, say): not kept.
    job.url = url
    job.duration = 100.0
    assert srv.start_bundle(job)[0] == 200
    state = wait_for_bundle(job)
    assert state == "failed: the video came short: 2s of 100s", state
    assert kept_for_phone(job.cache.dir) == []
    assert not os.path.exists(os.path.join(srv.DEV_CACHE_DIR, "index.json"))


def test_forgetting_the_phone_s_copy_keeps_the_audio_and_the_index_follows():
    job = test_a_step_job_keeps_its_video_and_captions_for_the_phone()
    cache, folder, page = srv.DEV_CACHE_DIR, job.cache.dir, job.page
    assert srv.clear_dev_cache(page, bundle_only=True) == 1
    assert kept_for_phone(folder) == []
    assert os.path.exists(os.path.join(folder, "audio.s16"))
    assert os.path.exists(os.path.join(folder, "captions-speech.json"))
    assert not os.path.exists(os.path.join(cache, "index.json"))
    assert job.status()["bundle"] == "none"
    assert srv.clear_dev_cache(page, bundle_only=True) == 0
    # Forgetting the video altogether takes the phone's copy with it.
    assert srv.start_bundle(job, TITLE)[0] == 200 and wait_for_bundle(job) == "done"
    assert os.path.exists(os.path.join(cache, "index.json"))
    assert srv.clear_dev_cache() == 1
    assert os.listdir(cache) == [], os.listdir(cache)


def test_a_page_with_no_direct_link_is_downloaded_by_yt_dlp():
    # yt-dlp stood in for by a script that answers --get-url with the
    # served stream (the audio fetch asks that) and otherwise writes the
    # file asked for, reporting progress the way yt-dlp does.
    fresh_cache()
    url, playlist = hls_stream(4)
    bin_dir = tempfile.mkdtemp()
    fake = os.path.join(bin_dir, "yt-dlp")
    with open(fake, "w", encoding="utf-8") as f:
        f.write(f"""#!/usr/bin/env python3
import subprocess, sys
args = sys.argv[1:]
if "--get-url" in args:
    print({url!r})
    sys.exit(0)
out = args[args.index("-o") + 1]
print("[download]  50.0% of 1.00MiB at 1.00MiB/s ETA 00:00", flush=True)
subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", {playlist!r},
                "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", out], check=True)
print("[download] 100.0% of 1.00MiB at 1.00MiB/s ETA 00:00", flush=True)
""")
    os.chmod(fake, 0o755)
    path = os.environ["PATH"]
    os.environ["PATH"] = bin_dir + os.pathsep + path
    try:
        job = step_job("", "https://example.com/watch/5", 4)
        job.lines = list(LINES)
        assert srv.start_bundle(job, TITLE)[0] == 200
        assert wait_for_bundle(job) == "done", srv._bundle_fetches[job.cache.dir].error
    finally:
        os.environ["PATH"] = path
    status = job.status()
    assert status["bundle"] == "done" and abs(status["bundle_fetched"] - 4) < 0.2, status
    assert kept_for_phone(job.cache.dir) == ["bundle.json", "video.mp4"]


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"ok {name}")

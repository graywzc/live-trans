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

# tailscale and sudo stood in for by scripts, first on PATH for the whole
# run, so that no test touches this machine's tailnet. The tailscale one
# answers `status --json` with a made-up tailnet name, `serve status
# --json` with the serve config kept in FAKE_TAILSCALE_STATE (the host's
# own HTTPS with one proxy until a path is added), and `serve --bg
# --set-path` by noting the call in FAKE_TAILSCALE_CALLS and adding the
# path, or, when FAKE_TAILSCALE_DENY is set and it is not run as root,
# by refusing the way tailscaled does a user it cannot verify. The sudo
# one runs what follows `-n` as root (the call noted with "sudo" before
# it), or refuses for want of a password when FAKE_SUDO_DENY is set.
TAILNET_HOST = "host.test-net.ts.net"
_fake_bin = tempfile.mkdtemp()
with open(os.path.join(_fake_bin, "tailscale"), "w", encoding="utf-8") as _f:
    _f.write(f"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
state = os.environ["FAKE_TAILSCALE_STATE"]
host = {TAILNET_HOST!r}
as_root = bool(os.environ.get("FAKE_TAILSCALE_ROOT"))


def config():
    try:
        with open(state) as f:
            return json.load(f)
    except OSError:
        return {{"TCP": {{"443": {{"HTTPS": True}}}},
                "Web": {{host + ":443": {{"Handlers": {{"/": {{"Proxy": "http://127.0.0.1:8080"}}}}}}}}}}


if args == ["status", "--json"]:
    print(json.dumps({{"Self": {{"DNSName": host + "."}}}}))
elif args == ["serve", "status", "--json"]:
    print(json.dumps(config()))
elif args[:3] == ["serve", "--bg", "--set-path"]:
    with open(os.environ["FAKE_TAILSCALE_CALLS"], "a") as f:
        f.write(("sudo " if as_root else "") + " ".join(args) + "\\n")
    if os.environ.get("FAKE_TAILSCALE_DENY") and not as_root:
        print("sending serve config: 401 Unauthorized: must be root, or be an operator and able to run "
              "'sudo tailscale' to serve a path or Unix socket", file=sys.stderr)
        sys.exit(1)
    current = config()
    current["Web"][host + ":443"]["Handlers"][args[3]] = {{"Path": args[4]}}
    with open(state, "w") as f:
        json.dump(current, f)
    print("Available within your tailnet:")
else:
    print("fake tailscale: unexpected arguments", args, file=sys.stderr)
    sys.exit(2)
""")
os.chmod(os.path.join(_fake_bin, "tailscale"), 0o755)
with open(os.path.join(_fake_bin, "sudo"), "w", encoding="utf-8") as _f:
    _f.write("""#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
if args[:1] != ["-n"]:
    print("fake sudo: only -n is expected", args, file=sys.stderr)
    sys.exit(2)
if os.environ.get("FAKE_SUDO_DENY"):
    print("sudo: a password is required", file=sys.stderr)
    sys.exit(1)
sys.exit(subprocess.run(args[1:], env=dict(os.environ, FAKE_TAILSCALE_ROOT="1")).returncode)
""")
os.chmod(os.path.join(_fake_bin, "sudo"), 0o755)
os.environ["PATH"] = _fake_bin + os.pathsep + os.environ["PATH"]
os.environ["FAKE_TAILSCALE_STATE"] = os.path.join(_fake_bin, "serve.json")
os.environ["FAKE_TAILSCALE_CALLS"] = os.path.join(_fake_bin, "calls.log")


def tailscale_calls():
    """The `serve --set-path` calls the fake tailscale has taken."""
    try:
        with open(os.environ["FAKE_TAILSCALE_CALLS"], encoding="utf-8") as f:
            return f.read().splitlines()
    except OSError:
        return []

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
    """A cache of its own for the test, empty, with the tailnet as the
    server first finds it: the folder not served, nothing asked yet."""
    srv.DEV_CACHE_DIR = tempfile.mkdtemp()
    scratch = tempfile.mkdtemp()
    os.environ["FAKE_TAILSCALE_STATE"] = os.path.join(scratch, "serve.json")
    os.environ["FAKE_TAILSCALE_CALLS"] = os.path.join(scratch, "calls.log")
    os.environ.pop("FAKE_TAILSCALE_DENY", None)
    os.environ.pop("FAKE_SUDO_DENY", None)
    srv._serve.update(url=None, error=None, thread=None)
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
    # And the cache folder is now served to the phone (see the serving
    # tests), the status saying where.
    assert status["bundle_url"] == f"https://{TAILNET_HOST}/livetrans" and status["bundle_serve_error"] is None
    return job


def test_the_bundles_are_served_to_the_phone_once_one_is_kept():
    cache = fresh_cache()
    url, _ = hls_stream(4)
    job = step_job(url, "https://example.com/watch/7", 4)
    job.lines = list(LINES)
    # Nothing is served, or asked of tailscale, for a cache with nothing
    # kept.
    status = job.status()
    assert status["bundle_url"] is None and status["bundle_serve_error"] is None, status
    assert tailscale_calls() == []
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        assert srv.start_bundle(job, TITLE)[0] == 200
        assert wait_for_bundle(job) == "done", srv._bundle_fetches[job.cache.dir].error
    # The first bundle kept has the server put the cache folder under
    # /livetrans of the host's own tailnet name, once.
    status = job.status()
    assert status["bundle_url"] == f"https://{TAILNET_HOST}/livetrans" and status["bundle_serve_error"] is None, status
    assert tailscale_calls() == [f"serve --bg --set-path /livetrans {os.path.realpath(cache)}"], tailscale_calls()
    # A server started later finds the folder served and asks nothing more.
    srv._serve.update(url=None, error=None)
    assert srv.ensure_bundle_serving() == f"https://{TAILNET_HOST}/livetrans"
    assert len(tailscale_calls()) == 1
    # At start, a cache holding bundles is seen to off the main thread.
    srv._serve.update(url=None, error=None)
    srv.ensure_bundle_serving_soon()
    srv._serve["thread"].join(10)
    assert srv.bundle_serving() == (f"https://{TAILNET_HOST}/livetrans", None)
    assert len(tailscale_calls()) == 1
    # Served somewhere else under that path, the folder is put there anew.
    srv._serve.update(url=None, error=None)
    with open(os.environ["FAKE_TAILSCALE_STATE"], encoding="utf-8") as f:
        config = json.load(f)
    config["Web"][f"{TAILNET_HOST}:443"]["Handlers"]["/livetrans"] = {"Path": tempfile.mkdtemp()}
    with open(os.environ["FAKE_TAILSCALE_STATE"], "w", encoding="utf-8") as f:
        json.dump(config, f)
    assert srv.ensure_bundle_serving() == f"https://{TAILNET_HOST}/livetrans"
    assert len(tailscale_calls()) == 2
    # The log tells of the serving without the host's name.
    assert "served to the tailnet under /livetrans" in out.getvalue() and TAILNET_HOST not in out.getvalue(), out.getvalue()


def test_when_tailscale_refuses_the_server_asks_as_root_or_tells_why_not():
    # tailscaled refuses the user; sudo wants a password: the bundle is
    # kept all the same, tailscale's refusal told in the status and the
    # log, no URL anywhere.
    cache = fresh_cache()
    os.environ["FAKE_TAILSCALE_DENY"] = "1"
    os.environ["FAKE_SUDO_DENY"] = "1"
    url, _ = hls_stream(4)
    job = step_job(url, "https://example.com/watch/8", 4)
    job.lines = list(LINES)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        assert srv.start_bundle(job, TITLE)[0] == 200
        assert wait_for_bundle(job) == "done", srv._bundle_fetches[job.cache.dir].error
    status = job.status()
    assert status["bundle"] == "done", status
    assert status["bundle_url"] is None, status
    assert status["bundle_serve_error"].startswith("sending serve config: 401 Unauthorized: must be root"), status
    assert "not served to the phone (sending serve config: 401" in out.getvalue(), out.getvalue()
    assert "http" not in out.getvalue(), out.getvalue()
    serve = f"serve --bg --set-path /livetrans {os.path.realpath(cache)}"
    assert tailscale_calls() == [serve], tailscale_calls()
    # sudo allowed without a password (the sudoers line from the README):
    # the next attempt is refused as the user again and then made as root.
    os.environ.pop("FAKE_SUDO_DENY")
    assert srv.ensure_bundle_serving() == f"https://{TAILNET_HOST}/livetrans"
    assert tailscale_calls() == [serve, serve, f"sudo {serve}"], tailscale_calls()
    assert job.status()["bundle_serve_error"] is None


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

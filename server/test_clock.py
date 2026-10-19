"""Times across a gap in the audio's timestamps (PacketClock): run with the
server's Python, `python test_clock.py`."""
import functools
import os
import subprocess
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


import asr_server as srv


def close(a, b, within=1e-6):
    return abs(a - b) < within


def frame_list(frames, tb=48000):
    """A framecrc file of `frames`, [(pts, samples)] at 48 kHz."""
    path = os.path.join(tempfile.mkdtemp(), "clock.crc")
    with open(path, "w") as f:
        f.write(f"#software: test\n#tb 0: 1/{tb}\n#media_type 0: audio\n")
        for pts, samples in frames:
            f.write(f"0, {pts}, {pts}, {samples}, {samples * 4}, 0x00000000\n")
    return path


def test_without_a_gap_the_two_clocks_are_one():
    clock = srv.PacketClock(frame_list([(k * 1024, 1024) for k in range(100)]), 0.0)
    for t in (0.0, 0.5, 1.2):
        assert close(clock.to_video(t), t) and close(clock.to_samples(t), t), t


def test_after_a_gap_the_samples_are_later_in_the_video():
    # 50 frames, then the timestamps jump half a second, then 50 more.
    frames = [(k * 1024, 1024) for k in range(50)] + [(50 * 1024 + 24000 + k * 1024, 1024) for k in range(50)]
    clock = srv.PacketClock(frame_list(frames), 0.0)
    joint = 50 * 1024 / 48000
    assert close(clock.to_video(joint - 0.1), joint - 0.1)
    assert close(clock.to_video(joint + 0.1), joint + 0.6)
    # And back: a moment after the gap, and one inside it.
    assert close(clock.to_samples(joint + 0.6), joint + 0.1)
    assert close(clock.to_samples(joint + 0.25), joint)


def test_a_job_begun_partway_is_on_the_video_clock_from_its_offset():
    # A seek: the first frame's timestamp is the stream's, the samples
    # begin at the offset.
    frames = [(5_000_000 + k * 1024, 1024) for k in range(40)]
    clock = srv.PacketClock(frame_list(frames), 600.0)
    assert close(clock.to_video(600.0), 600.0) and close(clock.to_video(600.5), 600.5)


def test_the_list_is_gone_once_finished_and_the_times_kept():
    path = frame_list([(0, 1024), (1024 + 4800, 1024)])
    clock = srv.PacketClock(path, 0.0)
    clock.finish()
    assert not os.path.exists(path)
    assert close(clock.to_video(1024 / 48000 + 0.01), 1024 / 48000 + 0.1 + 0.01)


_served = None


def served(path):
    """`path` over HTTP on this machine, as the fetch takes options only an
    HTTP input has."""
    global _served
    if _served is None:
        class Quiet(SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass

        directory = tempfile.mkdtemp()
        server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=directory))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        _served = (directory, server.server_address[1])
    directory, port = _served
    os.replace(path, os.path.join(directory, os.path.basename(path)))
    return f"http://127.0.0.1:{port}/{os.path.basename(path)}"


def stream_with_a_gap(gap):
    """An MPEG-TS file of two 3 s tones whose timestamps leave `gap`
    seconds between them, as the segments of some HLS streams do."""
    work = tempfile.mkdtemp()
    parts = []
    for k, (hz, at) in enumerate(((440, 0.0), (880, 3.0 + gap))):
        part = os.path.join(work, f"part{k}.ts")
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", f"sine=frequency={hz}:duration=3",
                        "-c:a", "aac", "-output_ts_offset", str(at), "-f", "mpegts", part], check=True)
        parts.append(part)
    joined = os.path.join(work, f"gap{int(gap * 1000)}.ts")
    with open(joined, "wb") as out:
        for part in parts:
            with open(part, "rb") as f:
                out.write(f.read())
    return joined


def fetched(url):
    """A job's fetch of `url` alone, run to its end (no transcription)."""
    transcribe = srv.PrefetchJob._transcribe
    srv.PrefetchJob._transcribe = lambda self: None
    try:
        job = srv.PrefetchJob(url, url, {}, None, 0)
    finally:
        srv.PrefetchJob._transcribe = transcribe
    deadline = time.time() + 30
    while not job.fetch_done and job.state == "running" and time.time() < deadline:
        time.sleep(0.05)
    assert job.fetch_done, (job.state, job.error)
    return job


def gap_in(path):
    """Where the audio's timestamps jump, from ffprobe: (the samples heard
    before it, in seconds; how long the jump is)."""
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
                          "packet=pts_time,duration_time", "-of", "csv=p=0", path],
                         capture_output=True, text=True, check=True).stdout.split()
    packets = [tuple(map(float, line.split(",")[:2])) for line in out]
    heard = 0.0
    for (pts, length), (after, _) in zip(packets, packets[1:]):
        heard += length
        if after - pts - length > 0.005:
            return heard, after - pts - length
    raise AssertionError("no gap")


def test_a_fetch_puts_the_samples_after_a_gap_where_they_are_in_the_video():
    path = stream_with_a_gap(0.6)
    joint, gap = gap_in(path)  # the encoder pads each part: not quite 3 s and 0.6 s
    assert 0.4 < gap < 0.7, gap
    job = fetched(served(path))
    # Before the jump the clocks agree; after it the video is `gap` ahead,
    # and a time asked for in the video comes back to the same samples.
    assert close(job._video(joint - 0.5), joint - 0.5, within=0.03)
    assert close(job._video(joint + 0.5), joint + 0.5 + gap, within=0.03), (job._video(joint + 0.5), joint, gap)
    assert close(job.clock.to_samples(joint + 0.5 + gap), joint + 0.5, within=0.03)
    assert close(job.status()["fetched"], job.fetched + gap, within=0.05), (job.status()["fetched"], job.fetched, gap)
    assert not os.path.exists(job.clock.path)


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"{name} ok")

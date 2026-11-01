"""The apps' service on the host: run with `python3 test_phone_service.py`."""
import json
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory

import phone_service


REPORT = {"build": "v0.1.82-2-gabc1234", "seconds": 30.1, "frames": 1800, "hitches": 2, "route": "BluetoothA2DPOutput",
          "low_power": False, "thermal": "nominal"}


def post(port, body, path="/timings"):
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=body, method="POST")
    try:
        return urllib.request.urlopen(request).status
    except urllib.error.HTTPError as error:
        return error.code


def test_a_report_is_kept_and_anything_else_refused():
    with TemporaryDirectory() as folder:
        file = Path(folder) / "timings.jsonl"
        server = ThreadingHTTPServer(("127.0.0.1", 0), phone_service.handler(file, Path(folder)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]
        assert post(port, json.dumps(REPORT).encode()) == 204
        kept = json.loads(file.read_text())
        assert kept["hitches"] == 2 and kept["received"] > 0
        assert post(port, b"not json") == 400
        assert post(port, json.dumps(REPORT).encode(), "/other") == 400
        assert post(port, json.dumps({**REPORT, "title": "a video"}).encode()) == 400
        assert post(port, json.dumps({**REPORT, "route": "x" * 33}).encode()) == 400
        assert post(port, json.dumps({**REPORT, "hitches": "many"}).encode()) == 400
        assert post(port, b"x" * 5000) == 400
        assert len(file.read_text().splitlines()) == 1
        server.shutdown()


def test_the_file_keeps_only_the_last_reports():
    with TemporaryDirectory() as folder:
        file = Path(folder) / "timings.jsonl"
        for index in range(5):
            phone_service.KEEP = 3
            phone_service.append(file, {"frames": index})
        assert [json.loads(line)["frames"] for line in file.read_text().splitlines()] == [2, 3, 4]


VIDEO = "0123456789abcdef"


def pick(port, change, video=VIDEO):
    return post(port, json.dumps(change).encode(), f"/picks/{video}")


def picks(port, video=VIDEO):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/picks/{video}") as answer:
        return json.load(answer)["picks"]


def test_picks_are_kept_per_caption_and_can_be_taken_back():
    with TemporaryDirectory() as folder:
        (Path(folder) / VIDEO).mkdir()
        server = ThreadingHTTPServer(("127.0.0.1", 0), phone_service.handler(Path(folder) / "t", Path(folder)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]
        assert picks(port) == {}
        assert pick(port, {"at": 12340, "pick": "nemo"}) == 204
        assert pick(port, {"at": 56780, "pick": "k2"}) == 204
        assert pick(port, {"at": 12340, "pick": "qwen"}) == 204
        assert picks(port) == {"12340": "qwen", "56780": "k2"}
        assert pick(port, {"at": 12340, "pick": None}) == 204
        assert picks(port) == {"56780": "k2"}
        assert json.loads((Path(folder) / VIDEO / "picks.json").read_text()) == {"56780": "k2"}
        server.shutdown()


def test_only_a_picks_change_to_a_kept_video_is_taken():
    with TemporaryDirectory() as folder:
        (Path(folder) / VIDEO).mkdir()
        server = ThreadingHTTPServer(("127.0.0.1", 0), phone_service.handler(Path(folder) / "t", Path(folder)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]
        assert pick(port, {"at": 1, "pick": "nemo"}, video="fedcba9876543210") == 404
        assert pick(port, {"at": 1, "pick": "nemo"}, video="..") == 404
        assert not (Path(folder) / "fedcba9876543210").exists()
        for bad in ({"at": 1, "pick": "someone"}, {"at": -1, "pick": "k2"}, {"at": "1", "pick": "k2"},
                    {"at": True, "pick": "k2"}, {"at": 1}, {"at": 1, "pick": "k2", "text": "a sentence"}):
            assert pick(port, bad) == 400, bad
        assert picks(port) == {}
        server.shutdown()


if __name__ == "__main__":
    test_a_report_is_kept_and_anything_else_refused()
    test_the_file_keeps_only_the_last_reports()
    test_picks_are_kept_per_caption_and_can_be_taken_back()
    test_only_a_picks_change_to_a_kept_video_is_taken()
    print("ok")

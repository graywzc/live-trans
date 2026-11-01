"""The phone's timings on the host: run with `python3 test_phone_timings.py`."""
import json
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory

import phone_timings


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
        server = ThreadingHTTPServer(("127.0.0.1", 0), phone_timings.handler(file))
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
            phone_timings.KEEP = 3
            phone_timings.append(file, {"frames": index})
        assert [json.loads(line)["frames"] for line in file.read_text().splitlines()] == [2, 3, 4]


if __name__ == "__main__":
    test_a_report_is_kept_and_anything_else_refused()
    test_the_file_keeps_only_the_last_reports()
    print("ok")

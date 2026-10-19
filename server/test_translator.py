"""The translator's failures, and the lines dropped as Whisper's stock
inventions: run with the server's Python, `python test_translator.py`."""
import io
import json
import socket
import urllib.error
import urllib.request

import asr_server as srv


def with_generate(fails_with):
    """translate_ollama with every request failing as `fails_with`; the
    translator's state before and after."""
    generate, ok = srv._ollama_generate, srv._ollama_ok

    def failing(*args, **kwargs):
        raise fails_with

    srv._ollama_generate, srv._ollama_ok = failing, True
    try:
        result = srv.translate_ollama(["今日は雨が降りそうだ"])
        return result, srv._ollama_ok
    finally:
        srv._ollama_generate, srv._ollama_ok = generate, ok


def test_a_request_too_slow_once_leaves_the_translator_on():
    for slow in (TimeoutError("timed out"), socket.timeout("timed out"), urllib.error.URLError(TimeoutError("timed out"))):
        result, ok = with_generate(slow)
        assert result is None and ok, (slow, result, ok)


def test_a_translator_that_is_not_there_is_turned_off():
    result, ok = with_generate(urllib.error.URLError(ConnectionRefusedError(111, "refused")))
    assert result is None and not ok


def test_every_request_caps_the_answer():
    sent = []
    urlopen = urllib.request.urlopen

    def recording(request, timeout):
        sent.append(json.loads(request.data))
        return io.BytesIO(json.dumps({"response": "It looks like rain today."}).encode())

    urllib.request.urlopen = recording
    try:
        srv._ollama_generate("今日は雨が降りそうだ", timeout=5)
    finally:
        urllib.request.urlopen = urlopen
    cap = sent[0]["options"]["num_predict"]
    assert 200 < cap <= 4 * len("今日は雨が降りそうだ") + 200, cap


def test_whispers_stock_lines_are_known_and_speech_is_not():
    for stock in ("ご視聴ありがとうございました", "チャンネル登録よろしくお願いします", "字幕作成 山田"):
        assert srv._STOCK_LINE.search(stock), stock
    for speech in ("今日は雨が降りそうだ", "ありがとうございました", "字幕を読むのが速いね"):
        assert not srv._STOCK_LINE.search(speech), speech


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"{name} ok")

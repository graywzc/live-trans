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


def test_the_prompts_and_the_health_name_the_target_language():
    kept = srv.TARGET
    try:
        srv.TARGET = "zh"
        for prompt in (srv._ollama_prompt(), srv._split_prompt(), srv._long_prompt()):
            assert "Simplified Chinese" in prompt and "English" not in prompt, prompt
        srv.TARGET = "en"
        assert "natural English" in srv._split_prompt()
    finally:
        srv.TARGET = kept


def test_a_chinese_translation_is_not_taken_for_a_piece_of_the_transcript():
    source = "今日は雨だね傘持ってきた"
    asked = []
    generate = srv._ollama_generate
    srv._ollama_generate = lambda text, timeout, prompt=None: asked.append(text) or "译文"
    try:
        # Broken up but left untranslated: each piece asked for alone.
        pieces = srv._breaks_only("今日は雨だね ||| 傘持ってきた", source)
        assert pieces == [("今日は雨だね", "译文"), ("傘持ってきた", "译文")], pieces
        # A Chinese translation, in kanji too, is not one of the pieces.
        assert srv._breaks_only("今日は雨だね ||| 今天下雨了\n傘持ってきた ||| 带伞了", source) == pieces
    finally:
        srv._ollama_generate = generate


def test_whisper_english_is_not_the_fallback_for_chinese():
    kept = srv.TARGET, srv.run_whisper, srv.translate_ollama, srv._ollama_ok, srv.TRANSLATE_BACKEND
    asked = []

    def whisper(audio, beam_size, prompt="", words=None, vad=False, task="transcribe"):
        asked.append(task)
        return ["雨だね"] if task == "transcribe" else ["It's raining."]

    srv.run_whisper, srv.translate_ollama, srv._ollama_ok, srv.TRANSLATE_BACKEND = whisper, lambda segments: None, True, "ollama"
    try:
        srv.TARGET = "zh"
        _, pairs, _ = srv.transcribe_and_translate(srv.np.zeros(16000, srv.np.float32), beam_size=1)
        assert pairs == [("雨だね", "")] and asked == ["transcribe"], (pairs, asked)
        srv.TARGET = "en"
        _, pairs, _ = srv.transcribe_and_translate(srv.np.zeros(16000, srv.np.float32), beam_size=1)
        assert pairs == [("雨だね", "It's raining.")], pairs
    finally:
        srv.TARGET, srv.run_whisper, srv.translate_ollama, srv._ollama_ok, srv.TRANSLATE_BACKEND = kept

def test_a_translation_still_in_kana_is_the_japanese_again():
    assert srv._left_in_japanese("今日は雨だね")
    assert srv._left_in_japanese("うっ")
    assert not srv._left_in_japanese("今天下雨了")
    assert not srv._left_in_japanese("It's raining.")
    assert not srv._left_in_japanese("天才"), "kanji alone may be Chinese for the same word"
    assert not srv._left_in_japanese("")


def test_a_batch_copied_rather_than_translated_is_asked_again_then_line_by_line():
    source = ["今日は雨だね", "傘持ってきた", "もちろんだよ"]
    copied = "\n".join(f"{ja} ||| {ja}" for ja in source)
    translated = "今日は雨だね ||| 今天下雨了\n傘持ってきた ||| 带伞了吗\nもちろんだよ ||| 当然"
    why = []
    assert srv._parse_pairs(copied, "\n".join(source), why) is None
    assert why == ["3 of 3 lines left in Japanese"], why
    asked = []
    generate = srv._ollama_generate

    def answers(*replies):
        def fake(text, timeout, prompt=None):
            asked.append(prompt)
            return replies[min(len(asked), len(replies)) - 1]
        return fake

    try:
        # Asked again, told to translate: the second answer is used.
        srv._ollama_generate = answers(copied, translated)
        pairs = srv.translate_ollama(source)
        assert [en for _, en in pairs] == ["今天下雨了", "带伞了吗", "当然"], pairs
        assert len(asked) == 2 and "never the Japanese again" in asked[1]
        # Copied twice: line by line, each line's own translation.
        asked.clear()
        srv._ollama_generate = answers(copied, copied, "译一", "译二", "译三")
        assert [en for _, en in srv.translate_ollama(source)] == ["译一", "译二", "译三"]
    finally:
        srv._ollama_generate = generate


def test_one_line_left_in_japanese_is_translated_alone_or_left_empty():
    generate = srv._ollama_generate
    replies = iter(["呃", "うっ"])
    srv._ollama_generate = lambda text, timeout, prompt=None: next(replies)
    try:
        pairs = srv._translate_what_is_left([("今日は雨だね", "今天下雨了"), ("うっ", "うっ"), ("あっ", "あっ")])
        assert pairs == [("今日は雨だね", "今天下雨了"), ("うっ", "呃"), ("あっ", "")], pairs
    finally:
        srv._ollama_generate = generate

def test_two_lines_given_one_translation_are_translated_again_each_alone():
    generate = srv._ollama_generate
    asked = []
    srv._ollama_generate = lambda text, timeout, prompt=None: asked.append(text) or f"译文{len(asked)}"
    try:
        pairs = srv._translate_what_is_left([
            ("公害ですかああ", "是罗兰交给我的纸。"),
            ("ローランから渡された紙だ", "是罗兰交给我的纸。"),
            ("うん", "嗯"), ("うん", "嗯"),
        ])
    finally:
        srv._ollama_generate = generate
    assert pairs == [("公害ですかああ", "译文1"), ("ローランから渡された紙だ", "译文2"),
                     ("うん", "嗯"), ("うん", "嗯")], pairs
    assert asked == ["公害ですかああ", "ローランから渡された紙だ"], "the same words may share a translation"

def test_an_answer_out_of_format_but_one_line_per_segment_is_taken_by_position():
    segments = ["今日は雨だね", "傘持ってきた", "もちろんだよ"]
    generate = srv._ollama_generate
    asked = []

    def answers(*replies):
        def fake(text, timeout, prompt=None):
            asked.append(prompt)
            return replies[min(len(asked), len(replies)) - 1]
        return fake

    try:
        # The translations alone, one line each.
        srv._ollama_generate = answers("今天下雨了\n带伞了吗\n当然")
        assert srv.translate_ollama(segments) == list(zip(segments, ["今天下雨了", "带伞了吗", "当然"]))
        assert len(asked) == 1
        # Translated where the Japanese was to be copied.
        asked.clear()
        srv._ollama_generate = answers("今天下雨 ||| 今天下雨了\n带伞 ||| 带伞了吗\n当然 ||| 当然")
        assert [en for _, en in srv.translate_ollama(segments)] == ["今天下雨了", "带伞了吗", "当然"]
        # Lines not one per segment: asked once more, told the format.
        asked.clear()
        srv._ollama_generate = answers("今天下雨了，带伞了吗\n当然",
                                       "今日は雨だね ||| 今天下雨了\n傘持ってきた ||| 带伞了吗\nもちろんだよ ||| 当然")
        assert [en for _, en in srv.translate_ollama(segments)] == ["今天下雨了", "带伞了吗", "当然"]
        assert len(asked) == 2 and "never translated" in asked[1]
    finally:
        srv._ollama_generate = generate

if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"{name} ok")

"""ReazonSpeech in Whisper's place (LIVETRANS_ASR=reazon): run with the
server's Python, `python test_reazon.py`. A stand-in recognizer records what
it is given and answers with characters at times, so no model is needed."""
import numpy as np

import asr_server as srv


class FakeStream:
    def __init__(self, recognizer):
        self.recognizer = recognizer
        self.result = None

    def accept_waveform(self, rate, samples):
        self.samples = samples


class FakeRecognizer:
    """Answers each stream with `answer`: [(character, seconds into what it
    was given), ...]."""

    def __init__(self, answer):
        self.answer = answer
        self.given = []

    def create_stream(self):
        return FakeStream(self)

    def decode_stream(self, stream):
        self.given.append(stream.samples.size / srv.SAMPLE_RATE)

        class Result:
            tokens = [c for c, _ in self.answer]
            timestamps = [t for _, t in self.answer]

        stream.result = Result()


def with_recognizer(recognizer, call):
    kept = srv._reazon, srv.ASR_BACKEND
    srv._reazon, srv.ASR_BACKEND = recognizer, "reazon"
    try:
        return call()
    finally:
        srv._reazon, srv.ASR_BACKEND = kept


def test_a_long_clip_is_cut_at_its_quietest_moment():
    audio = np.full(40 * srv.SAMPLE_RATE, 0.1, dtype=np.float32)
    audio[int(11.0 * srv.SAMPLE_RATE):int(11.3 * srv.SAMPLE_RATE)] = 0.0
    pieces = srv._reazon_pieces(audio, 0.0, 40.0)
    assert all(b - a <= srv.REAZON_PIECE for a, b in pieces), pieces
    assert 11.0 <= pieces[0][1] <= 11.3, pieces
    assert pieces[0][0] == 0.0 and pieces[-1][1] == 40.0
    assert srv._reazon_pieces(audio, 2.0, 9.0) == [(2.0, 9.0)]


def test_characters_come_back_as_words_on_the_audio_s_clock():
    # Given half a second of silence first, the recognizer's times are
    # half a second late; a gap of a second or more starts a segment.
    answer = [("今", 0.6), ("日", 0.8), ("は", 1.0), ("雨", 2.7), ("だ", 2.9)]
    recognizer = FakeRecognizer(answer)
    words, breaks = [], []
    audio = np.zeros(6 * srv.SAMPLE_RATE, dtype=np.float32)
    texts = with_recognizer(recognizer, lambda: srv.run_whisper(audio, words=words, breaks=breaks, clips=[(1.0, 5.0)]))
    assert texts == ["今日は", "雨だ"], texts
    assert [w[0] for w in words] == ["今", "日", "は", "雨", "だ"]
    assert abs(words[0][1] - 1.1) < 1e-6 and abs(words[0][2] - 1.3) < 1e-6, words[0]
    assert abs(words[3][1] - 3.2) < 1e-6, words[3]
    assert words[-1][2] <= 5.0 + 1e-6, "the last character ends by the end of its clip"
    assert breaks == [(0, words[0][1]), (3, words[3][1])], breaks
    assert recognizer.given == [4.0 + 2 * srv.REAZON_PAD], "the clip, padded either side"


def test_whisper_still_translates_and_reazon_is_off_by_default():
    assert srv.ASR_BACKEND in ("whisper", "reazon")
    recognizer = FakeRecognizer([])
    asked = []
    kept = srv._asr

    class FakeWhisper:
        def transcribe(self, audio, **kwargs):
            asked.append(kwargs["task"])
            return [], None

    srv._asr = FakeWhisper()
    try:
        with_recognizer(recognizer, lambda: srv.run_whisper(np.zeros(16000, np.float32), task="translate"))
    finally:
        srv._asr = kept
    assert asked == ["translate"] and recognizer.given == [], (asked, recognizer.given)


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"ok {name}")

"""The cut grid and the hearing of pieces, with Whisper and the LLM stood
in for: run with the server's Python, `python test_grid.py`. The
sentences are invented."""
import numpy as np

import asr_server as srv

SR = srv.SAMPLE_RATE


def silence(seconds):
    """Audio for a hearing stood in for: nothing in it is listened to."""
    return np.zeros(int(seconds * SR), dtype=np.float32)


def grid_with(speech, began, end):
    """A grid told where the speech is, in place of Silero hearing it."""
    grid = srv.CutGrid()
    grid.add_speech([(began + a, began + b) for a, b in speech], began, end)
    return grid


class FakeWhisper:
    """Words with times, as Whisper gives them. Each clip asked for is
    decoded on its own: its segment holds the words heard within it, cut
    into more segments where `breaks_at` names a word."""

    def __init__(self, words, breaks_at=()):
        self.words = words  # [(text, start, end), ...]
        self.breaks_at = set(breaks_at)

    def __call__(self, audio, beam_size=3, task="transcribe", prompt=None, words=None, vad=False, breaks=None,
                 clips=None):
        texts = []
        for a, b in clips or [(0, audio.size / SR)]:
            inside = [w for w in self.words if a <= (w[1] + w[2]) / 2 < b]
            segment = []
            for word in inside:
                if word[0] in self.breaks_at and segment:
                    texts.append(self.flush(segment, words, breaks))
                    segment = []
                segment.append(word)
            if segment:
                texts.append(self.flush(segment, words, breaks))
        return texts

    @staticmethod
    def flush(segment, words, breaks):
        if breaks is not None:
            breaks.append((len(words), segment[0][1]))
        words.extend(segment)
        return "".join(w for w, _, _ in segment)


def test_hard_cuts_and_edges():
    grid = grid_with([(0.5, 2.0), (2.3, 4.0), (5.0, 6.0)], 100.0, 107.0)
    assert grid.cuts[0] == 100.0 and grid.cuts[-1] == 107.0, grid.cuts
    inner = [c for c in grid.cuts if 100 < c < 107]
    assert len(inner) == 1 and 104.3 < inner[0] < 104.7, grid.cuts  # the second's pause, not the 0.3 s one
    assert grid.pieces(100.6, 100.7) == [(100.0, inner[0])]
    # Asked for by a line's rounded times, a piece is its own alone, even
    # where the speech runs on across a soft cut into the next.
    grid.cut_between(("はい", 102.0, 102.5), ("そう", 102.51, 103.0), heard=True)
    cut = round(grid.cuts[1], 2)
    assert grid.pieces(100.5, cut) == [(100.0, grid.cuts[1])], grid.pieces(100.5, cut)
    assert grid.pieces(cut, 104.0) == [(grid.cuts[1], grid.cuts[2])], grid.pieces(cut, 104.0)
    low, high = grid.bounds(100.0, inner[0])
    assert 100.4 < low < 100.7 and 103.8 < high < 104.2, (low, high)


def test_sentences_heard_to_end_cut_for_good(monkeypatch=None):
    grid = grid_with([(0.2, 5.8)], 10.0, 16.0)
    audio = silence(6.0)
    assert grid.cuts == [10.0, 16.0]
    # One segment, two sentences: punctuation ends the first inside the piece.
    first = FakeWhisper([("今日は", 0.3, 0.8), ("晴れです。", 0.9, 1.6), ("明日は", 2.0, 2.5), ("雨かな", 2.6, 3.2)])
    srv.run_whisper, real_whisper = first, srv.run_whisper
    srv.translate_ollama, real_translate = (lambda texts: [(t, f"en:{t}") for t in texts]), srv.translate_ollama
    try:
        lines = srv.hear_pieces(grid, audio, 10.0, beam_size=5, prompt="")
        assert [l["ja"] for l in lines] == ["今日は晴れです。", "明日は雨かな"], lines
        assert [l["en"] for l in lines] == ["en:今日は晴れです。", "en:明日は雨かな"], lines
        assert len(grid.cuts) == 3 and 11.6 < grid.cuts[1] < 12.0, grid.cuts
        # The piece's times are its speech's, so a line heard again lands
        # on the same times.
        assert lines[0]["start"] == round(10.2, 2) and lines[1]["end"] == round(15.8, 2), lines
        # Heard again with other words and no punctuation: the cut stays,
        # and the words go to the pieces by their times.
        second = FakeWhisper([("今日は", 0.3, 0.8), ("晴れだ", 0.9, 1.5), ("明日は", 2.0, 2.5), ("雨だな", 2.6, 3.2)])
        srv.run_whisper = second
        again = srv.hear_pieces(grid, audio, 10.0, beam_size=10, prompt="", within=(10.0, 16.0))
        assert [l["ja"] for l in again] == ["今日は晴れだ", "明日は雨だな"], again
        assert len(grid.cuts) == 3
        # Only the pieces asked for come back, and a cut outside them is
        # not made.
        third = FakeWhisper([("今日は", 0.3, 0.8), ("晴れ。", 0.9, 1.5), ("明日は", 2.0, 2.5), ("雨。", 2.6, 2.9), ("風も強い。", 3.0, 3.4)])
        srv.run_whisper = third
        some = srv.hear_pieces(grid, audio, 10.0, beam_size=10, prompt="", within=(10.0, grid.cuts[1]))
        assert [l["ja"] for l in some] == ["今日は晴れ。"], some
        assert len(grid.cuts) == 3, grid.cuts
        # Nor does a neighbour whose speech runs up to the cut.
        other = srv.hear_pieces(grid, audio, 10.0, beam_size=10, prompt="", within=(grid.cuts[1], 16.0))
        assert [l["ja"] for l in other] == ["明日は雨。", "風も強い。"], other
        assert len(grid.cuts) == 4, grid.cuts
    finally:
        srv.run_whisper, srv.translate_ollama = real_whisper, real_translate


def test_llm_sentence_ends_cut_and_straddling_ones_are_translated_apart():
    grid = grid_with([(0.2, 2.0), (2.8, 5.0)], 0.0, 6.0)  # a 0.8 s pause: a hard cut
    audio = silence(6.0)
    assert len(grid.cuts) == 3
    whisper = FakeWhisper([("駅まで", 0.3, 0.8), ("歩いた", 0.9, 1.4), ("のに", 1.5, 1.9), ("みなさん", 2.9, 3.5), ("お元気", 3.6, 4.2), ("ですか", 4.3, 4.9)])
    calls = []

    def llm(texts):
        calls.append(list(texts))
        # The LLM joins the two pieces into one sentence, and cuts the
        # second piece in two.
        return [("駅まで歩いたのにみなさん", "en:A"), ("お元気ですか", "en:B")]

    srv.run_whisper, real_whisper = whisper, srv.run_whisper
    srv.translate_ollama, real_translate = llm, srv.translate_ollama
    srv.translate_text, real_text = (lambda ja: f"own:{ja}"), srv.translate_text
    try:
        lines = srv.hear_pieces(grid, audio, 0.0, beam_size=5, prompt="")
        assert calls == [["駅まで歩いたのに", "みなさんお元気ですか"]], calls
        assert [l["ja"] for l in lines] == ["駅まで歩いたのに", "みなさん", "お元気ですか"], lines
        # The sentence straddling the hard cut is translated piece by
        # piece; the LLM's own sentence keeps its English.
        assert [l["en"] for l in lines] == ["own:駅まで歩いたのに", "own:みなさん", "en:B"], lines
        assert len(grid.cuts) == 4, grid.cuts
    finally:
        srv.run_whisper, srv.translate_ollama, srv.translate_text = real_whisper, real_translate, real_text


def test_a_word_timed_early_stays_with_its_sentence():
    grid = grid_with([(0.2, 2.0), (2.3, 4.0)], 0.0, 5.0)
    grid.cut_between(("ください", 1.5, 2.0), ("明", 2.3, 2.4), heard=True)
    assert len(grid.cuts) == 3 and 2.1 < grid.cuts[1] < 2.2, grid.cuts
    # Heard again, Whisper puts the first character of 明日 before the
    # cut: the gap between two kanji is not where a sentence breaks, so
    # the cut falls after ください.
    marked = grid_with([(0.2, 2.0), (2.3, 4.0)], 0.0, 5.0)
    marked.cut_between(("ください", 1.5, 2.0), ("明", 2.3, 2.4), heard=True, tail="言わないでください", head="明日行くよ")
    assert marked.marks[marked.cuts[1]] == ("ださい", "明日行"), marked.marks
    whisper = FakeWhisper([("言わないで", 0.3, 1.4), ("ください", 1.5, 2.0), ("明", 2.05, 2.2), ("日", 2.3, 2.5), ("行くよ", 2.6, 3.5)])
    srv.run_whisper, real_whisper = whisper, srv.run_whisper
    srv.translate_ollama, real_translate = (lambda texts: [(t, "en") for t in texts]), srv.translate_ollama
    try:
        lines = srv.hear_pieces(grid, silence(5.0), 0.0, beam_size=5, prompt="")
        assert [l["ja"] for l in lines] == ["言わないでください", "明日行くよ"], lines
        # With the cut's marks, the first word of 明日 is placed by its
        # text, even timed half a second early.
        srv.run_whisper = FakeWhisper([("言わないで", 0.3, 1.4), ("ください", 1.5, 1.7), ("明", 1.72, 1.8), ("日", 2.3, 2.5), ("行くよ", 2.6, 3.5)])
        lines = srv.hear_pieces(marked, silence(5.0), 0.0, beam_size=5, prompt="")
        assert [l["ja"] for l in lines] == ["言わないでください", "明日行くよ"], lines
        # The marks of a cut are set as it is made, and the hearing that
        # made it lands its words on it exactly.
        fresh = grid_with([(0.2, 4.0)], 0.0, 5.0)
        srv.run_whisper = FakeWhisper([("言わないで", 0.3, 1.4), ("ください。", 1.5, 1.7), ("明", 1.72, 1.8), ("日", 2.3, 2.5), ("行くよ", 2.6, 3.5)])
        lines = srv.hear_pieces(fresh, silence(5.0), 0.0, beam_size=5, prompt="")
        assert [l["ja"] for l in lines] == ["言わないでください。", "明日行くよ"], lines
        assert fresh.marks[fresh.cuts[1]] == ("ださい", "明日行"), fresh.marks
    finally:
        srv.run_whisper, srv.translate_ollama = real_whisper, real_translate


def test_a_pause_belongs_to_the_gap_next_to_it():
    # Speech runs 0.2-1.9 and 2.3-3.9 with a 0.4 s pause: a soft cut
    # at most. Whisper times どう, the first word after the pause, 0.3 s
    # early, so that the pause lies under it, and begins a segment at it.
    # The segment break before どう claims the pause for the gap before
    # it; nothing about the words themselves (した ending in た) may
    # claim it for the gap after.
    grid = grid_with([(0.2, 1.9), (2.3, 3.9)], 0.0, 5.0)
    assert grid.cuts == [0.0, 5.0]
    whisper = FakeWhisper([("大変", 0.3, 0.7), ("だ", 0.7, 0.9), ("大変", 1.0, 1.5), ("だ", 1.5, 1.8),
                           ("どう", 1.95, 2.3), ("した", 2.3, 2.6), ("んですか", 2.6, 3.1), ("海野さん", 3.2, 3.8)],
                          breaks_at=("どう",))
    srv.run_whisper, real_whisper = whisper, srv.run_whisper
    srv.translate_ollama, real_translate = (lambda texts: [(t, "en") for t in texts]), srv.translate_ollama
    try:
        lines = srv.hear_pieces(grid, silence(5.0), 0.0, beam_size=5, prompt="")
        assert [l["ja"] for l in lines] == ["大変だ大変だ", "どうしたんですか海野さん"], lines
        assert len(grid.cuts) == 3 and 2.05 < grid.cuts[1] < 2.15, grid.cuts
        assert grid.marks[grid.cuts[1]] == ("大変だ", "どうし"), grid.marks
    finally:
        srv.run_whisper, srv.translate_ollama = real_whisper, real_translate


def test_a_hard_cut_goes_by_the_clip_a_word_was_heard_in():
    grid = grid_with([(0.2, 2.0), (2.6, 4.0)], 0.0, 5.0)  # a 0.6 s pause: a hard cut at 2.3
    assert len(grid.cuts) == 3 and grid.cuts[1] in grid.hard
    # Whisper decodes the two clips apart; it times the second's first
    # word 0.4 s early, into the pause and before the cut, as it does.
    heard = [[("大変だ", 0.3, 1.0), ("大変だ", 1.1, 1.9)], [("どう", 2.15, 2.3), ("したんですか", 2.5, 3.9)]]
    clips_seen = []

    def decode(audio, clips=None, words=None, breaks=None, **kw):
        clips_seen.append(clips)
        return [FakeWhisper.flush(segment, words, breaks) for segment in heard]

    srv.run_whisper, real_whisper = decode, srv.run_whisper
    srv.translate_ollama, real_translate = (lambda texts: [(t, "en") for t in texts]), srv.translate_ollama
    try:
        lines = srv.hear_pieces(grid, silence(5.0), 0.0, beam_size=5, prompt="")
        assert [l["ja"] for l in lines] == ["大変だ大変だ", "どうしたんですか"], lines
        # The clips asked for run a little into the pauses, not past the cut.
        (a, b), (c, d) = clips_seen[0]
        assert abs(a - 0.05) < 1e-6 and abs(b - 2.15) < 1e-6 and abs(c - 2.45) < 1e-6 and abs(d - 4.15) < 1e-6, clips_seen
    finally:
        srv.run_whisper, srv.translate_ollama = real_whisper, real_translate


def test_neighbours_that_follow_on():
    grid = grid_with([(0.5, 2.0), (2.6, 4.0), (6.0, 7.0)], 0.0, 8.0)
    middle = grid.pieces(2.7, 2.8)
    assert len(middle) == 1
    low, high = grid.with_neighbours(middle)
    assert low == 0.0 and 4.0 < high < 6.0, (low, high)  # the first follows on; the third is 2 s off


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"{name} ok")

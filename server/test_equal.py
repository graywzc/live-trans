"""The three recognizers heard as equals, with each of them stood in for:
run with the server's Python, `python test_equal.py`. The sentences are
invented, and in kana, so each reads as it is written."""
import os
import stat
import sys
import tempfile
import threading

import numpy as np

import asr_server as srv


def _no_translator(*args, **kwargs):
    raise RuntimeError("no translator in these tests")


srv._ollama_generate = _no_translator
# As if each batch took too long: left untranslated, the captions go on.
srv.translate_ollama = lambda segments: None
SR = srv.SAMPLE_RATE


def silence(seconds):
    return np.zeros(int(seconds * SR), dtype=np.float32)


def heard(**versions):
    """A clip as hear_equally gives it: each version's characters spread
    over 0-1 s, read as written."""
    clip = {"versions": {}, "readings": {}}
    for name, text in versions.items():
        chars = srv._chars_of(text)
        step = 1.0 / max(len(chars), 1)
        clip["versions"][name] = [[c, k * step, (k + 1) * step, end] for k, (c, end) in enumerate(chars)]
        clip["readings"][name] = [c for c, _ in chars]
    return clip


def test_the_caption_is_the_version_nearest_the_others_and_two_must_agree():
    # k2 heard a word wrong; nemo and qwen agree, and nemo wins the tie.
    assert srv.chosen(heard(k2="あめがふるね", nemo="あめがふるよね", qwen="あめがふるよね")) == "nemo"
    # qwen alone is nearest both others.
    assert srv.chosen(heard(k2="あめがふる", nemo="あめがふるよね", qwen="あめがふるよ")) == "qwen"
    # Only one heard it at all: no caption.
    assert srv.chosen(heard(qwen="ごしちょうありがとう")) is None
    # Two heard different things: no caption.
    assert srv.chosen(heard(k2="あ", qwen="ごしちょうありがとう")) is None
    # One disagreeing with two who agree is left out of the choice.
    assert srv.chosen(heard(k2="らららららら", nemo="あめがふる", qwen="あめがふる")) == "nemo"
    # With neither nemo nor qwen to be had, k2 alone.
    alone = heard(k2="あめ")
    alone["alone"] = True
    assert srv.chosen(alone) == "k2"


def test_a_word_a_cut_falls_inside_is_read_on_both_sides():
    # The aligner reads a word on its first character: cut after いくよ,
    # the second speaker's ねえ is still read, and two agree on it.
    clip = heard(nemo="いくよねえ", qwen="いくよねえ")
    for name in clip["readings"]:
        clip["readings"][name] = ["いくよねえ", "", "", "", ""]
    assert srv._reading(clip, "nemo") == "いくよねえ"
    assert srv._reading(clip, "nemo", 0.0, 0.6) == "いくよ"
    assert srv._reading(clip, "nemo", 0.6, 1.0) == "ねえ"
    agree, _ = srv._agreeing(clip, 0.6, 1.0)
    assert agree == {"nemo", "qwen"}


def test_the_words_are_the_chosen_ones_with_a_sentence_end_only_where_another_heard_one():
    clip = heard(k2="あめだねいくよ", nemo="あめだね。いくよ。", qwen="あめだねいくよ。")
    words, breaks = [], []
    names = srv.equal_words([clip, {}], words, breaks, began=0.0)
    assert names == ["nemo", None]
    text = "".join(w[0] for w in words)
    # nemo's end after だね is its alone; the one at the end qwen heard too.
    assert text == "あめだねいくよ。", text
    assert breaks == [(0, 0.0)]


class FakeRecognizers:
    """k2 by clip start, and nemo, qwen and the aligner as workers: each
    hears what `said` gives it for the clip starting nearest, and counts
    what it was asked."""

    def __init__(self, said):
        self.said = said  # {clip start: {"k2": text, "nemo": text, "qwen": text}}
        self.asked = []

    def text(self, name, a):
        start = min(self.said, key=lambda s: abs(s - a))
        return self.said[start].get(name, "")

    def run_reazon(self, audio, words=None, breaks=None, clips=None, vad=False, piece=None):
        for a, b in clips:
            self.asked.append(("k2", round(a, 2)))
            chars = self.text("k2", a)
            step = (b - a) / max(len(chars), 1)
            words.extend((c, a + k * step, a + (k + 1) * step) for k, c in enumerate(chars))
        return []

    def worker(self, name):
        fake = self

        class Worker:
            def available(self):
                return True

            def ask(self, header, audio, lines=True):
                if name == "align":
                    fake.asked.append(("align", len(header["pieces"])))
                    return {
                        "pieces": [[[k * p["length"] / max(len(p["words"]), 1), (k + 1) * p["length"] / max(len(p["words"]), 1)]
                                    for k in range(len(p["words"]))] for p in header["pieces"]],
                        "readings": [list(text) for text in header["read"]],
                    }
                fake.asked.append((name, len(header["clips"])))
                return [{"i": i, "text": fake.text(name, a)} for i, (a, b) in enumerate(header["clips"])]

        return Worker()

    def __enter__(self):
        self.saved = srv.run_reazon, dict(srv._workers)
        srv.run_reazon = self.run_reazon
        for key, name in (("hear_nemo", "nemo"), ("hear_qwen", "qwen"), ("align", "align")):
            srv._workers[key] = self.worker(name)
        return self

    def __exit__(self, *exc):
        srv.run_reazon, workers = self.saved
        srv._workers.clear()
        srv._workers.update(workers)


def test_a_sentence_k2_dropped_is_a_caption_and_one_only_qwen_heard_is_none():
    grid = srv.CutGrid()
    grid.add_speech([(0.0, 2.0), (3.0, 5.0), (6.0, 7.0)], 0.0, 8.0)
    said = {
        # k2 kept only the last words of the first clip.
        0.0: {"k2": "そうだね", "nemo": "きょうはあめがふりそうだね。", "qwen": "きょうはあめがふりそうだね"},
        3.0: {"k2": "かさをもっていこうか", "nemo": "かさをもっていこうか。", "qwen": "かさをもっていこうか"},
        # Over the music only qwen heard words.
        6.0: {"qwen": "ごしちょうありがとうございました"},
    }
    cache = {}
    with FakeRecognizers(said) as fake:
        lines = srv.hear_pieces(grid, silence(8.0), 0.0, beam_size=5, prompt="", heard=cache)
        first = list(fake.asked)
        # Heard again (a caption cut where the speaker changes), no one listens.
        again = srv.hear_pieces(grid, silence(8.0), 0.0, beam_size=5, prompt="", heard=cache)
        assert fake.asked == first, fake.asked
    # (nemo's full stops are its alone, so they are not kept.)
    assert [line["ja"] for line in lines] == ["きょうはあめがふりそうだね", "かさをもっていこうか"], lines
    assert [line["heard_by"] for line in lines] == ["nemo", "nemo"]
    assert lines[0]["heard"] == {"k2": "そうだね", "qwen": "きょうはあめがふりそうだね"}, lines[0]["heard"]
    assert [line["ja"] for line in again] == [line["ja"] for line in lines]
    # Each heard the three clips once, at the same time.
    assert sorted(set(a[0] for a in first)) == ["align", "k2", "nemo", "qwen"], first
    assert ("nemo", 3) in first and ("qwen", 3) in first


def test_a_change_of_speaker_is_cut_where_the_others_heard_it_when_k2_stretches_a_word():
    # One says あしたはどうかなあ (0-1.5 s), another うんいいよ (1.9-3 s). k2,
    # whose version is chosen, stretches な across the quiet and times
    # the last あ into the second turn; nemo and qwen, timed by the
    # aligner, end the first turn at 1.45 s.
    grid = srv.CutGrid()
    grid.add_speech([(0.0, 1.5), (1.9, 3.0)], 0.0, 3.5)
    (a, b), = grid.clips(0.0, 3.5)

    def spread(text, first, second):
        chars = list(text)
        cut = text.index("うん")
        times = [first[0] + k * (first[1] - first[0]) / cut for k in range(cut)]
        times += [second[0] + k * (second[1] - second[0]) / (len(chars) - cut) for k in range(len(chars) - cut)]
        ends = times[1:] + [second[1]]
        return [[c, t, min(e, t + 0.15), False] for c, t, e in zip(chars, times, ends)]

    k2 = [[c, k * 0.17, (k + 1) * 0.17, False] for k, c in enumerate("あしたはどうか")]
    k2 += [["な", 1.2, 1.8, False], ["あ", 1.95, 1.97, False]]
    k2 += [[c, 1.95 + k * 0.2, 2.15 + k * 0.2, False] for k, c in enumerate("うんいいよ")]
    versions = {"k2": k2, "nemo": spread("あしたはどうかなあうんいいよね", (0.0, 1.45), (2.0, 2.9)),
                "qwen": spread("あしたもどうかなあうんいいよ", (0.0, 1.45), (2.0, 2.9))}
    cache = {(round(a, 2), round(b, 2)): {"versions": versions, "readings": {
        name: [c for c, *_ in chars] for name, chars in versions.items()}, "alone": False}}
    turns = [(0.0, 1.5, "A"), (1.9, 3.0, "B")]
    lines = srv.hear_pieces(grid, silence(3.5), 0.0, beam_size=5, prompt="", turns=turns, heard=cache)
    assert [line["ja"] for line in lines] == ["あしたはどうかなあ", "うんいいよ"], lines
    assert [line["heard_by"] for line in lines] == ["k2", "k2"]


def test_k2_is_timed_by_the_aligner_and_by_itself_only_when_the_aligner_fails():
    said = {1.0: {"k2": "あめだね", "nemo": "あめだね", "qwen": "あめだね"}}

    class Aligner:
        """Each character a point a tenth of a second on from the last."""

        def available(self):
            return True

        def ask(self, header, audio, lines=True):
            return {"pieces": [[[0.1 * k, 0.1 * k + 0.02] for k in range(len(p["words"]))] for p in header["pieces"]],
                    "readings": [list(text) for text in header["read"]]}

    class Down(Aligner):
        def ask(self, header, audio, lines=True):
            raise RuntimeError("align failed: out of memory")

    with FakeRecognizers(said):
        srv._workers["align"] = Aligner()
        clip, = srv.hear_equally(silence(4.0), [(1.0, 3.0)], began=10.0)
        assert [round(a, 2) for c, a, b, _ in clip["versions"]["k2"]] == [11.0, 11.1, 11.2, 11.3], clip["versions"]["k2"]
        assert clip["readings"]["k2"] == list("あめだね")
        srv._workers["align"] = Down()
        clip, = srv.hear_equally(silence(4.0), [(1.0, 3.0)], began=10.0)
        # k2's own times, half a second a character here, moved by K2_LEAD.
        assert [round(a, 2) for c, a, b, _ in clip["versions"]["k2"]] == [11.15, 11.65, 12.15, 12.65], clip["versions"]["k2"]
        assert clip.get("alone"), "nemo and qwen untimed are left out"


def test_a_vowel_that_draws_out_the_one_before_is_not_aligned_on_its_own():
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "devtools"))
    import align
    # でもなあ, そう, こう, ねえ, ちゃあ, and a long-vowel mark after anything.
    for before, char in [("な", "あ"), ("そ", "う"), ("こ", "う"), ("ね", "え"), ("ちゃ", "あ"), ("ナ", "ア"), ("な", "ー")]:
        assert align.draws_out(before, char), (before, char)
    # A new vowel, ん before it, せい (said with its い), nothing before.
    for before, char in [("な", "い"), ("ん", "あ"), ("せ", "い"), ("", "ー"), ("な", "か")]:
        assert not align.draws_out(before, char), (before, char)


def test_a_job_keeps_the_other_versions_by_the_caption_and_hears_nothing_again():
    job = srv.PrefetchJob.__new__(srv.PrefetchJob)
    job.others = {}
    lines = [{"ja": "かさ", "en": "", "start": 1.0, "end": 2.0, "heard_by": "nemo", "heard": {"k2": "かさ", "qwen": "かさ"}}]
    job._keep_heard(lines)
    assert job.others == {(1.0, 2.0): {"k2": "かさ", "qwen": "かさ"}}
    assert "heard" not in lines[0] and lines[0]["heard_by"] == "nemo"
    versions = srv.with_versions(lines, job.others)[0]["versions"]
    assert set(versions) == {"k2", "qwen"}, versions
    assert srv.bundle_line({**lines[0], "versions": versions})["heard_by"] == "nemo"
    job.equal = True
    job._hear_other_texts([(1.0, 2.0)])  # runs no tool: there is none here to run


ECHO = '''import json, sys
serve = "--serve" in sys.argv
while True:
    line = sys.stdin.buffer.readline()
    if not line.strip():
        break
    header = json.loads(line)
    sys.stdin.buffer.read(header["samples"] * 2)
    if header.get("die"):
        sys.exit(3)
    if header.get("fail"):
        print(json.dumps({"error": "asked to fail"}), flush=True)
    else:
        for i, clip in enumerate(header["clips"]):
            print(json.dumps({"i": i, "text": "x" * i}), flush=True)
    print(json.dumps({"done": True}), flush=True)
'''


def test_a_worker_keeps_running_between_requests_and_starts_again_after_it_dies():
    folder = tempfile.mkdtemp()
    os.makedirs(os.path.join(folder, "echo", "bin"))
    os.symlink(sys.executable, os.path.join(folder, "echo", "bin", "python"))
    with open(os.path.join(folder, "echo.py"), "w") as f:
        f.write(ECHO)
    original = srv.DEVTOOLS_DIR
    srv.DEVTOOLS_DIR = folder
    try:
        worker = srv.Worker("echo")
        assert worker.available()
        audio = silence(0.1)
        assert worker.ask({"clips": [[0, 1], [1, 2]]}, audio) == [{"i": 0, "text": ""}, {"i": 1, "text": "x"}]
        first = worker.process.pid
        assert worker.ask({"clips": [[0, 1]]}, audio) == [{"i": 0, "text": ""}]
        assert worker.process.pid == first, "the same process, its model still loaded"
        try:
            worker.ask({"clips": [], "fail": True}, audio)
            raise AssertionError("an error answer is raised")
        except RuntimeError as exc:
            assert "asked to fail" in str(exc)
        assert worker.process.pid == first, "a request that failed leaves it running"
        try:
            worker.ask({"clips": [], "die": True}, audio)
            raise AssertionError("a worker that dies is raised")
        except RuntimeError:
            pass
        assert worker.ask({"clips": [[0, 1]]}, audio) == [{"i": 0, "text": ""}]
        assert worker.process.pid != first, "started again"
        assert not srv.Worker("missing").available()
    finally:
        srv.DEVTOOLS_DIR = original


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print("ok", name)

"""Where a batch of speech for Whisper ends: run with the server's Python,
`python test_batches.py`."""
import asr_server as srv


def close(a, b):
    return abs(a - b) < 1e-6


def test_speech_is_gathered_up_to_a_minute_and_ends_in_a_long_pause():
    # Ten seconds of speech, a second's pause, over and over.
    speech = [(k * 11.0, k * 11.0 + 10.0) for k in range(9)]
    end, reason = srv.choose_batch(speech, 99.0, more=True)
    # The sixth stretch makes a minute; the pause after it ends the batch.
    assert close(end, 65.3) and reason == "pause 1.0s", (end, reason)


def test_it_waits_while_there_is_less_and_more_is_coming():
    speech = [(0.5, 10.0), (11.0, 20.0)]
    assert srv.choose_batch(speech, 20.2, more=True) is None
    # The same with nothing more to come is a batch to the end.
    assert srv.choose_batch(speech, 20.2, more=False) == (20.2, "end of the audio")


def test_speech_far_off_is_not_gathered_with_it():
    speech = [(0.5, 10.0), (11.0, 20.0), (27.0, 30.0)]
    end, reason = srv.choose_batch(speech, 40.0, more=True)
    assert close(end, 20.3) and reason == "pause 7.0s", (end, reason)


def test_a_silence_still_going_on_ends_the_batch_once_it_is_far():
    speech = [(0.5, 10.0)]
    assert srv.choose_batch(speech, 14.0, more=True) is None
    end, reason = srv.choose_batch(speech, 15.5, more=True)
    assert close(end, 10.3) and reason == "pause 5.5s or more", (end, reason)


def test_a_long_silence_before_the_speech_is_a_batch_of_nothing():
    end, reason = srv.choose_batch([(42.0, 50.0)], 60.0, more=True)
    assert close(end, 41.7) and reason == "silence 42s", (end, reason)
    # And silence alone is passed over as it comes.
    assert srv.choose_batch([], 3.0, more=True) is None
    assert srv.choose_batch([], 30.0, more=True) == (29.0, "silence 29s")
    assert srv.choose_batch([], 30.0, more=False) == (30.0, "end of the audio")


def test_a_batch_that_runs_long_ends_at_its_last_long_pause():
    # Under a minute of speech in ninety seconds, no pause far enough.
    speech = [(k * 10.0, k * 10.0 + 6.0) for k in range(10)]
    assert srv.choose_batch(speech, 80.0, more=True) is None
    end, reason = srv.choose_batch(speech, 96.0, more=True)
    assert close(end, 86.3) and reason == "pause 4.0s", (end, reason)


def test_speech_that_never_pauses_long_is_cut_in_its_longest_pause():
    speech = [(0.0, 40.0), (40.3, 70.0), (70.2, 95.0)]
    end, reason = srv.choose_batch(speech, 95.0, more=True)
    assert close(end, 40.15) and reason == "no long pause in 90s, the longest 0.30s", (end, reason)
    end, reason = srv.choose_batch([(0.0, 95.0)], 95.0, more=True)
    assert close(end, 60.0) and reason == "no pause in 90s", (end, reason)


def test_with_more_audio_than_was_looked_at_it_does_not_wait():
    speech = [(0.5, 30.0), (30.8, 50.0)]
    end, reason = srv.choose_batch(speech, 50.0, more=True, capped=True)
    assert close(end, 30.3) and reason == "pause 0.8s", (end, reason)


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"{name} ok")

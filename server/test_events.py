"""The log lines kept for the app to show: run with the server's Python,
`python test_events.py`."""
import asr_server as srv


def fresh():
    srv._events.clear()
    srv._event_count = 0


def test_lines_come_back_from_where_the_client_left_off():
    fresh()
    for n in range(3):
        srv.log(f"line {n}")
    first = srv.events_since(0)
    assert [e["text"] for e in first["events"]] == ["line 0", "line 1", "line 2"], first
    assert first["next"] == 3 and first["boot"] == srv._boot
    srv.log("line 3")
    later = srv.events_since(first["next"])
    assert [(e["seq"], e["text"]) for e in later["events"]] == [(4, "line 3")], later
    assert srv.events_since(later["next"])["events"] == []


def test_only_the_last_lines_are_kept():
    fresh()
    for n in range(srv.EVENTS_KEPT + 20):
        srv.log(f"line {n}")
    kept = srv.events_since(0)
    assert len(kept["events"]) == srv.EVENTS_KEPT
    assert kept["events"][0]["seq"] == 21 and kept["next"] == srv.EVENTS_KEPT + 20


def test_a_step_is_marked_and_never_printed():
    import contextlib
    import io

    fresh()
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        srv.log("3 lines in 1.0s")
        srv.detail("  line 0:01.0–0:02.5: 明日は晴れるでしょう")
    events = srv.events_since(0)["events"]
    assert [e.get("detail", False) for e in events] == [False, True], events
    assert printed.getvalue() == "3 lines in 1.0s\n", printed.getvalue()


def test_a_previews_steps_are_not_told():
    fresh()
    srv._untold.on = True
    try:
        srv.detail("Whisper: 4 words")
    finally:
        srv._untold.on = False
    assert srv.events_since(0)["events"] == []


def test_a_place_in_the_video():
    assert srv.clock(245.34) == "4:05.3" and srv.clock(7) == "0:07.0"
    assert srv.stretch(59.96, 61) == "1:00.0–1:01.0", srv.stretch(59.96, 61)


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"{name} ok")

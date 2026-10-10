"""The lines told for the app to show: run with the server's Python,
`python test_events.py`."""
import asr_server as srv


def fresh():
    srv._events.clear()
    srv._event_count = 0


def test_lines_come_back_from_where_the_client_left_off():
    fresh()
    for n in range(3):
        srv.tell(f"line {n}")
    first = srv.events_since(0)
    assert [e["text"] for e in first["events"]] == ["line 0", "line 1", "line 2"], first
    assert first["next"] == 3 and first["boot"] == srv._boot
    srv.tell("line 3")
    later = srv.events_since(first["next"])
    assert [(e["seq"], e["text"]) for e in later["events"]] == [(4, "line 3")], later
    assert srv.events_since(later["next"])["events"] == []


def test_only_the_last_lines_are_kept():
    fresh()
    for n in range(srv.EVENTS_KEPT + 20):
        srv.tell(f"line {n}")
    kept = srv.events_since(0)
    assert len(kept["events"]) == srv.EVENTS_KEPT
    assert kept["events"][0]["seq"] == 21 and kept["next"] == srv.EVENTS_KEPT + 20


def test_what_is_told_is_never_printed():
    import contextlib
    import io

    fresh()
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        srv.tell("line 0:01.0–0:02.5: 明日は晴れるでしょう")
    assert len(srv.events_since(0)["events"]) == 1
    assert printed.getvalue() == ""


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"{name} ok")

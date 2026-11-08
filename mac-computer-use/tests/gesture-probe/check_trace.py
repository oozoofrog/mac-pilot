#!/usr/bin/env python3
"""Compare mac-cu gesture frames with GestureProbe events.jsonl; no dependencies."""

import argparse
import json
import math
import sys


def distance(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def check(request, records, position_tolerance=5, time_tolerance=0.15, gestures=()):
    expected, active = [], {}
    peak = 0
    for frame in request["frames"]:
        for touch in frame["touches"]:
            ident, phase, time = touch["id"], touch["phase"], frame["time"]
            if phase == "down":
                assert ident not in active, f"request: contact {ident} already down"
                path = {"id": ident, "points": []}
                expected.append(path)
                active[ident] = path
            assert ident in active, f"request: contact {ident} is not down"
            path = active[ident]
            previous = path["points"][-1][1:] if path["points"] else None
            point = (touch["x"], touch["y"]) if "x" in touch else previous
            assert point is not None, "request: down needs coordinates"
            path["points"].append((time, *point))
            peak = max(peak, len(active))
            if phase in ("up", "cancel"):
                path["end"] = "cancelled" if phase == "cancel" else "ended"
                del active[ident]
    assert not active, "request ends with active contacts"
    assert expected, "request has no touches"
    received = [row for row in records if row.get("kind") == "touch"]
    assert received, "probe received no touches"
    observed = {}
    for row in received:
        count = sum(touch["phase"] not in ("ended", "cancelled") for touch in row["contacts"])
        assert row["active"] == count, "probe active count disagrees with contact phases"
        for touch in row["contacts"]:
            ident = touch["id"]
            if ident not in observed:
                assert touch["phase"] == "began", f"probe contact {ident} has no begin"
                observed[ident] = {"id": ident, "points": []}
            path = observed[ident]
            path["points"].append((row["timestamp"], touch["x"], touch["y"]))
            if touch["phase"] in ("ended", "cancelled"):
                path["end"] = touch["phase"]
    assert len(observed) == len(expected), f"contact lifetimes: expected {len(expected)}, received {len(observed)}"
    assert max(row["active"] for row in received) == peak, f"simultaneous contacts: expected {peak}"
    assert received[-1]["active"] == 0, "probe ends with active contacts"
    expected_origin = min(path["points"][0][0] for path in expected)
    observed_origin = min(path["points"][0][0] for path in observed.values())
    unmatched = list(observed.values())
    for path in expected:
        first = path["points"][0]
        candidates = [other for other in unmatched
                      if abs((other["points"][0][0] - observed_origin) - (first[0] - expected_origin)) <= time_tolerance
                      and distance(other["points"][0][1:], first[1:]) <= position_tolerance]
        assert candidates, f"no matching begin for request contact {path['id']} at {first}"
        other = min(candidates, key=lambda item: distance(item["points"][0][1:], first[1:])
                    + abs((item["points"][0][0] - observed_origin) - (first[0] - expected_origin)))
        unmatched.remove(other)
        assert other.get("end") == path["end"], f"contact {path['id']}: missing/wrong end phase"
        expected_duration = path["points"][-1][0] - first[0]
        observed_duration = other["points"][-1][0] - other["points"][0][0]
        assert abs(expected_duration - observed_duration) <= time_tolerance, f"contact {path['id']}: wrong lift time"
        for time, x, y in path["points"]:
            nearby = [point for point in other["points"]
                      if abs((point[0] - observed_origin) - (time - expected_origin)) <= time_tolerance]
            assert nearby and min(distance(point[1:], (x, y)) for point in nearby) <= position_tolerance, \
                f"contact {path['id']}: missing position {x},{y} at {time}"
        if all(distance(point[1:], first[1:]) <= position_tolerance for point in path["points"]):
            assert all(distance(point[1:], first[1:]) <= position_tolerance for point in other["points"]), \
                f"contact {path['id']}: stationary finger moved"
    for spec in gestures:
        name, _, count = spec.partition(":")
        assert any(row.get("kind") == "gesture" and row.get("gesture") == name and row.get("state") == 3
                   and (not count or row.get("requiredTouches", row.get("touches")) == int(count)) for row in records), \
            f"recognizer did not recognize {spec}"
    return {"passed": True, "contactLifetimes": len(expected), "maxTouches": peak, "gestures": list(gestures)}


def self_test():
    request = {"frames": [
        {"time": 0, "touches": [{"id": n, "phase": "down", "x": n * 50, "y": 300} for n in (1, 2, 3)]},
        {"time": 0.5, "touches": [{"id": 2, "phase": "move", "x": 120, "y": 300}]},
        {"time": 0.7, "touches": [{"id": 1, "phase": "up"}]},
        {"time": 1, "touches": [{"id": n, "phase": "up"} for n in (2, 3)]},
    ]}
    records, contacts = [], {}
    for frame in request["frames"]:
        for touch in contacts.values():
            touch["phase"] = "stationary"
        for change in frame["touches"]:
            ident = change["id"] + 10
            point = contacts.setdefault(ident, {"id": ident})
            point.update({key: value for key, value in change.items() if key in ("x", "y")})
            point["phase"] = {"down": "began", "move": "moved", "up": "ended"}[change["phase"]]
        records.append({"kind": "touch", "timestamp": 10 + frame["time"],
                        "contacts": [point.copy() for point in contacts.values()],
                        "active": sum(point["phase"] != "ended" for point in contacts.values())})
        contacts = {ident: point for ident, point in contacts.items() if point["phase"] != "ended"}
    assert check(request, records)["maxTouches"] == 3
    for mutate in (lambda rows: rows[0].update(active=2),
                   lambda rows: rows[1]["contacts"][0].update(x=85),
                   lambda rows: rows[-1].update(active=1),
                   lambda rows: rows[-1].update(timestamp=12)):
        broken = json.loads(json.dumps(records))
        mutate(broken)
        try:
            check(request, broken)
        except AssertionError:
            continue
        raise AssertionError("self-test accepted a broken trace")
    print("self-test: passed (three contacts, independent lift, movement, stationary contact, cleanup)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("request", nargs="?")
    parser.add_argument("events", nargs="?")
    parser.add_argument("--gesture", action="append", default=[], help="recognizer, optionally with count, e.g. pan:3 or pinch")
    parser.add_argument("--since-sequence", type=int, default=0, help="ignore earlier records in a shared app run")
    parser.add_argument("--position-tolerance", type=float, default=5, help="points")
    parser.add_argument("--time-tolerance", type=float, default=0.15, help="seconds")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.request or not args.events:
        parser.error("request JSON and events.jsonl paths are required")
    with open(args.request) as handle:
        request = json.load(handle)
    with open(args.events) as handle:
        records = [row for line in handle if line.strip()
                   and (row := json.loads(line)).get("sequence", 0) > args.since_sequence]
    print(json.dumps(check(request, records, args.position_tolerance, args.time_tolerance, args.gesture), ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, KeyError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Puts the output of two runs of tests/ingame/perf_r3.lua side by side: c0 (before) and c1 (after).

    python perf_compare.py c0.txt c1.txt [--slower 1.10]

Each file is what `pzdev check perf_r3.lua --follow 900` printed (or a part of Zomboid\\console.txt: the lines are found
by their "[perf] " tag wherever it stands). Prints a Markdown table of the timed paths (mean and p95 per call, c1/c0), one
of the frames (p50, p95, p99, max, frames over 50 ms), and whether the routes and the one-offs found the same things
(their hashes). A path whose c1 mean is more than `--slower` times its c0 mean (1.10 by default) and more than 2 us
over it is marked SLOWER: the frequent paths must not be (E2E.md 10.1). A path one build has not is `n/a`.
"""
import re
import sys

LINE = re.compile(r"\[perf\] (.*)")
PAIR = re.compile(r"(\w+)=([^\s]+)")
HOT = ("cursor.", "objects.", "machines.", "bu.lookup", "bu.lights", "bu.checkObjects", "bu.spawned", "bu.links", "bu.floorlines",
       "alarm.", "dense.look", "towns.enter")


def parse(path):
    """-> (paths, frames, hashes, notes): paths[id] = {mean_us, p95_us, ...} or None for n/a."""
    paths, frames, hashes, notes = {}, {}, {}, []
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            m = LINE.search(raw)
            if not m:
                continue
            text = m.group(1).strip()
            words = text.split()
            if not words:
                continue
            pairs = dict(PAIR.findall(text))
            if words[0] == "frames" and len(words) > 1:
                frames[words[1]] = pairs
            elif "n/a" in words[1:2] or (len(words) > 1 and words[1] == "n/a"):
                paths[words[0]] = None
            elif "mean_us" in pairs:
                paths[words[0]] = pairs
            elif words[0].startswith("bu.route") or words[0] in ("bu.route",):
                key = " ".join(words[:2])
                hashes[key] = (pairs.get("len"), pairs.get("hash"))
            elif words[0].endswith(".result") and "hash" in pairs:
                hashes[words[0]] = (None, pairs["hash"])
            elif words[0] in ("build=c0", "build=c1") or words[0].startswith("build="):
                notes.append(text)
            elif words[0] in ("api", "spot", "alarms", "machines", "bu", "cursor", "dense", "towns", "alarm.scene",
                              "api.first", "heavy.meteor.states"):
                notes.append(text)
    return paths, frames, hashes, notes


def num(pairs, key):
    try:
        return float(pairs[key])
    except (KeyError, TypeError, ValueError):
        return None


def cell(x, places=1):
    return "-" if x is None else ("%." + str(places) + "f") % x


def main():
    args = sys.argv[1:]
    slower = 1.10
    if "--slower" in args:
        i = args.index("--slower")
        slower = float(args[i + 1])
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__)
        return 2
    a_paths, a_frames, a_hashes, a_notes = parse(args[0])
    b_paths, b_frames, b_hashes, b_notes = parse(args[1])

    print("c0 =", args[0])
    for n in a_notes[:6]:
        print("   ", n)
    print("c1 =", args[1])
    for n in b_notes[:6]:
        print("   ", n)
    print()
    print("| path | c0 mean us | c1 mean us | c1/c0 | c0 p95 us | c1 p95 us | c0 calls | c1 calls | |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
    ids = list(dict.fromkeys(list(a_paths) + list(b_paths)))
    slow = 0
    for pid in ids:
        a, b = a_paths.get(pid), b_paths.get(pid)
        if a is None and b is None:
            print("| %s | n/a | n/a | | | | | | |" % pid)
            continue
        am, bm = num(a, "mean_us"), num(b, "mean_us")
        ratio = (bm / am) if am and bm is not None else None
        flag = ""
        if ratio is not None and ratio > slower and bm - am > 2 and pid.startswith(HOT):
            flag = "SLOWER"
            slow += 1
        elif ratio is not None and ratio < 1 / slower:
            flag = "faster"
        print("| %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            pid, cell(am) if a else "n/a", cell(bm) if b else "n/a", cell(ratio, 2), cell(num(a, "p95_us")),
            cell(num(b, "p95_us")), (a or {}).get("calls", "-"), (b or {}).get("calls", "-"), flag))
    print()
    print("| frames | c0 n | c1 n | c0 p50/p95/p99/max ms | c1 p50/p95/p99/max ms | c0 over50 | c1 over50 |")
    print("| --- | ---: | ---: | --- | --- | ---: | ---: |")
    for fid in dict.fromkeys(list(a_frames) + list(b_frames)):
        a, b = a_frames.get(fid), b_frames.get(fid)

        def spread(p):
            return "n/a" if not p else "/".join(p.get(k, "-") for k in ("p50_ms", "p95_ms", "p99_ms", "max_ms"))

        print("| %s | %s | %s | %s | %s | %s | %s |" % (fid, (a or {}).get("n", "-"), (b or {}).get("n", "-"), spread(a),
                                                       spread(b), (a or {}).get("over50", "-"), (b or {}).get("over50", "-")))
    print()
    print("| found the same | c0 | c1 | |")
    print("| --- | --- | --- | --- |")
    for key in dict.fromkeys(list(a_hashes) + list(b_hashes)):
        a, b = a_hashes.get(key), b_hashes.get(key)
        same = "same" if a == b and a is not None else "DIFFERENT"
        print("| %s | %s | %s | %s |" % (key, "/".join(x or "-" for x in a) if a else "n/a", "/".join(x or "-" for x in b) if b else "n/a", same))
    print()
    print("%d frequent path(s) marked SLOWER (c1 mean over %.2f x c0)." % (slow, slower))
    return 1 if slow else 0


if __name__ == "__main__":
    sys.exit(main())

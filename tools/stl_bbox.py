#!/usr/bin/env python3
"""Report an STL's bounding box, and optionally assert it is the expected size.

    stl_bbox.py model.stl
    stl_bbox.py model.stl --expect-x 120 --expect-z 7 --tol 0.05

`make check` uses the assertion form. The SVG-import path is the one part of this
pipeline that could silently produce a correct-looking model at the wrong scale,
so the finished solid gets measured rather than trusted.
"""

import argparse
import struct
import sys


def bbox_binary(data):
    if len(data) < 84:
        return None
    count = struct.unpack("<I", data[80:84])[0]
    if len(data) < 84 + count * 50:
        return None
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    off = 84
    for _ in range(count):
        vals = struct.unpack_from("<12f", data, off)
        for v in range(3):
            for a in range(3):
                c = vals[3 + v * 3 + a]
                lo[a] = min(lo[a], c)
                hi[a] = max(hi[a], c)
        off += 50
    return lo, hi, count


def bbox_ascii(text):
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    facets = 0
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("facet "):
            facets += 1
        elif line.startswith("vertex "):
            parts = line.split()
            for a in range(3):
                c = float(parts[1 + a])
                lo[a] = min(lo[a], c)
                hi[a] = max(hi[a], c)
    return lo, hi, facets


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stl")
    ap.add_argument("--expect-x", type=float)
    ap.add_argument("--expect-y", type=float)
    ap.add_argument("--expect-z", type=float)
    ap.add_argument("--tol", type=float, default=0.05, help="allowed error in mm")
    args = ap.parse_args()

    data = open(args.stl, "rb").read()
    result = None
    if not data.lstrip()[:5].lower().startswith(b"solid"):
        result = bbox_binary(data)
    if result is None:
        try:
            result = bbox_ascii(data.decode("utf-8", "replace"))
        except UnicodeError:
            result = bbox_binary(data)
    if result is None:
        sys.exit("stl_bbox.py: could not parse %s as an STL" % args.stl)

    lo, hi, facets = result
    if facets == 0 or lo[0] == float("inf"):
        sys.exit("stl_bbox.py: %s contains no geometry" % args.stl)

    size = [hi[i] - lo[i] for i in range(3)]
    axes = "xyz"
    print("%s: %d facets" % (args.stl, facets))
    for i in range(3):
        print("  %s  %9.3f .. %9.3f   size %8.3f mm" % (axes[i], lo[i], hi[i], size[i]))

    failures = []
    for i, want in enumerate((args.expect_x, args.expect_y, args.expect_z)):
        if want is None:
            continue
        got = size[i]
        if abs(got - want) > args.tol:
            failures.append(
                "%s is %.3f mm, expected %.3f mm (off by %.3f, tolerance %.3f)"
                % (axes[i], got, want, got - want, args.tol)
            )
    if failures:
        for f in failures:
            print("FAIL: " + f, file=sys.stderr)
        sys.exit(1)
    print("OK: dimensions within %.3f mm of target" % args.tol)


if __name__ == "__main__":
    main()

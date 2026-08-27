#!/usr/bin/env python3
"""Measure traced layers and emit the generated OpenSCAD size config.

    svg_bbox.py --out build/config.scad a.svg b.svg ...

The bounding box is the union across every SVG given, computed in the exact
coordinate space that OpenSCAD's `import(..., dpi=25.4)` produces. That union is
what lets pigpen.scad turn a human-facing "make it 120 mm wide" into a scale
factor, while keeping both layers on one shared frame so they stay registered.

Curves are measured properly (the extrema of each cubic are solved for, not just
the control points), so the reported box is the real silhouette, not an
over-estimate of it.
"""

import argparse
import math
import re
import sys
import xml.etree.ElementTree as ET

SVG_NS = "{http://www.w3.org/2000/svg}"
TOKEN = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?|[A-Za-z]")


def parse_length(text):
    """SVG length -> float, dropping any unit suffix."""
    m = re.match(r"\s*([-+]?[\d.eE+-]+)\s*([a-z%]*)\s*$", text or "")
    if not m:
        raise ValueError("cannot parse length %r" % text)
    return float(m.group(1))


def cubic_extrema(p0, p1, p2, p3):
    """Parameter values in (0,1) where a cubic bezier's derivative vanishes."""
    a = -p0 + 3 * p1 - 3 * p2 + p3
    b = 2 * (p0 - 2 * p1 + p2)
    c = p1 - p0
    ts = []
    if abs(a) < 1e-12:
        if abs(b) > 1e-12:
            ts.append(-c / b)
    else:
        disc = b * b - 4 * a * c
        if disc >= 0:
            root = math.sqrt(disc)
            ts.extend(((-b + root) / (2 * a), (-b - root) / (2 * a)))
    return [t for t in ts if 0.0 < t < 1.0]


def cubic_at(p0, p1, p2, p3, t):
    u = 1 - t
    return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3


class Box:
    def __init__(self):
        self.x0 = self.y0 = float("inf")
        self.x1 = self.y1 = float("-inf")

    def add(self, x, y):
        self.x0 = min(self.x0, x)
        self.y0 = min(self.y0, y)
        self.x1 = max(self.x1, x)
        self.y1 = max(self.y1, y)

    @property
    def empty(self):
        return self.x0 > self.x1


def walk_path(d, box, emit):
    """Feed every extreme point of path data `d` to box via the emit mapping."""
    tokens = TOKEN.findall(d)
    i = 0
    cmd = None
    cx = cy = 0.0
    sx = sy = 0.0

    def num():
        nonlocal i
        val = float(tokens[i])
        i += 1
        return val

    def point(rel):
        x, y = num(), num()
        return (cx + x, cy + y) if rel else (x, y)

    while i < len(tokens):
        if tokens[i].isalpha():
            cmd = tokens[i]
            i += 1
            if cmd in "Zz":
                cx, cy = sx, sy
                continue
        if cmd is None:
            raise ValueError("path data starts without a command: %r" % d[:40])

        low = cmd.lower()
        rel = cmd.islower()
        if low == "m":
            cx, cy = point(rel)
            sx, sy = cx, cy
            box.add(*emit(cx, cy))
            # A repeated coordinate pair after moveto is an implicit lineto.
            cmd = "l" if rel else "L"
        elif low == "l":
            cx, cy = point(rel)
            box.add(*emit(cx, cy))
        elif low == "h":
            x = num()
            cx = cx + x if rel else x
            box.add(*emit(cx, cy))
        elif low == "v":
            y = num()
            cy = cy + y if rel else y
            box.add(*emit(cx, cy))
        elif low == "c":
            x0, y0 = cx, cy
            x1, y1 = point(rel)
            x2, y2 = point(rel)
            x3, y3 = point(rel)
            box.add(*emit(x3, y3))
            for axis, (a, b, c, dd) in enumerate(
                ((x0, x1, x2, x3), (y0, y1, y2, y3))
            ):
                for t in cubic_extrema(a, b, c, dd):
                    px = cubic_at(x0, x1, x2, x3, t)
                    py = cubic_at(y0, y1, y2, y3, t)
                    box.add(*emit(px, py))
            cx, cy = x3, y3
        else:
            raise ValueError("unsupported path command %r (potrace should not emit it)" % cmd)


def measure(path, box):
    tree = ET.parse(path)
    root = tree.getroot()

    vb = root.get("viewBox")
    if not vb:
        raise ValueError("%s has no viewBox" % path)
    vx, vy, vw, vh = (float(v) for v in re.split(r"[\s,]+", vb.strip()))
    width = parse_length(root.get("width"))
    height = parse_length(root.get("height"))
    kx, ky = width / vw, height / vh

    for g in root.iter(SVG_NS + "g"):
        tx = ty = 0.0
        gx = gy = 1.0
        transform = g.get("transform", "")
        m = re.search(r"translate\(\s*([-\d.eE+]+)[\s,]+([-\d.eE+]+)\s*\)", transform)
        if m:
            tx, ty = float(m.group(1)), float(m.group(2))
        m = re.search(r"scale\(\s*([-\d.eE+]+)[\s,]+([-\d.eE+]+)\s*\)", transform)
        if m:
            gx, gy = float(m.group(1)), float(m.group(2))

        def emit(px, py, tx=tx, ty=ty, gx=gx, gy=gy):
            # group transform -> SVG user units
            ux, uy = tx + gx * px, ty + gy * py
            # viewBox -> viewport
            vxp, vyp = (ux - vx) * kx, (uy - vy) * ky
            # OpenSCAD flips SVG's y-down axis on import
            return vxp, height - vyp

        for elem in g.iter(SVG_NS + "path"):
            d = elem.get("d")
            if d:
                walk_path(d, box, emit)

    return width, height


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="OpenSCAD config file to write")
    ap.add_argument("svgs", nargs="+")
    args = ap.parse_args()

    box = Box()
    canvas_w = canvas_h = None
    for svg in args.svgs:
        w, h = measure(svg, box)
        if canvas_w is None:
            canvas_w, canvas_h = w, h
        elif (round(w, 6), round(h, 6)) != (round(canvas_w, 6), round(canvas_h, 6)):
            sys.exit(
                "svg_bbox.py: %s is %gx%g but %s is %gx%g - layers must share one "
                "canvas or they will not stay registered"
                % (svg, w, h, args.svgs[0], canvas_w, canvas_h)
            )

    if box.empty:
        sys.exit("svg_bbox.py: no geometry found in %s" % ", ".join(args.svgs))

    lines = [
        "// GENERATED by tools/svg_bbox.py - do not edit, `make` rewrites it.",
        "// Measured from: %s" % ", ".join(args.svgs),
        "// Units are source pixels, which import(dpi=25.4) turns into millimetres.",
        "",
        "CANVAS_W_PX = %.6f;" % canvas_w,
        "CANVAS_H_PX = %.6f;" % canvas_h,
        "",
        "ART_X0 = %.6f;" % box.x0,
        "ART_Y0 = %.6f;" % box.y0,
        "ART_X1 = %.6f;" % box.x1,
        "ART_Y1 = %.6f;" % box.y1,
        "ART_W  = %.6f;" % (box.x1 - box.x0),
        "ART_H  = %.6f;" % (box.y1 - box.y0),
        "ART_CX = %.6f;" % ((box.x0 + box.x1) / 2.0),
        "ART_CY = %.6f;" % ((box.y0 + box.y1) / 2.0),
        "",
    ]
    with open(args.out, "w") as fh:
        fh.write("\n".join(lines))

    sys.stderr.write(
        "artwork %.2f x %.2f px at (%.2f, %.2f)-(%.2f, %.2f)\n"
        % (box.x1 - box.x0, box.y1 - box.y0, box.x0, box.y0, box.x1, box.y1)
    )


if __name__ == "__main__":
    main()

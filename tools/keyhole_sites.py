#!/usr/bin/env python3
"""Pick and verify keyhole positions against the plaque silhouette.

    keyhole_sites.py --mask build/layers/base-silhouette.pgm \
        --out build/keyholes.scad --config build/config.scad \
        --width-mm 120 --head-d 8 --shank-d 4.2 --slot-len 9 --wall 1.5

The plaque is an irregular blob, so a keyhole placed by eye can easily end up
close enough to an edge that the screw head breaks out through the side. This
computes the exact distance from every interior point to the nearest edge, then
picks the widest symmetric pair of sites that keeps the required material around
the whole keyhole footprint - and fails the build if no such pair exists.

Positions are emitted in artwork pixel units, the same space ART_CX/ART_CY are
in, so they scale with WIDTH_MM exactly like the traced outlines do.
"""

import argparse
import math
import re
import sys

INF = float("inf")


def read_pgm(path):
    """Minimal binary PGM (P5) reader. Returns (width, height, bytes)."""
    with open(path, "rb") as fh:
        data = fh.read()

    fields = []
    pos = 0
    while len(fields) < 4:
        while pos < len(data) and data[pos : pos + 1].isspace():
            pos += 1
        if data[pos : pos + 1] == b"#":
            while pos < len(data) and data[pos] != 0x0A:
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos : pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    pos += 1  # single whitespace byte after maxval

    if fields[0] != b"P5":
        sys.exit("keyhole_sites.py: %s is not a binary PGM (P5)" % path)
    w, h, maxval = int(fields[1]), int(fields[2]), int(fields[3])
    if maxval > 255:
        sys.exit("keyhole_sites.py: 16-bit PGM not supported")
    pixels = data[pos : pos + w * h]
    if len(pixels) != w * h:
        sys.exit("keyhole_sites.py: %s is truncated" % path)
    return w, h, pixels


def edt_1d(f):
    """Squared 1-D distance transform (Felzenszwalb & Huttenlocher)."""
    n = len(f)
    d = [0.0] * n
    v = [0] * n
    z = [0.0] * (n + 1)
    k = 0
    v[0] = 0
    z[0] = -INF
    z[1] = INF
    for q in range(1, n):
        while True:
            p = v[k]
            s = ((f[q] + q * q) - (f[p] + p * p)) / (2.0 * q - 2.0 * p)
            if s > z[k]:
                break
            k -= 1
        k += 1
        v[k] = q
        z[k] = s
        z[k + 1] = INF
    k = 0
    for q in range(n):
        while z[k + 1] < q:
            k += 1
        d[q] = (q - v[k]) * (q - v[k]) + f[v[k]]
    return d


def distance_to_edge(w, h, solid):
    """Euclidean distance from each solid pixel to the nearest non-solid pixel.

    Anything outside the image counts as non-solid, so a shape running off the
    canvas does not read as infinitely thick.
    """
    # Column pass.
    grid = [[0.0] * w for _ in range(h)]
    for x in range(w):
        col = [0.0 if not solid[y * w + x] else INF for y in range(h)]
        out = edt_1d(col)
        for y in range(h):
            grid[y][x] = out[y]
    # Row pass.
    for y in range(h):
        out = edt_1d(grid[y])
        row = grid[y]
        for x in range(w):
            row[x] = math.sqrt(out[x])
    return grid


def keyhole_area(head_r, shank_r, slot_len, steps=200000):
    """Area of the keyhole outline: disk, slot and end cap unioned.

    Integrated numerically over y rather than solved in closed form, because the
    three pieces overlap differently depending on how the sizes relate and the
    closed form has to case-split on all of them. Every piece is symmetric about
    x = 0, so the union's width at any y is just the widest piece there.
    """
    y0, y1 = -head_r, slot_len + shank_r
    dy = (y1 - y0) / steps
    total = 0.0
    for i in range(steps):
        y = y0 + (i + 0.5) * dy
        half = 0.0
        if abs(y) <= head_r:
            half = max(half, math.sqrt(head_r * head_r - y * y))
        if 0.0 <= y <= slot_len:
            half = max(half, shank_r)
        if abs(y - slot_len) <= shank_r:
            half = max(half, math.sqrt(shank_r * shank_r - (y - slot_len) ** 2))
        total += 2.0 * half * dy
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mask", required=True, help="binary PGM of the silhouette")
    ap.add_argument("--config", required=True, help="generated build/config.scad")
    ap.add_argument("--out", required=True)
    ap.add_argument("--width-mm", type=float, required=True)
    ap.add_argument("--head-d", type=float, required=True)
    ap.add_argument("--shank-d", type=float, required=True)
    ap.add_argument("--slot-len", type=float, required=True)
    ap.add_argument("--wall", type=float, required=True,
                    help="material to keep between the keyhole and the edge, mm")
    ap.add_argument("--drop", type=float, default=0.30,
                    help="where to sit the sites, as a fraction of artwork "
                         "height below the top edge")
    ap.add_argument("--downsample", type=int, default=4)
    ap.add_argument("--draw", help="write MVG draw primitives here, for the "
                                   "placement map preview")
    args = ap.parse_args()

    cfg = {}
    for m in re.finditer(r"^\s*(\w+)\s*=\s*([-\d.eE+]+)\s*;", open(args.config).read(), re.M):
        cfg[m.group(1)] = float(m.group(2))
    for key in ("ART_W", "ART_X0", "ART_X1", "ART_Y0", "ART_Y1", "CANVAS_H_PX"):
        if key not in cfg:
            sys.exit("keyhole_sites.py: %s has no %s - run `make config`" % (args.config, key))

    w, h, pixels = read_pgm(args.mask)
    ds = args.downsample
    solid = [p > 127 for p in pixels]
    grid = distance_to_edge(w, h, solid)

    # The mask is downsampled, so convert everything into full-resolution
    # artwork pixels, which is the space config.scad and pigpen.scad share.
    px_per_mm = cfg["ART_W"] / args.width_mm
    need_head = (args.head_d / 2.0 + args.wall) * px_per_mm
    need_shank = (args.shank_d / 2.0 + args.wall) * px_per_mm
    slot_px = args.slot_len * px_per_mm

    def clearance(x_px, y_units):
        """Distance to the nearest edge, in full-res pixels, or 0 if outside."""
        col = int(round(x_px / ds))
        row = int(round((cfg["CANVAS_H_PX"] - y_units) / ds))
        if not (0 <= col < w and 0 <= row < h):
            return 0.0
        return grid[row][col] * ds

    def footprint_ok(x_px, y_units):
        """Head circle plus the whole slot must keep their material."""
        if clearance(x_px, y_units) < need_head:
            return False
        steps = max(2, int(slot_px / (2 * ds)) + 1)
        for i in range(1, steps + 1):
            y = y_units + slot_px * i / steps
            if clearance(x_px, y) < need_shank:
                return False
        return True

    centre_x = (cfg["ART_X0"] + cfg["ART_X1"]) / 2.0
    art_h = cfg["ART_Y1"] - cfg["ART_Y0"]

    # Search outward from the requested height for the widest symmetric pair.
    # Sliding down the plaque is acceptable; a lopsided pair is not, because the
    # plaque would hang crooked.
    best = None
    for dy in range(0, int(art_h / 2)):
        for sign in ((1, -1) if dy else (1,)):
            y = cfg["ART_Y1"] - args.drop * art_h + sign * dy
            if not (cfg["ART_Y0"] < y < cfg["ART_Y1"]):
                continue
            half = None
            step = max(1.0, ds / 2.0)
            offset = (cfg["ART_X1"] - cfg["ART_X0"]) / 2.0
            while offset > 0:
                if footprint_ok(centre_x - offset, y) and footprint_ok(centre_x + offset, y):
                    half = offset
                    break
                offset -= step
            if half is not None and half > need_head:
                best = (y, half)
                break
        if best:
            break

    if best is None:
        sys.exit(
            "keyhole_sites.py: no keyhole position keeps %.2f mm of material "
            "around a %.1f mm head. Make the plaque bigger (WIDTH_MM), the "
            "screw smaller (KEYHOLE_HEAD_D), or the wall thinner (KEYHOLE_WALL)."
            % (args.wall, args.head_d)
        )

    y, half = best
    sites = [(centre_x - half, y), (centre_x + half, y)]
    clearances = [clearance(x, yy) / px_per_mm for x, yy in sites]

    lines = [
        "// GENERATED by tools/keyhole_sites.py - do not edit, `make` rewrites it.",
        "// Positions are artwork pixel units, the same space as ART_CX/ART_CY,",
        "// so they scale with WIDTH_MM exactly like the traced outlines.",
        "// Verified for a %.1f mm head with %.2f mm of material kept around it."
        % (args.head_d, args.wall),
        "",
        "KEYHOLE_SITES = [",
    ]
    for x, yy in sites:
        lines.append("    [%.4f, %.4f]," % (x, yy))
    lines.append("];")
    lines.append("")
    lines.append("// Actual edge clearance achieved at each site, in mm.")
    lines.append("KEYHOLE_CLEARANCE_MM = [%s];"
                 % ", ".join("%.3f" % c for c in clearances))
    lines.append("")
    lines.append("// Cross-sectional area of one keyhole outline. `make check`")
    lines.append("// multiplies this by the pocket depth to confirm the solid")
    lines.append("// really lost the material the keyholes should have removed.")
    lines.append("KEYHOLE_AREA_MM2 = %.6f;" % keyhole_area(
        args.head_d / 2.0, args.shank_d / 2.0, args.slot_len))
    lines.append("KEYHOLE_COUNT = %d;" % len(sites))
    lines.append("")
    open(args.out, "w").write("\n".join(lines))

    if args.draw:
        # ImageMagick draws in image coordinates: y down from the top.
        cmds = []
        for x, yy in sites:
            row = cfg["CANVAS_H_PX"] - yy
            top = row - slot_px
            cmds.append("circle %.1f,%.1f %.1f,%.1f"
                        % (x, row, x + args.head_d / 2.0 * px_per_mm, row))
            cmds.append("rectangle %.1f,%.1f %.1f,%.1f"
                        % (x - args.shank_d / 2.0 * px_per_mm, top,
                           x + args.shank_d / 2.0 * px_per_mm, row))
            cmds.append("circle %.1f,%.1f %.1f,%.1f"
                        % (x, top, x + args.shank_d / 2.0 * px_per_mm, top))
        # Plain MVG primitives, one per line, for `magick -draw @file`. Passing
        # them as shell arguments instead would lose the quoting that keeps each
        # primitive a single argument.
        open(args.draw, "w").write("\n".join(cmds) + "\n")

    spacing = 2 * half / px_per_mm
    sys.stderr.write(
        "keyholes: 2 sites %.1f mm apart, %.1f mm below the top edge; "
        "edge clearance %.2f / %.2f mm (need %.2f)\n"
        % (spacing, (cfg["ART_Y1"] - y) / px_per_mm,
           clearances[0], clearances[1], args.head_d / 2 + args.wall)
    )


if __name__ == "__main__":
    main()

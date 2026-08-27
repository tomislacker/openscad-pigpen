#!/usr/bin/env bash
#
# Trace one exported layer PNG into an SVG that OpenSCAD can import.
#
#   trace_layer.sh <in.png> <out.svg>
#
# The layer's *alpha* channel is the shape, not its colour: the exported layers
# are flat colour on transparency, so luminance would trace the wrong thing (and
# would trace nothing at all for a layer that happens to be near-white).
#
# Tunables come from the environment so the Makefile owns the defaults:
#   TRACE_SCALE      integer upsample before tracing; smooths the stair-stepping
#                    that a 1:1 trace of an anti-aliased edge leaves behind
#   TRACE_THRESHOLD  alpha cutoff, in percent, for "this pixel is ink"
#   TRACE_TURDSIZE   drop traced specks smaller than this many pixels
#   TRACE_ALPHAMAX   potrace corner threshold; 0 = all corners, 1.33 = all smooth
#   TRACE_OPTTOLERANCE  potrace curve-fitting tolerance
#
# The output SVG keeps the full canvas as its viewBox, so every layer shares one
# coordinate frame and the extruded layers land on top of each other.

set -euo pipefail

in=${1:?usage: trace_layer.sh <in.png> <out.svg>}
out=${2:?usage: trace_layer.sh <in.png> <out.svg>}

TRACE_SCALE=${TRACE_SCALE:-2}
TRACE_THRESHOLD=${TRACE_THRESHOLD:-50}
TRACE_TURDSIZE=${TRACE_TURDSIZE:-2}
TRACE_ALPHAMAX=${TRACE_ALPHAMAX:-1.0}
TRACE_OPTTOLERANCE=${TRACE_OPTTOLERANCE:-0.2}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pbm="$tmp/layer.pbm"
raw="$tmp/layer.svg"

# Alpha -> 1-bit mask. potrace treats black as ink, and `-alpha extract` makes
# opaque pixels white, hence the negate.
magick "$in" \
    -alpha extract \
    -filter Lanczos -resize "$((TRACE_SCALE * 100))%" \
    -threshold "${TRACE_THRESHOLD}%" \
    -negate \
    -depth 1 \
    "$pbm"

if ! magick identify -format '%[fx:mean]' "$pbm" | awk '{ exit ($1 < 1.0) ? 0 : 1 }'; then
    echo "trace_layer.sh: $in is fully transparent - nothing to trace" >&2
    exit 1
fi

potrace --svg \
    --turdsize "$TRACE_TURDSIZE" \
    --alphamax "$TRACE_ALPHAMAX" \
    --opttolerance "$TRACE_OPTTOLERANCE" \
    -o "$raw" "$pbm"

# potrace labels the document in points and at the upsampled pixel count. Rewrite
# the header back to plain, unitless user units at the *original* canvas size so
# that OpenSCAD's `import(..., dpi=25.4)` gives exactly 1 source pixel = 1 mm,
# independent of TRACE_SCALE. Only the header changes; the paths keep their
# upsampled coordinates and are mapped down by the viewBox.
python3 - "$raw" "$out" "$TRACE_SCALE" <<'PY'
import re
import sys

raw, out, scale = sys.argv[1], sys.argv[2], int(sys.argv[3])
svg = open(raw).read()

m = re.search(r'<svg\b[^>]*>', svg)
if not m:
    sys.exit("trace_layer.sh: potrace produced no <svg> element")
tag = m.group(0)

vb = re.search(r'viewBox="([\d.eE+-]+)\s+([\d.eE+-]+)\s+([\d.eE+-]+)\s+([\d.eE+-]+)"', tag)
if not vb:
    sys.exit("trace_layer.sh: potrace <svg> has no viewBox")
vx, vy, vw, vh = (float(g) for g in vb.groups())

tag = re.sub(r'\swidth="[^"]*"', ' width="%g"' % (vw / scale), tag, count=1)
tag = re.sub(r'\sheight="[^"]*"', ' height="%g"' % (vh / scale), tag, count=1)
open(out, "w").write(svg[:m.start()] + tag + svg[m.end():])
PY

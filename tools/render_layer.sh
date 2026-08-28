#!/usr/bin/env bash
#
# Render one group of the source SVG to a full-canvas PNG with alpha.
#
#   render_layer.sh <in.svg> <group-id> <out.png>
#
# The wordmark is set in Strato, which is not installed system-wide. Inkscape
# resolves fonts through fontconfig, so this builds a throwaway fontconfig that
# adds the repo's own font directory on top of the system configuration. Without
# it Inkscape silently falls back to a default sans and the wordmark comes out in
# the wrong typeface - which is exactly how the .xcf ended up with Noto Sans
# baked into it.
#
# Tunables:
#   RENDER_W / RENDER_H  output pixel size; every layer must share one canvas
#   FONT_DIR             directory holding the .ttf
#
# --export-area-page keeps the full canvas rather than cropping to the group, so
# all layers come out on the same pixel grid and stay registered downstream.

set -euo pipefail

svg=${1:?usage: render_layer.sh <in.svg> <group-id> <out.png>}
group=${2:?usage: render_layer.sh <in.svg> <group-id> <out.png>}
out=${3:?usage: render_layer.sh <in.svg> <group-id> <out.png>}

RENDER_W=${RENDER_W:-3600}
RENDER_H=${RENDER_H:-1800}
FONT_DIR=${FONT_DIR:-$PWD}

if ! grep -q "id=\"$group\"" "$svg"; then
    echo "render_layer.sh: $svg has no element with id=\"$group\". Groups present:" >&2
    grep -o 'id="[^"]*"' "$svg" | sort -u | sed 's/^/  /' >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/cache"
cat > "$tmp/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
  <dir>$(cd "$FONT_DIR" && pwd)</dir>
  <cachedir>$tmp/cache</cachedir>
</fontconfig>
EOF

export FONTCONFIG_FILE="$tmp/fonts.conf"

mkdir -p "$(dirname "$out")"
inkscape \
    --export-type=png \
    --export-filename="$out" \
    --export-id="$group" \
    --export-id-only \
    --export-area-page \
    --export-background-opacity=0 \
    -w "$RENDER_W" -h "$RENDER_H" \
    "$svg" >/dev/null 2>&1

if [ ! -s "$out" ]; then
    echo "render_layer.sh: inkscape produced no output for group '$group'" >&2
    exit 1
fi

# A group that rendered to nothing means the id matched something invisible;
# tracing an empty mask later would fail with a much less obvious message.
if magick identify -format '%[fx:mean.a]' "$out" | awk '{ exit ($1 > 0) ? 0 : 1 }'; then
    :
else
    echo "render_layer.sh: group '$group' rendered fully transparent" >&2
    exit 1
fi

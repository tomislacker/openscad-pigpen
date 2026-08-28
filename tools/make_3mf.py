#!/usr/bin/env python3
"""Pack the per-colour STLs into a multi-material 3MF for PrusaSlicer.

    make_3mf.py --out dist/pigpen.3mf --name Pigpen \
        --part dist/stl/pigpen-dark.stl:Base:1 \
        --part dist/stl/pigpen-light.stl:Accent:2

Each --part is <stl>:<name>:<extruder>.

The parts become *volumes of a single object*, not separate objects. That
distinction is the whole point: PrusaSlicer treats volumes as rigidly bound, so
the accent cannot be dragged out of alignment with the base, and loading the file
needs no manual positioning. Two top-level objects would each be independently
placeable, and PrusaSlicer re-centres objects on load, so their shared coordinate
frame would not survive.

A 3MF is a zip of XML. The mesh goes in 3D/3dmodel.model as one object with one
merged triangle list; Metadata/Slic3r_PE_model.config then carves that list back
into volumes by triangle index and hangs the extruder assignment off each one.
That config part is a PrusaSlicer extension rather than core 3MF, which is why
the layout here mirrors what PrusaSlicer itself writes.
"""

import argparse
import os
import struct
import sys
import zipfile

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
 <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
 <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
</Types>
"""

RELS = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>
"""


def read_stl(path):
    """Return a list of triangles, each a tuple of three (x, y, z) tuples."""
    with open(path, "rb") as fh:
        data = fh.read()

    if data.lstrip()[:5].lower() == b"solid" and b"facet" in data[:2048]:
        tris = []
        current = []
        for line in data.decode("utf-8", "replace").splitlines():
            line = line.strip()
            if line.startswith("vertex "):
                parts = line.split()
                current.append(tuple(float(parts[i + 1]) for i in range(3)))
                if len(current) == 3:
                    tris.append(tuple(current))
                    current = []
        return tris

    if len(data) < 84:
        sys.exit("make_3mf.py: %s is too short to be an STL" % path)
    count = struct.unpack("<I", data[80:84])[0]
    if len(data) < 84 + count * 50:
        sys.exit("make_3mf.py: %s is truncated" % path)
    tris = []
    off = 84
    for _ in range(count):
        v = struct.unpack_from("<12f", data, off)
        tris.append((v[3:6], v[6:9], v[9:12]))
        off += 50
    return tris


def fmt(value):
    """9 significant digits round-trips a float32 exactly.

    Formatting matters for more than file size: vertices are welded by comparing
    these strings, so two coordinates that were equal in the STL have to render
    identically here or the mesh comes out unwelded and non-manifold.
    """
    text = "%.9g" % value
    return "0" if text in ("-0", "-0.0") else text


def build_mesh(parts):
    """Weld all parts into one vertex/triangle list, tracking volume spans."""
    loaded = []
    for stl, name, extruder in parts:
        tris = read_stl(stl)
        if not tris:
            sys.exit("make_3mf.py: %s contains no triangles" % stl)
        loaded.append((tris, name, extruder))

    # 3MF places the origin at the front-left of the build plate and expects
    # geometry in the positive octant. The model comes out of OpenSCAD centred on
    # the origin, so half of it would sit at negative bed coordinates and
    # PrusaSlicer rejects it with "All objects are outside of the print volume".
    # Shift every part by the same amount, which keeps them registered.
    lo = [min(p[a] for tris, _, _ in loaded for tri in tris for p in tri)
          for a in range(3)]

    vertices = []
    index = {}
    triangles = []
    spans = []

    for tris, name, extruder in loaded:
        first = len(triangles)
        for tri in tris:
            tri = tuple(tuple(p[a] - lo[a] for a in range(3)) for p in tri)
            ids = []
            for point in tri:
                key = (fmt(point[0]), fmt(point[1]), fmt(point[2]))
                got = index.get(key)
                if got is None:
                    got = len(vertices)
                    index[key] = got
                    vertices.append(key)
                ids.append(got)
            # A triangle with a repeated vertex has no area; PrusaSlicer counts
            # these as degenerate and "repairs" the mesh on load.
            if len(set(ids)) == 3:
                triangles.append(ids)
        spans.append((name, extruder, first, len(triangles) - 1, len(tris)))

    return vertices, triangles, spans


def write_model(vertices, triangles, name):
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<model unit="millimeter" xml:lang="en-US"'
        ' xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"'
        ' xmlns:slic3rpe="http://schemas.slic3r.org/3mf/2017/06">',
        ' <metadata name="slic3rpe:Version3mf">1</metadata>',
        ' <metadata name="Title">%s</metadata>' % name,
        " <resources>",
        '  <object id="1" type="model">',
        "   <mesh>",
        "    <vertices>",
    ]
    out.extend('     <vertex x="%s" y="%s" z="%s"/>' % v for v in vertices)
    out.append("    </vertices>")
    out.append("    <triangles>")
    out.extend('     <triangle v1="%d" v2="%d" v3="%d"/>' % tuple(t) for t in triangles)
    out.append("    </triangles>")
    out.extend([
        "   </mesh>",
        "  </object>",
        " </resources>",
        " <build>",
        '  <item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0" printable="1"/>',
        " </build>",
        "</model>",
        "",
    ])
    return "\n".join(out)


def write_config(spans, name):
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<config>",
        ' <object id="1" instances_count="1">',
        '  <metadata type="object" key="name" value="%s"/>' % name,
    ]
    for vol_name, extruder, first, last, _ in spans:
        out.extend([
            '  <volume firstid="%d" lastid="%d">' % (first, last),
            '   <metadata type="volume" key="name" value="%s"/>' % vol_name,
            '   <metadata type="volume" key="volume_type" value="ModelPart"/>',
            '   <metadata type="volume" key="extruder" value="%d"/>' % extruder,
            '   <mesh edges_fixed="0" degenerate_facets="0" facets_removed="0"'
            ' facets_reversed="0" backwards_edges="0"/>',
            "  </volume>",
        ])
    out.extend([" </object>", "</config>", ""])
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--name", default="model")
    ap.add_argument("--part", action="append", required=True,
                    metavar="STL:NAME:EXTRUDER",
                    help="repeatable; assigns one STL to one extruder")
    args = ap.parse_args()

    parts = []
    for spec in args.part:
        bits = spec.rsplit(":", 2)
        if len(bits) != 3:
            sys.exit("make_3mf.py: --part wants <stl>:<name>:<extruder>, got %r" % spec)
        stl, vol_name, extruder = bits
        if not os.path.exists(stl):
            sys.exit("make_3mf.py: no such STL: %s" % stl)
        try:
            extruder = int(extruder)
        except ValueError:
            sys.exit("make_3mf.py: extruder must be a number, got %r" % extruder)
        if extruder < 1:
            sys.exit("make_3mf.py: extruders are numbered from 1, got %d" % extruder)
        parts.append((stl, vol_name, extruder))

    vertices, triangles, spans = build_mesh(parts)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    # Fixed timestamp: dist/ is committed, and zip entries otherwise carry the
    # build time and make every rebuild look like a change.
    stamp = (1980, 1, 1, 0, 0, 0)

    def add(zf, path, text):
        info = zipfile.ZipInfo(path, date_time=stamp)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o600 << 16
        zf.writestr(info, text)

    with zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED) as zf:
        add(zf, "[Content_Types].xml", CONTENT_TYPES)
        add(zf, "_rels/.rels", RELS)
        add(zf, "3D/3dmodel.model", write_model(vertices, triangles, args.name))
        add(zf, "Metadata/Slic3r_PE_model.config", write_config(spans, args.name))

    total = sum(s[4] for s in spans)
    sys.stderr.write(
        "%s: %d vertices, %d triangles welded from %d\n"
        % (args.out, len(vertices), len(triangles), total))
    for vol_name, extruder, first, last, count in spans:
        sys.stderr.write("  extruder %d  %-8s triangles %d-%d (%d)\n"
                         % (extruder, vol_name, first, last, count))


if __name__ == "__main__":
    main()

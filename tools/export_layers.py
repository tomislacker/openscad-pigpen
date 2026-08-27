#!/usr/bin/env python3
"""Export every layer of an XCF to its own full-canvas PNG.

Runs inside GIMP 3.x:

    gimp-console -i --quit \
        --batch-interpreter=python-fu-eval \
        -b "$(cat tools/export_layers.py)"

GIMP's python-fu-eval takes the script as a literal string with no argv, so the
parameters arrive through the environment instead.

    XCF_IN      path to the .xcf
    LAYERS_DIR  directory to write <LayerName>.png into
    LAYERS_MANIFEST  file listing the exported layer names, one per line

Every layer is padded out to the full canvas so that all exported PNGs share one
coordinate frame. That shared frame is what keeps the traced layers registered
to each other in the OpenSCAD model; without it each layer would be cropped to
its own ink and the stack would not line up.
"""

import os
import sys
import traceback

from gi.repository import Gimp, Gio


def sanitize(name):
    """Filesystem-safe layer name, kept human readable."""
    keep = [c if (c.isalnum() or c in "-_") else "_" for c in name]
    return "".join(keep).strip("_") or "layer"


def export_png(image, path):
    proc = Gimp.get_pdb().lookup_procedure("file-png-export")
    if proc is None:
        raise RuntimeError("GIMP has no file-png-export procedure")
    cfg = proc.create_config()
    cfg.set_property("run-mode", Gimp.RunMode.NONINTERACTIVE)
    cfg.set_property("image", image)
    cfg.set_property("file", Gio.File.new_for_path(path))
    cfg.set_property("save-transparent", True)
    cfg.set_property("compression", 9)
    result = proc.run(cfg)
    status = result.index(0)
    if status != Gimp.PDBStatusType.SUCCESS:
        raise RuntimeError("file-png-export failed for %s: %s" % (path, status))


def main():
    xcf = os.environ["XCF_IN"]
    outdir = os.environ["LAYERS_DIR"]
    manifest = os.environ["LAYERS_MANIFEST"]

    os.makedirs(outdir, exist_ok=True)
    image = Gimp.file_load(Gimp.RunMode.NONINTERACTIVE, Gio.File.new_for_path(xcf))
    width, height = image.get_width(), image.get_height()

    names = []
    for layer in image.get_layers():
        name = layer.get_name()
        dup = image.duplicate()
        # Keep only the layer being exported, then grow it to the canvas so the
        # PNG's pixel grid is identical for every layer.
        keep = None
        for candidate in dup.get_layers():
            if candidate.get_name() == name and keep is None:
                keep = candidate
            else:
                dup.remove_layer(candidate)
        if keep is None:
            dup.delete()
            raise RuntimeError("layer %r vanished from the duplicated image" % name)
        keep.set_visible(True)
        keep.set_opacity(100.0)
        keep.resize_to_image_size()

        out = os.path.join(outdir, sanitize(name) + ".png")
        export_png(dup, out)
        dup.delete()
        names.append((name, sanitize(name), out))
        sys.stderr.write("exported %s -> %s\n" % (name, out))

    # Drop the loaded original too, or GIMP reports it as "a stray image ... left
    # around by a plug-in" on the way out.
    image.delete()

    # Written last, so its existence means the whole export succeeded. The
    # Makefile keys off that.
    with open(manifest, "w") as fh:
        fh.write("# canvas %d %d\n" % (width, height))
        for name, slug, path in names:
            fh.write("%s\t%s\t%s\n" % (name, slug, path))


# No Gimp.quit() here: it is deprecated in GIMP 3.2, and calling it mid-eval
# makes python-fu-eval report "returned no return values" and echo this entire
# script to the log. The caller passes --quit instead.
try:
    main()
except Exception:
    sys.stderr.write(traceback.format_exc())
    raise

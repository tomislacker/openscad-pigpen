# Pigpen logo: GIMP layers -> traced SVG -> OpenSCAD -> STL / previews.
#
#   pigpen_logo.xcf
#     |  make layers    GIMP exports each layer full-canvas, alpha intact
#     v
#   build/layers/*.png
#     |  make trace     alpha -> 1-bit mask -> potrace -> SVG
#     v
#   build/svg/*.svg
#     |  make config    measure the artwork so WIDTH_MM can mean millimetres
#     v
#   build/config.scad + pigpen.scad
#     |  make stl / make preview
#     v
#   build/stl/*.stl, build/img/*.png
#
# Every knob below can be overridden on the command line, e.g.
#
#   make stl WIDTH_MM=200 DARK_H=4 LIGHT_H=2
#   make preview BASE_MODE=knockout

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

# ---------------------------------------------------------------- inputs ----

XCF         ?= pigpen_logo.xcf
SCAD        ?= pigpen.scad
BUILD       ?= build

# Layer names as they appear in the .xcf. `make layers` prints what it found,
# so if you rename them in GIMP the error will tell you the new names.
DARK_LAYER  ?= DarkPart
LIGHT_LAYER ?= LightPart

# Name for the synthesised merged mask (see the BASE_MODE note below). It is not
# a layer in the .xcf; it is generated into build/layers/ alongside the real ones
# so it flows through the same tracing rule.
BASE_LAYER  := base-silhouette

# ------------------------------------------------------------ model size ----

# Printed width of the artwork in mm; the height follows the aspect ratio.
WIDTH_MM    ?= 120
DARK_H      ?= 3.5
LIGHT_H     ?= 3.5

# silhouette = dark and light merged into a solid base, so the light layer is
# supported (printable). knockout = the dark layer exactly as drawn, holes and
# all, which leaves the light layer floating. See pigpen.scad.
#
# The merge happens on the masks, before tracing, not on the traced outlines in
# OpenSCAD. In the artwork the light details are knocked out of the dark layer,
# so the two traces run along the *same* edge from opposite sides. Unioning
# those two outlines in OpenSCAD leaves slivers and single-point contact between
# contours, and linear_extrude turns that into a mesh CGAL rejects with "The
# given mesh is not closed" - after which it drops the base and silently exports
# only the light layer. ORing the two alpha masks and tracing the result once
# gives a single clean set of contours instead.
BASE_MODE   ?= silhouette

# --------------------------------------------------------- trace settings ----

# Upsample factor applied to the alpha channel before tracing. 1 is plenty here:
# potrace's curve fitting already removes the stair-stepping, and 2 multiplies
# the facet count by ~17 for no visible gain at print scale. Raise it only if
# fine detail looks faceted.
TRACE_SCALE        ?= 1
# Alpha cutoff, in percent, for "this pixel is ink".
TRACE_THRESHOLD    ?= 50
# Discard traced specks smaller than this many pixels.
TRACE_TURDSIZE     ?= 2
# potrace corner threshold: 0 = every corner sharp, 1.33 = everything smoothed.
TRACE_ALPHAMAX     ?= 1.0
# potrace curve-fitting tolerance; larger is smoother and simpler.
TRACE_OPTTOLERANCE ?= 0.2

# ------------------------------------------------------------- previews -----

# Size OpenSCAD renders at. The previews are trimmed afterwards, so the final
# files are smaller than this.
IMG_SIZE    ?= 1600,900
COLORSCHEME ?= Tomorrow Night
# Margin, in pixels, left around the model after trimming.
PREVIEW_MARGIN ?= 40

# OpenSCAD gimbal camera: translate x,y,z then rotate x,y,z then distance.
# Distance is left at 0 because --viewall computes it.
CAM_ISO     ?= 0,0,0,55,0,25,0
CAM_TOP     ?= 0,0,0,0,0,0,0
CAM_FRONT   ?= 0,0,0,90,0,0,0

# ------------------------------------------------------------- programs -----

GIMP        ?= gimp-console
OPENSCAD    ?= openscad
POTRACE     ?= potrace
MAGICK      ?= magick
PYTHON      ?= python3

# ------------------------------------------------------------- derived ------

LAYERS_DIR  := $(BUILD)/layers
SVG_DIR     := $(BUILD)/svg
STL_DIR     := $(BUILD)/stl
IMG_DIR     := $(BUILD)/img

MANIFEST    := $(LAYERS_DIR)/manifest.tsv
CONFIG      := $(BUILD)/config.scad
TRACE_STAMP := $(BUILD)/.trace-flags

DARK_PNG    := $(LAYERS_DIR)/$(DARK_LAYER).png
LIGHT_PNG   := $(LAYERS_DIR)/$(LIGHT_LAYER).png
BASE_PNG    := $(LAYERS_DIR)/$(BASE_LAYER).png
DARK_SVG    := $(SVG_DIR)/$(DARK_LAYER).svg
LIGHT_SVG   := $(SVG_DIR)/$(LIGHT_LAYER).svg
BASE_SVG    := $(SVG_DIR)/$(BASE_LAYER).svg
SVGS        := $(DARK_SVG) $(LIGHT_SVG) $(BASE_SVG)

STL_ALL     := $(STL_DIR)/pigpen.stl
STL_DARK    := $(STL_DIR)/pigpen-dark.stl
STL_LIGHT   := $(STL_DIR)/pigpen-light.stl

PREVIEWS    := $(IMG_DIR)/pigpen-iso.png \
               $(IMG_DIR)/pigpen-top.png \
               $(IMG_DIR)/pigpen-front.png

TOTAL_H     := $(shell awk 'BEGIN { printf "%g", $(DARK_H) + $(LIGHT_H) }')

# Values pushed into OpenSCAD. -D wins over the assignments in the .scad, so the
# file stays usable on its own in the GUI while `make` stays authoritative here.
SCAD_DEFS = \
	-D 'WIDTH_MM=$(WIDTH_MM)' \
	-D 'DARK_H=$(DARK_H)' \
	-D 'LIGHT_H=$(LIGHT_H)' \
	-D 'BASE_MODE="$(BASE_MODE)"' \
	-D 'DARK_SVG="$(DARK_SVG)"' \
	-D 'LIGHT_SVG="$(LIGHT_SVG)"' \
	-D 'BASE_SVG="$(BASE_SVG)"'

# OpenSCAD exits 0 even when CGAL rejects part of the model - it prints
# "ERROR: The given mesh is not closed!", drops that solid, and writes a
# perfectly valid STL of whatever was left. That is a silently wrong result, so
# treat any ERROR: line as a failure rather than trusting the exit status. This
# also filters the per-run cache statistics down to just the useful lines.
define run_openscad
@log=$$(mktemp); \
if ! $(OPENSCAD) $(1) >"$$log" 2>&1; then \
	grep -E '^(ERROR|WARNING|TRACE|ECHO):' "$$log" >&2 || cat "$$log" >&2; \
	rm -f "$$log"; exit 1; \
fi; \
if grep -q '^ERROR:' "$$log"; then \
	echo 'OpenSCAD reported an error but exited 0; refusing the output:' >&2; \
	grep -E '^(ERROR|WARNING|TRACE):' "$$log" >&2; \
	rm -f "$$log"; exit 1; \
fi; \
grep -E '^(ECHO|WARNING):' "$$log" || true; \
rm -f "$$log"
endef

# --viewall fits the model's bounding *sphere*, which on a wide flat plaque
# leaves it filling about half the frame. Crop back to the model afterwards and
# re-add an even margin. The border colour is sampled from the rendered corner
# so this keeps working if COLORSCHEME changes.
define trim_preview
@bg=$$($(MAGICK) '$(1)' -format '%[pixel:p{0,0}]' info:); \
$(MAGICK) '$(1)' -fuzz 2% -trim +repage \
	-bordercolor "$$bg" -border $(PREVIEW_MARGIN) '$(1)'
endef

TRACE_ENV = \
	TRACE_SCALE=$(TRACE_SCALE) \
	TRACE_THRESHOLD=$(TRACE_THRESHOLD) \
	TRACE_TURDSIZE=$(TRACE_TURDSIZE) \
	TRACE_ALPHAMAX=$(TRACE_ALPHAMAX) \
	TRACE_OPTTOLERANCE=$(TRACE_OPTTOLERANCE)

# GIMP 3 needs an explicit batch interpreter, and --quit or it lingers as a
# background process once the script finishes.
GIMP_BATCH = $(GIMP) -i --quit --batch-interpreter=python-fu-eval

# GIMP chatters about plug-ins it cannot load, shader inputs it does not use,
# and a broken pipe as --quit tears the plug-in down. None of it affects the
# export; keep the real messages visible and drop the rest.
GIMP_NOISE = 'surfacemap_x|libcfitsio|gimp_wire_read|gjs.*No such file|gimp_flush\(\).*Broken pipe|Welcome to GIMP|^[[:space:]]*$$'

# ---------------------------------------------------------------- targets ----

.PHONY: all help layers trace config scad stl stl-dark stl-light \
        preview thumbs check layer-sheet gui clean distclean tools FORCE

all: stl preview ## Trace, build every STL, and render the previews

help: ## Show this help
	@echo 'Pigpen logo build. Targets:'
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk -F':.*?## ' '{ printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2 }'
	@echo
	@echo 'Current settings (override on the command line):'
	@echo '  WIDTH_MM=$(WIDTH_MM)  DARK_H=$(DARK_H)  LIGHT_H=$(LIGHT_H)  BASE_MODE=$(BASE_MODE)'
	@echo '  DARK_LAYER=$(DARK_LAYER)  LIGHT_LAYER=$(LIGHT_LAYER)  TRACE_SCALE=$(TRACE_SCALE)'
	@echo
	@echo 'Example:  make stl WIDTH_MM=200 DARK_H=4'

tools: ## Check that every external program is installed
	@missing=0; \
	for t in $(GIMP) $(OPENSCAD) $(POTRACE) $(MAGICK) $(PYTHON); do \
		if command -v "$$t" >/dev/null 2>&1; then \
			printf '  ok      %s\n' "$$t"; \
		else \
			printf '  MISSING %s\n' "$$t"; missing=1; \
		fi; \
	done; \
	exit $$missing

# --- layer export ---

layers: $(MANIFEST) ## Export each .xcf layer to build/layers/<name>.png
	@echo 'Layers in $(XCF):'
	@grep -v '^#' $(MANIFEST) | cut -f1 | sed 's/^/  /'

# GIMP writes several PNGs plus the manifest in one run. The manifest is written
# last, so it is the reliable stamp for "the export completed".
$(MANIFEST): $(XCF) tools/export_layers.py
	@mkdir -p $(LAYERS_DIR)
	@rm -f '$(MANIFEST)'
	@log=$$(mktemp); \
	if XCF_IN='$(abspath $(XCF))' \
	   LAYERS_DIR='$(abspath $(LAYERS_DIR))' \
	   LAYERS_MANIFEST='$(abspath $(MANIFEST))' \
	   $(GIMP_BATCH) -b "$$(cat tools/export_layers.py)" </dev/null >"$$log" 2>&1; then \
		grep -vE $(GIMP_NOISE) "$$log" || true; \
		rm -f "$$log"; \
	else \
		status=$$?; \
		echo 'GIMP layer export failed:' >&2; \
		grep -vE $(GIMP_NOISE) "$$log" >&2 || true; \
		rm -f "$$log"; \
		exit $$status; \
	fi
	@test -s '$(MANIFEST)' || { echo 'GIMP export produced no manifest' >&2; exit 1; }

# The PNGs come out of the rule above. This rule only proves the requested layer
# actually exists, then touches it so make does not re-run the export forever
# (GIMP writes the PNGs before the manifest, leaving them "older" than it).
$(LAYERS_DIR)/%.png: $(MANIFEST)
	@if [ ! -f '$@' ]; then \
		echo "No layer named '$*' in $(XCF). Layers present:" >&2; \
		grep -v '^#' $(MANIFEST) | cut -f1 | sed 's/^/  /' >&2; \
		echo "Set DARK_LAYER=/LIGHT_LAYER= to match, or rename them in GIMP." >&2; \
		exit 1; \
	fi
	@touch '$@'

# The merged base mask. An explicit rule, so it wins over the pattern rule above
# (this one is synthesised, not exported from the .xcf). Compositing with a
# transparent background makes the result's alpha the union of the two inputs'.
$(BASE_PNG): $(DARK_PNG) $(LIGHT_PNG)
	$(MAGICK) '$(DARK_PNG)' '$(LIGHT_PNG)' -background none -flatten '$@'

# --- tracing ---

trace: $(SVGS) ## Trace the layer PNGs into build/svg/<name>.svg

# Re-trace when the trace settings change, not just when the PNGs do. Without
# this, changing TRACE_SCALE for one layer would silently leave the other at the
# old setting and the two would no longer register.
$(TRACE_STAMP): FORCE
	@mkdir -p $(BUILD)
	@echo '$(TRACE_ENV)' | cmp -s - '$@' || echo '$(TRACE_ENV)' > '$@'

$(SVG_DIR)/%.svg: $(LAYERS_DIR)/%.png tools/trace_layer.sh $(TRACE_STAMP)
	@mkdir -p $(SVG_DIR)
	$(TRACE_ENV) tools/trace_layer.sh '$<' '$@'

# --- measurement / generated config ---

scad: config ## Alias for config
config: $(CONFIG) ## Measure the traced artwork into build/config.scad

$(CONFIG): $(SVGS) tools/svg_bbox.py
	@mkdir -p $(BUILD)
	$(PYTHON) tools/svg_bbox.py --out '$@' $(SVGS)

# --- solids ---

stl: $(STL_ALL) $(STL_DARK) $(STL_LIGHT) ## Export combined and per-colour STLs

stl-dark: $(STL_DARK)   ## Export just the dark base
stl-light: $(STL_LIGHT) ## Export just the light top layer

$(STL_DIR)/pigpen.stl: $(SCAD) $(CONFIG) $(SVGS)
	@mkdir -p $(STL_DIR)
	@echo 'openscad -> $@ (PART=all)'
	$(call run_openscad, -o '$@' $(SCAD_DEFS) -D 'PART="all"' '$(SCAD)')

$(STL_DIR)/pigpen-dark.stl: $(SCAD) $(CONFIG) $(SVGS)
	@mkdir -p $(STL_DIR)
	@echo 'openscad -> $@ (PART=dark)'
	$(call run_openscad, -o '$@' $(SCAD_DEFS) -D 'PART="dark"' '$(SCAD)')

$(STL_DIR)/pigpen-light.stl: $(SCAD) $(CONFIG) $(SVGS)
	@mkdir -p $(STL_DIR)
	@echo 'openscad -> $@ (PART=light)'
	$(call run_openscad, -o '$@' $(SCAD_DEFS) -D 'PART="light"' '$(SCAD)')

# --- previews ---

preview: $(PREVIEWS) ## Render iso / top / front thumbnails to build/img
thumbs: preview     ## Alias for preview

# PNG export uses OpenSCAD's preview renderer, which honours color(); the full
# CGAL render (--render) would draw everything in one colour instead.
$(IMG_DIR)/pigpen-iso.png: $(SCAD) $(CONFIG) $(SVGS)
	@mkdir -p $(IMG_DIR)
	@echo 'openscad -> $@'
	$(call run_openscad, -o '$@' $(SCAD_DEFS) -D 'PART="all"' \
		--imgsize=$(IMG_SIZE) --camera=$(CAM_ISO) --viewall --autocenter \
		--projection=p --colorscheme='$(COLORSCHEME)' '$(SCAD)')
	$(call trim_preview,$@)

$(IMG_DIR)/pigpen-top.png: $(SCAD) $(CONFIG) $(SVGS)
	@mkdir -p $(IMG_DIR)
	@echo 'openscad -> $@'
	$(call run_openscad, -o '$@' $(SCAD_DEFS) -D 'PART="all"' \
		--imgsize=$(IMG_SIZE) --camera=$(CAM_TOP) --viewall --autocenter \
		--projection=o --colorscheme='$(COLORSCHEME)' '$(SCAD)')
	$(call trim_preview,$@)

$(IMG_DIR)/pigpen-front.png: $(SCAD) $(CONFIG) $(SVGS)
	@mkdir -p $(IMG_DIR)
	@echo 'openscad -> $@'
	$(call run_openscad, -o '$@' $(SCAD_DEFS) -D 'PART="all"' \
		--imgsize=$(IMG_SIZE) --camera=$(CAM_FRONT) --viewall --autocenter \
		--projection=o --colorscheme='$(COLORSCHEME)' '$(SCAD)')
	$(call trim_preview,$@)

layer-sheet: $(DARK_PNG) $(LIGHT_PNG) ## Contact sheet of the raw layer split
	@mkdir -p $(IMG_DIR)
	$(MAGICK) \
		\( '$(DARK_PNG)'  -background '#492517' -alpha remove -alpha off -resize 900x \) \
		\( '$(LIGHT_PNG)' -background '#a5a5a5' -alpha remove -alpha off -resize 900x \) \
		-append '$(IMG_DIR)/layers.png'
	@echo 'wrote $(IMG_DIR)/layers.png'

# --- verification ---

check: $(STL_ALL) $(STL_DARK) $(STL_LIGHT) ## Measure the STLs against the requested size
	@echo '--- combined (expect $(WIDTH_MM) mm wide, $(TOTAL_H) mm tall) ---'
	$(PYTHON) tools/stl_bbox.py '$(STL_ALL)' \
		--expect-x $(WIDTH_MM) --expect-z $(TOTAL_H)
	@echo '--- dark base (expect $(DARK_H) mm tall) ---'
	$(PYTHON) tools/stl_bbox.py '$(STL_DARK)' --expect-z $(DARK_H)
	@echo '--- light layer (expect $(LIGHT_H) mm tall) ---'
	$(PYTHON) tools/stl_bbox.py '$(STL_LIGHT)' --expect-z $(LIGHT_H)

gui: $(CONFIG) $(SVGS) ## Open the model in the OpenSCAD GUI
	$(OPENSCAD) '$(SCAD)' &

# --- housekeeping ---

clean: ## Remove generated STLs, previews and the measured config
	rm -rf '$(STL_DIR)' '$(IMG_DIR)' '$(CONFIG)'

distclean: ## Remove everything under build/, including the GIMP export
	rm -rf '$(BUILD)'

FORCE:

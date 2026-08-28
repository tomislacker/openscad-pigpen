# Pigpen logo: SVG groups -> traced SVG -> OpenSCAD -> STL / previews.
#
#   pigpen_logo.svg + StratoRegular-2d5o.ttf
#     |  make layers    Inkscape renders each group full-canvas, alpha intact
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
#   dist/stl/*.stl, dist/img/*.png     <- committed, so GitHub can preview them
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

SVG_SRC     ?= pigpen_logo.svg
SCAD        ?= pigpen.scad

# The wordmark is set in Strato, which is not installed system-wide. Inkscape
# finds it through a throwaway fontconfig that tools/render_layer.sh points at
# this directory. Without that it falls back to a default sans - which is how the
# .xcf came to have Noto Sans baked into it rather than the real typeface.
FONT        ?= StratoRegular-2d5o.ttf
FONT_DIR    ?= $(CURDIR)

# Intermediates (throwaway, .gitignored) and finished artefacts (committed).
# The STLs and previews live in dist/ because they are the point of the repo:
# GitHub renders a .stl in its 3-D viewer and the previews go in the README, so
# both have to be in the tree for someone who has not run the toolchain.
BUILD       ?= build
DIST        ?= dist

# Group ids in the source SVG. Rendering a missing one lists the ids that do
# exist, so a rename in the artwork gives a usable error.
DARK_LAYER  ?= base
LIGHT_LAYER ?= details

# Name for the synthesised merged mask (see the BASE_MODE note below). It is not
# a group in the SVG; it is generated into build/layers/ alongside the rendered
# ones so it flows through the same tracing rule.
BASE_LAYER  := base-silhouette

# Canvas the layers are rendered at. Only the ratio to WIDTH_MM matters
# downstream, so this is purely a fidelity knob: at 3600 px the plaque is
# 0.033 mm per pixel at the default size, an order of magnitude finer than a
# 0.4 mm nozzle resolves. Every layer must use the same canvas or they stop
# being registered to each other.
RENDER_W    ?= 3600
RENDER_H    ?= 1800

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

# ImageMagick stamps a tIME chunk into every PNG it writes. dist/ is committed,
# so without this every rebuild reports six modified previews whose pixels are
# byte-for-byte identical.
PNG_REPRODUCIBLE = -strip -define png:exclude-chunk=date,time

# OpenSCAD gimbal camera: translate x,y,z then rotate x,y,z then distance.
# Distance is left at 0 because --viewall computes it. Projection is p
# (perspective) or o (orthographic); the flat-on views read better square-on.
CAM_ISO     ?= 0,0,0,55,0,25,0
PROJ_ISO    ?= p
CAM_TOP     ?= 0,0,0,0,0,0,0
PROJ_TOP    ?= o
CAM_FRONT   ?= 0,0,0,90,0,0,0
PROJ_FRONT  ?= o

# Views rendered for every .scad. Adding one here needs a matching CAM_<NAME>
# and PROJ_<NAME> above; nothing else.
VIEWS       ?= iso top front

# --------------------------------------------------- multi-material 3MF -----

# Which extruder prints which layer, and what the parts are called in the
# slicer's object list. Extruders are numbered from 1.
MODEL_NAME     ?= Pigpen
PART_DARK      ?= Base
PART_LIGHT     ?= Accent
EXTRUDER_DARK  ?= 1
EXTRUDER_LIGHT ?= 2

# --------------------------------------------------------------- exports ----

# binstl is ~5x smaller than OpenSCAD's default ASCII STL for the same mesh,
# which matters because these files are committed. Every slicer and GitHub's
# own viewer read it. Set STL_FORMAT=asciistl if you need a readable file.
STL_FORMAT  ?= binstl

# ------------------------------------------------------------- programs -----

INKSCAPE    ?= inkscape
OPENSCAD    ?= openscad
POTRACE     ?= potrace
MAGICK      ?= magick
PYTHON      ?= python3
# Only used by `make check` to validate the 3MF; not needed to build anything.
PRUSA_SLICER ?= prusa-slicer

# ------------------------------------------------------------- derived ------

LAYERS_DIR  := $(BUILD)/layers
SVG_DIR     := $(BUILD)/svg
STL_DIR     := $(DIST)/stl
IMG_DIR     := $(DIST)/img

CONFIG      := $(BUILD)/config.scad
TRACE_STAMP := $(BUILD)/.trace-flags
RENDER_STAMP := $(BUILD)/.render-flags

LAYER_SHEET   := $(IMG_DIR)/layers.png

DARK_PNG    := $(LAYERS_DIR)/$(DARK_LAYER).png
LIGHT_PNG   := $(LAYERS_DIR)/$(LIGHT_LAYER).png
BASE_PNG    := $(LAYERS_DIR)/$(BASE_LAYER).png
DARK_SVG    := $(SVG_DIR)/$(DARK_LAYER).svg
LIGHT_SVG   := $(SVG_DIR)/$(LIGHT_LAYER).svg
BASE_SVG    := $(SVG_DIR)/$(BASE_LAYER).svg
SVGS        := $(DARK_SVG) $(LIGHT_SVG) $(BASE_SVG)

# Every .scad in the project root is a model to export. build/config.scad is
# excluded by construction - it is generated, lives under build/, and is an
# include rather than a model. Drop a new .scad next to pigpen.scad and it picks
# up an STL and a full set of previews with no edit here; the generic rules at
# the bottom of the file build them.
SCAD_SRCS   := $(sort $(wildcard *.scad))
SCAD_NAMES  := $(basename $(SCAD_SRCS))

MMU_3MF     := $(DIST)/pigpen.3mf
MMU_STAMP   := $(BUILD)/.3mf-flags
MODEL_STAMP := $(BUILD)/.model-flags

STL_ALL     := $(STL_DIR)/pigpen.stl
STL_DARK    := $(STL_DIR)/pigpen-dark.stl
STL_LIGHT   := $(STL_DIR)/pigpen-light.stl

# pigpen.scad also gets the two per-colour cuts; anything else gets the whole
# model only.
STLS        := $(patsubst %,$(STL_DIR)/%.stl,$(SCAD_NAMES)) $(STL_DARK) $(STL_LIGHT)

PREVIEWS    := $(foreach n,$(SCAD_NAMES),\
                 $(foreach v,$(VIEWS),$(IMG_DIR)/$(n)-$(v).png))
PREVIEWS    += $(LAYER_SHEET)

TOTAL_H     := $(shell awk 'BEGIN { printf "%g", $(DARK_H) + $(LIGHT_H) }')

# Values pushed into OpenSCAD. -D wins over the assignments in the .scad, so the
# file stays usable on its own in the GUI while `make` stays authoritative here.
# Everything a model needs before it can be rendered. MODEL_STAMP is what makes
# `make stl WIDTH_MM=200` actually rebuild: none of the -D values below is a file
# make can watch, so without it a second build with different dimensions quietly
# keeps the previous STL, and `make check` then measures the old solid against
# the new expectations.
MODEL_DEPS := $(CONFIG) $(SVGS) $(MODEL_STAMP)

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
	-bordercolor "$$bg" -border $(PREVIEW_MARGIN) $(PNG_REPRODUCIBLE) '$(1)'
endef

# $(call export_stl,<output>,<PART>,<scad>)
define export_stl
@mkdir -p $(dir $(1))
@echo 'openscad -> $(1) (PART=$(2))'
$(call run_openscad, -o '$(1)' --export-format=$(STL_FORMAT) \
	$(SCAD_DEFS) -D 'PART="$(2)"' '$(3)')
endef

# $(call render_view,<output>,<camera>,<projection>,<scad>)
#
# PNG export uses OpenSCAD's preview renderer, which honours color(); the full
# CGAL render (--render) would draw everything in one colour instead.
define render_view
@mkdir -p $(dir $(1))
@echo 'openscad -> $(1)'
$(call run_openscad, -o '$(1)' $(SCAD_DEFS) -D 'PART="all"' \
	--imgsize=$(IMG_SIZE) --camera=$(2) --viewall --autocenter \
	--projection=$(3) --colorscheme='$(COLORSCHEME)' '$(4)')
$(call trim_preview,$(1))
endef

# Views are named in lower case (they end up in filenames); their knobs are
# upper case, like every other setting in this file.
UPPER = $(shell echo '$(1)' | tr '[:lower:]' '[:upper:]')

# Re-render when the canvas size changes, not just when the artwork does.
# Layers rendered at different sizes would silently stop being registered.
RENDER_ENV = RENDER_W=$(RENDER_W) RENDER_H=$(RENDER_H) FONT_DIR='$(FONT_DIR)'

TRACE_ENV = \
	TRACE_SCALE=$(TRACE_SCALE) \
	TRACE_THRESHOLD=$(TRACE_THRESHOLD) \
	TRACE_TURDSIZE=$(TRACE_TURDSIZE) \
	TRACE_ALPHAMAX=$(TRACE_ALPHAMAX) \
	TRACE_OPTTOLERANCE=$(TRACE_OPTTOLERANCE)

# ---------------------------------------------------------------- targets ----

.PHONY: all dist help layers trace config scad stl stl-dark stl-light 3mf \
        check-3mf \
        preview thumbs check layer-sheet gui clean distclean tools FORCE

all: stl 3mf preview ## Trace, build the STLs and 3MF, and render the previews

dist: all ## Alias for all: refresh everything committed under dist/

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
	for t in $(INKSCAPE) $(OPENSCAD) $(POTRACE) $(MAGICK) $(PYTHON); do \
		if command -v "$$t" >/dev/null 2>&1; then \
			printf '  ok      %s\n' "$$t"; \
		else \
			printf '  MISSING %s\n' "$$t"; missing=1; \
		fi; \
	done; \
	exit $$missing

# --- layer export ---

layers: $(DARK_PNG) $(LIGHT_PNG) ## Render each SVG group to build/layers/<id>.png
	@echo 'Rendered from $(SVG_SRC) at $(RENDER_W)x$(RENDER_H):'
	@printf '  %s\n' $(DARK_PNG) $(LIGHT_PNG)

# One rule per group; the stem is the SVG group id. Explicit rules elsewhere
# (the merged mask below) take precedence over this pattern.
$(LAYERS_DIR)/%.png: $(SVG_SRC) $(FONT) tools/render_layer.sh $(RENDER_STAMP)
	@mkdir -p $(LAYERS_DIR)
	$(RENDER_ENV) tools/render_layer.sh '$(SVG_SRC)' '$*' '$@'

# The merged base mask. An explicit rule, so it wins over the pattern rule above
# (this one is synthesised, not rendered from the SVG). Compositing with a
# transparent background makes the result's alpha the union of the two inputs'.
$(BASE_PNG): $(DARK_PNG) $(LIGHT_PNG)
	$(MAGICK) '$(DARK_PNG)' '$(LIGHT_PNG)' -background none -flatten '$@'

# --- tracing ---

trace: $(SVGS) ## Trace the layer PNGs into build/svg/<name>.svg

# Re-trace when the trace settings change, not just when the PNGs do. Without
# this, changing TRACE_SCALE for one layer would silently leave the other at the
# old setting and the two would no longer register.
$(RENDER_STAMP): FORCE
	@mkdir -p $(BUILD)
	@echo '$(RENDER_ENV)' | cmp -s - '$@' || echo '$(RENDER_ENV)' > '$@'

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

stl: $(STLS) ## Export an STL for every .scad, plus the per-colour cuts

stl-dark: $(STL_DARK)   ## Export just the dark base
stl-light: $(STL_LIGHT) ## Export just the light top layer

# One STL per .scad in the project root. New models are picked up by the
# wildcard, so this rule is the only one they need. Anything that imports the
# traced SVGs is covered by the $(CONFIG)/$(SVGS) prerequisites; a standalone
# model just ignores them.
$(STL_DIR)/%.stl: %.scad $(MODEL_DEPS)
	$(call export_stl,$@,all,$<)

# The two-colour cuts of pigpen.scad. Explicit rules, so they win over the
# pattern above (which would otherwise go looking for a pigpen-dark.scad).
$(STL_DARK): $(SCAD) $(MODEL_DEPS)
	$(call export_stl,$@,dark,$(SCAD))

$(STL_LIGHT): $(SCAD) $(MODEL_DEPS)
	$(call export_stl,$@,light,$(SCAD))

# --- multi-material 3MF ---

3mf: $(MMU_3MF) ## Pack the two colours into a multi-material 3MF

# Built from the two per-colour STLs rather than straight from OpenSCAD, which
# can write a 3MF but has no way to say which extruder a solid belongs to.
# Repack when the extruder assignment or the part names change, not just when
# the meshes do; neither of those is a file make can watch.
MMU_ENV = name=$(MODEL_NAME) dark=$(PART_DARK):$(EXTRUDER_DARK) \
	light=$(PART_LIGHT):$(EXTRUDER_LIGHT)

$(MODEL_STAMP): FORCE
	@mkdir -p $(BUILD)
	@echo '$(SCAD_DEFS)' | cmp -s - '$@' || echo '$(SCAD_DEFS)' > '$@'

$(MMU_STAMP): FORCE
	@mkdir -p $(BUILD)
	@echo '$(MMU_ENV)' | cmp -s - '$@' || echo '$(MMU_ENV)' > '$@'

$(MMU_3MF): $(STL_DARK) $(STL_LIGHT) tools/make_3mf.py $(MMU_STAMP)
	@mkdir -p $(dir $@)
	$(PYTHON) tools/make_3mf.py --out '$@' --name '$(MODEL_NAME)' \
		--part '$(STL_DARK):$(PART_DARK):$(EXTRUDER_DARK)' \
		--part '$(STL_LIGHT):$(PART_LIGHT):$(EXTRUDER_LIGHT)'

# --- previews ---

preview: $(PREVIEWS) ## Render iso / top / front views of every .scad
thumbs: preview     ## Alias for preview

# One pattern rule per view, generated from VIEWS so a new view is a two-line
# change up top. dist/img/<model>-<view>.png is built from <model>.scad.
define preview_rule
$$(IMG_DIR)/%-$(1).png: %.scad $$(MODEL_DEPS)
	$$(call render_view,$$@,$$(CAM_$(call UPPER,$(1))),$$(PROJ_$(call UPPER,$(1))),$$<)
endef
$(foreach v,$(VIEWS),$(eval $(call preview_rule,$(v))))

# On white, not on each layer's own colour: the base group renders as a solid
# blob in exactly the dark fill colour, so compositing it over that colour would
# make the sheet two blank rectangles.
layer-sheet: $(LAYER_SHEET) ## Contact sheet of the two rendered layers
$(LAYER_SHEET): $(DARK_PNG) $(LIGHT_PNG)
	@mkdir -p $(IMG_DIR)
	$(MAGICK) \
		\( '$(DARK_PNG)'  -background white -alpha remove -alpha off -resize 900x \) \
		\( '$(LIGHT_PNG)' -background white -alpha remove -alpha off -resize 900x \) \
		-append $(PNG_REPRODUCIBLE) '$@'
	@echo 'wrote $@'

# --- verification ---

check: $(STLS) ## Measure the STLs against the requested size
	@echo '--- combined (expect $(WIDTH_MM) mm wide, $(TOTAL_H) mm tall) ---'
	$(PYTHON) tools/stl_bbox.py '$(STL_ALL)' \
		--expect-x $(WIDTH_MM) --expect-z $(TOTAL_H)
	@echo '--- dark base (expect $(DARK_H) mm tall) ---'
	$(PYTHON) tools/stl_bbox.py '$(STL_DARK)' --expect-z $(DARK_H)
	@echo '--- light layer (expect $(LIGHT_H) mm tall) ---'
	$(PYTHON) tools/stl_bbox.py '$(STL_LIGHT)' --expect-z $(LIGHT_H)
	@$(MAKE) --no-print-directory check-3mf

# PrusaSlicer is not needed to *build* the 3MF, only to confirm it reads back the
# way it should, so this is skipped rather than failed when it is absent. The
# manifold check is the one that matters: welding the two STLs into one indexed
# mesh is where this could silently produce something the slicer has to repair.
check-3mf: $(MMU_3MF)
	@echo '--- 3mf (expect manifold, $(WIDTH_MM) mm wide, $(TOTAL_H) mm tall) ---'
	@if ! command -v $(PRUSA_SLICER) >/dev/null 2>&1; then \
		echo "  skipped: $(PRUSA_SLICER) not installed"; exit 0; \
	fi; \
	info=$$($(PRUSA_SLICER) --info '$(MMU_3MF)' 2>/dev/null); \
	echo "$$info" | grep -E 'size_|manifold|number_of_facets' | sed 's/^/  /'; \
	echo "$$info" | awk -v w='$(WIDTH_MM)' -v h='$(TOTAL_H)' -F' = ' ' \
	  /^manifold/   { if ($$2 != "yes") { print "FAIL: 3mf mesh is not manifold"; bad=1 } } \
	  /^size_x/     { d=$$2-w; if (d<0) d=-d; if (d>0.05) { print "FAIL: 3mf width " $$2; bad=1 } } \
	  /^size_z/     { d=$$2-h; if (d<0) d=-d; if (d>0.05) { print "FAIL: 3mf height " $$2; bad=1 } } \
	  END { if (bad) exit 1; print "OK: 3mf loads clean and measures right" }'
gui: $(MODEL_DEPS) ## Open the model in the OpenSCAD GUI
	$(OPENSCAD) '$(SCAD)' &

# --- housekeeping ---

clean: ## Remove the generated artefacts in dist/ and the measured config
	rm -rf '$(DIST)' '$(CONFIG)'

distclean: clean ## Also remove everything under build/, including the rendered layers
	rm -rf '$(BUILD)'

FORCE:

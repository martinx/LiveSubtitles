# LiveSubtitles - convenience wrapper around scripts/
#
#   make            build (release)
#   make run        build and launch from build/
#   make install    build and copy to /Applications
#   make debug      debug build
#   make icon       regenerate Resources/AppIcon.icns
#   make dist       build a zip suitable for a GitHub Release
#   make clean      remove build output and the SwiftPM cache

APP  := build/LiveSubtitles.app
ZIP  := build/LiveSubtitles.zip

.PHONY: all build debug run install icon update check-update dist dmg package clean

all: build

build:
	@scripts/build.sh release

debug:
	@scripts/build.sh debug

run: build
	@scripts/run.sh

install:
	@scripts/install.sh

icon:
	@python3 scripts/make-icon.py

# Pull and reinstall; `make check-update` only reports whether there is anything new.
update:
	@scripts/update.sh

check-update:
	@scripts/update.sh --fetch

# Zip whatever is already in build/.
#
# This deliberately does NOT depend on `build`. Rebuilding here would re-stamp and
# re-sign the app, which would throw away the version the tag supplied - and, when
# signing secrets are configured, the signature and the notarisation ticket stapled to
# it. Package only what was just built and signed.
dist:
	@test -d $(APP) || { echo "nothing to package: run 'make build' first" >&2; exit 1; }
	@rm -f $(ZIP)
	@cd build && ditto -c -k --sequesterRsrc --keepParent LiveSubtitles.app LiveSubtitles.zip
	@echo "==> $(ZIP)"

# Drag-to-Applications disk image, also packaged without rebuilding.
dmg:
	@scripts/make-dmg.sh

# Convenience for local use: build, then package both artefacts.
package: build dist dmg

clean:
	@rm -rf build .build

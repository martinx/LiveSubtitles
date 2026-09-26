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

.PHONY: all build debug run install icon update check-update dist clean

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

# ditto rather than zip: it preserves the bundle's metadata and symlinks.
dist: build
	@rm -f $(ZIP)
	@cd build && ditto -c -k --sequesterRsrc --keepParent LiveSubtitles.app LiveSubtitles.zip
	@echo "==> $(ZIP)"

clean:
	@rm -rf build .build

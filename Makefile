# Sesame — convenience targets over SwiftPM.

.PHONY: build release test app clean

# Debug build of every target (CLI + menu-bar app + core).
build:
	swift build

# Release build of every target.
release:
	swift build -c release

# Run the unit suite (the 20 CLI/core tests).
test:
	swift test

# Assemble + ad-hoc-sign + install the menu-bar app to ~/Applications/Sesame.app.
app:
	./scripts/build-app.sh

clean:
	swift package clean
	rm -rf .build/Sesame.app

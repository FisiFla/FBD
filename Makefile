# NOTE: --disable-sandbox is required on machines where SwiftPM's manifest
# sandbox-exec is blocked (sandbox_apply: Operation not permitted).
SWIFT_FLAGS = --disable-sandbox

CONFIG = release
APP_BUNDLE = build/FBD.app

.PHONY: all build test app clean run

all: app

build:
	swift build $(SWIFT_FLAGS)

test:
	swift test $(SWIFT_FLAGS)

# Universal (arm64 + x86_64). On Apple Silicon the macOS SDK may not ship an
# x86_64 slice; falls back to native arch with a warning.
# The built executable is located AFTER the build, inside the shell, by asking
# SwiftPM where it actually put things (`--show-bin-path`). Hard-coded guesses
# do not survive toolchain drift: `.build/release`, `.build/apple/Products/
# Release` and `.build/out/Products/Release` have each been the truth, and a
# wrong guess made this target fail with "built binary not found" even though
# the build succeeded. Asking in the shell also avoids expanding a make-side
# wildcard before the build has run.
app:
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	@if swift build $(SWIFT_FLAGS) -c $(CONFIG) --arch arm64 --arch x86_64 2>/tmp/fbd-universal.log; then \
		BIN="$$(swift build $(SWIFT_FLAGS) -c $(CONFIG) --arch arm64 --arch x86_64 --show-bin-path)/FBD"; \
	else \
		echo "Universal build failed (see /tmp/fbd-universal.log); building native arch only."; \
		swift build $(SWIFT_FLAGS) -c $(CONFIG) || exit 1; \
		BIN="$$(swift build $(SWIFT_FLAGS) -c $(CONFIG) --show-bin-path)/FBD"; \
	fi; \
	if [ -z "$$BIN" ] || [ ! -f "$$BIN" ]; then echo "error: built binary not found at '$$BIN'"; exit 1; fi; \
	cp "$$BIN" $(APP_BUNDLE)/Contents/MacOS/FBD; \
	BIN_DIR="$$(dirname "$$BIN")"; \
	if [ -d "$$BIN_DIR/Sparkle.framework" ]; then \
		mkdir -p $(APP_BUNDLE)/Contents/Frameworks; \
		cp -R "$$BIN_DIR/Sparkle.framework" $(APP_BUNDLE)/Contents/Frameworks/; \
		rm -rf $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/_CodeSignature; \
	else \
		echo "warning: Sparkle.framework not found in $$BIN_DIR - the updater will be inert"; \
	fi
	@cp Sources/FBD/Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp Sources/FBD/Resources/FBD.icns $(APP_BUNDLE)/Contents/Resources/FBD.icns
	@codesign --force --sign - $(APP_BUNDLE) >/dev/null 2>&1 || true
	@codesign --force --sign - $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework >/dev/null 2>&1 || true
	@echo "Built $(APP_BUNDLE)"

run: app
	open $(APP_BUNDLE)

# Bump the release version (RELEASING.md step 1). Updates
# CFBundleShortVersionString (and CFBundleVersion unless BUILD is given, in
# which case it is incremented). Usage:
#   make bump-version VERSION=1.0.0        # build +1
#   make bump-version VERSION=0.2.0 BUILD=2
bump-version:
	@if [ -z "$(VERSION)" ]; then echo "usage: make bump-version VERSION=x.y.z [BUILD=n]"; exit 1; fi; \
	PLIST=Sources/FBD/Resources/Info.plist; \
	CURRENT=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $$PLIST); \
	BUILD="$(BUILD)"; \
	if [ -z "$$BUILD" ]; then BUILD=$$((CURRENT + 1)); fi; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $$PLIST; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$BUILD" $$PLIST; \
	echo "version bumped to $(VERSION) (build $$BUILD, was $$CURRENT)"

## Drive the real panel via Accessibility/CGEvent (needs a11y permission).
ui-smoke:
	bash scripts/ui-smoke.sh

clean:
	rm -rf .build build

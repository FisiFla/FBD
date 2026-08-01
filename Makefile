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
# The built executable is located AFTER the build, inside the shell: SPM
# emits it at .build/apple/Products/Release/FBD (universal) or
# .build/<arch>-apple-macosx/release/FBD (single arch). (A make-side
# wildcard would be expanded before the build ran and came up empty on
# fresh checkouts.)
app:
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	@if swift build $(SWIFT_FLAGS) -c $(CONFIG) --arch arm64 --arch x86_64 2>/tmp/fbd-universal.log; then \
		BIN="$$(ls -d .build/apple/Products/Release/FBD .build/arm64-apple-macosx/release/FBD .build/x86_64-apple-macosx/release/FBD 2>/dev/null | head -1)"; \
	else \
		echo "Universal build failed (see /tmp/fbd-universal.log); building native arch only."; \
		swift build $(SWIFT_FLAGS) -c $(CONFIG); \
		BIN="$$(ls -d .build/apple/Products/Release/FBD .build/arm64-apple-macosx/release/FBD .build/x86_64-apple-macosx/release/FBD 2>/dev/null | head -1)"; \
	fi; \
	if [ -z "$$BIN" ] || [ ! -f "$$BIN" ]; then echo "error: built binary not found"; exit 1; fi; \
	cp "$$BIN" $(APP_BUNDLE)/Contents/MacOS/FBD
	@cp Sources/FBD/Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	# Sparkle: copy the framework (SPM binary distribution) into the bundle.
	@if [ -d .build/apple/Products/Release/Sparkle.framework ]; then \
		mkdir -p $(APP_BUNDLE)/Contents/Frameworks; \
		cp -R .build/apple/Products/Release/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/; \
		rm -rf $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/_CodeSignature; \
	fi
	@codesign --force --sign - $(APP_BUNDLE) >/dev/null 2>&1 || true
	@codesign --force --sign - $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework >/dev/null 2>&1 || true
	@echo "Built $(APP_BUNDLE)"

run: app
	open $(APP_BUNDLE)

clean:
	rm -rf .build build

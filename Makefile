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
app:
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	@if swift build $(SWIFT_FLAGS) -c $(CONFIG) --arch arm64 --arch x86_64 2>/tmp/fbd-universal.log; then \
		cp .build/apple/Products/$(CONFIG)/FBD $(APP_BUNDLE)/Contents/MacOS/FBD; \
	else \
		echo "Universal build failed (see /tmp/fbd-universal.log); building native arch only."; \
		swift build $(SWIFT_FLAGS) -c $(CONFIG); \
		cp .build/apple/Products/$(CONFIG)/FBD $(APP_BUNDLE)/Contents/MacOS/FBD; \
	fi
	@cp Sources/FBD/Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@codesign --force --sign - $(APP_BUNDLE) >/dev/null 2>&1 || true
	@echo "Built $(APP_BUNDLE)"

run: app
	open $(APP_BUNDLE)

clean:
	rm -rf .build build

APP_NAME     = Cortana Canvas
SCHEME       = CortanaCanvas
BUILD_DIR    = /tmp/canvas-release-build
INSTALL_PATH = /Applications/$(APP_NAME).app

.PHONY: generate build install update open clean

## Regenerate .xcodeproj from project.yml
generate:
	xcodegen generate

## Build Release binary
build: generate
	xcodebuild \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination 'platform=macOS' \
		build \
		-derivedDataPath $(BUILD_DIR) \
		| grep -E "^error:|BUILD (SUCCEEDED|FAILED)"

## Install to /Applications (build first)
install: build
	@echo "→ Stopping running instance..."
	@killall "$(APP_NAME)" 2>/dev/null; sleep 1; true
	@echo "→ Installing to /Applications..."
	@cp -R "$(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app" /Applications/
	@echo "✓ Installed: $(INSTALL_PATH)"

## Full update cycle: build + install + relaunch
update: install
	@echo "→ Launching..."
	@open "$(INSTALL_PATH)"
	@echo "✓ $(APP_NAME) updated and running"

## Open the installed app
open:
	open "$(INSTALL_PATH)"

## Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)

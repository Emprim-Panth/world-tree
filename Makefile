APP_NAME     = World Tree
SCHEME       = WorldTree
BUILD_DIR    = /tmp/worldtree-release-build
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
	@touch /tmp/.worldtree-updated
	@echo "✓ Installed: $(INSTALL_PATH)"

## Full update cycle: build + install + relaunch
update: install
	@echo "→ Launching..."
	@open "$(INSTALL_PATH)"
	@echo "✓ $(APP_NAME) updated and running"

## Open the installed app
open:
	open "$(INSTALL_PATH)"

## Trigger a staged rebuild (batched, zero-downtime)
rebuild:
	@mkdir -p ~/.cortana/worldtree
	@touch ~/.cortana/worldtree/rebuild.dirty
	@echo "Rebuild queued. Watcher will build after 2-min quiet window."
	@echo "Use 'make rebuild-now' to skip the quiet window."

## Rebuild immediately (skip quiet window, still staged)
rebuild-now:
	@echo "→ Building staged..."
	@WT_STAGED_BUILD=1 xcodebuild \
		-project WorldTree.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath /tmp/worldtree-staged-build \
		-quiet \
		build
	@echo "→ Swapping..."
	@killall "$(APP_NAME)" 2>/dev/null; sleep 1; true
	@ditto "/tmp/worldtree-staged-build/Build/Products/Debug/$(APP_NAME).app" "$(INSTALL_PATH)"
	@codesign --force --sign "Apple Development" \
		--entitlements WorldTree.entitlements \
		--options runtime \
		--timestamp=none \
		"$(INSTALL_PATH)"
	@rm -f ~/.cortana/worldtree/rebuild.dirty
	@echo "✓ $(APP_NAME) rebuilt and restarting (launchd)"

## Clean build artifacts
clean:
	rm -rf $(BUILD_DIR) /tmp/worldtree-staged-build

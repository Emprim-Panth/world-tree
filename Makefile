APP_NAME     = World Tree
SCHEME       = WorldTree
BUILD_DIR    = /tmp/worldtree-release-build
INSTALL_PATH = /Applications/$(APP_NAME).app
SIGN_IDENTITY = 4B1FEE2344F79AD30E99304B6454317CDEAB3878
ENTITLEMENTS  = WorldTree.entitlements
LAUNCHD_LABEL = com.forgeandcode.world-tree
LAUNCHD_PLIST = $(HOME)/Library/LaunchAgents/$(LAUNCHD_LABEL).plist
UID           = $(shell id -u)

.PHONY: generate build install update open clean rebuild rebuild-now


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
install:
	@./Scripts/install.sh

## Full update cycle: build + install + relaunch
update: install
	@echo "✓ $(APP_NAME) updated and running (via launchd)"

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
	@./Scripts/install.sh

## Clean build artifacts
clean:
	rm -rf $(BUILD_DIR) /tmp/worldtree-staged-build

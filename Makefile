SWIFT_SCRATCH ?= .build
.PHONY: test build build-unsigned build-signed

test:
	swift test --scratch-path "$(SWIFT_SCRATCH)"
	swift build --scratch-path "$(SWIFT_SCRATCH)" --product homekit-mcp-fixture
	HOMEKIT_FIXTURE="$(abspath $(SWIFT_SCRATCH))/debug/homekit-mcp-fixture" python3 -m unittest discover -s Tests -p 'test_*.py' -v

build: build-unsigned

build-unsigned:
	xcodebuild -project HomeKitSync.xcodeproj -scheme HomeKitSync -configuration Release -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build

# Explicit local signing only; no automatic provisioning/account changes.
build-signed:
	@test -n "$(DEVELOPMENT_TEAM)" || { echo 'Set DEVELOPMENT_TEAM to your own Apple team ID'; exit 1; }
	xcodebuild -project HomeKitSync.xcodeproj -scheme HomeKitSync -configuration Release -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath .build/xcode DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) build
